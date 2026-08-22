import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'discovery_service.dart';
import 'log.dart';
import 'session_service.dart';
import 'socket_service.dart';
import 'trace.dart';

const String _tag = '[Bootstrap]';

/// CC-LAT-010: what the connect race has resolved to so far. Both
/// `splash_screen.dart` and `connecting_screen.dart` are pure views over
/// this — neither owns any connect logic of its own any more.
sealed class BootstrapOutcome {
  const BootstrapOutcome();
}

/// The pairing read hasn't resolved yet. Only ever the state for the few
/// milliseconds between `main()` calling [ConnectionBootstrap.start] and the
/// Keystore read finishing — normally over before the first frame paints.
class BootstrapIdle extends BootstrapOutcome {
  const BootstrapIdle();
}

/// No saved pairing on this device — belongs at `/scan`.
class BootstrapNoPairing extends BootstrapOutcome {
  const BootstrapNoPairing();
}

/// A connect attempt (or the post-connect resync check) is in flight.
/// [stage] mirrors the three rows the old screen drew: 0 = reaching the
/// server, 1 = securing the session. A live connection never actually
/// reaches 2 — the resync check resolves straight to [BootstrapResumed] or
/// [BootstrapNeedsAuth] — it only appears in the debug demo-pairing path.
class BootstrapConnecting extends BootstrapOutcome {
  final PairingInfo pairing;
  final int stage;
  final String? errorMsg;
  const BootstrapConnecting(this.pairing, {this.stage = 0, this.errorMsg});
}

/// The saved host didn't answer within the connect timeout — scanning the
/// LAN for the desk's beacon and verifying candidates before giving up.
class BootstrapRediscovering extends BootstrapOutcome {
  final PairingInfo pairing;
  const BootstrapRediscovering(this.pairing);
}

/// Socket connected but the desk no longer trusts the prior PIN
/// verification (or this is a first-ever connect) — needs the PIN screen.
class BootstrapNeedsAuth extends BootstrapOutcome {
  final PairingInfo pairing;
  const BootstrapNeedsAuth(this.pairing);
}

/// Socket connected and the desk resumed the prior session silently —
/// straight to `/tables`, no PIN prompt.
class BootstrapResumed extends BootstrapOutcome {
  const BootstrapResumed();
}

/// The desk turned the pairing itself away (expired/revoked/deactivated).
/// Retrying cannot fix this — only a fresh QR can.
class BootstrapPairingRejected extends BootstrapOutcome {
  const BootstrapPairingRejected();
}

/// Timed out, then rediscovery found nothing reachable either.
class BootstrapFailed extends BootstrapOutcome {
  final PairingInfo pairing;
  const BootstrapFailed(this.pairing);
}

/// CC-LAT-010: races the pairing read and the socket connect from the
/// instant `main()` runs, instead of the old serial
/// splash-mounts → reads-pairing → connecting-mounts → calls-connect chain
/// (300-450ms of pure sequencing before a single packet went out).
///
/// **Invariant: exactly one authenticated operator socket exists at any
/// moment.** Rediscovery verifies candidates with the unauthenticated
/// `GET /ping` route only (see [SocketService.ping]) — it never opens a
/// second real operator socket to "simplify" verification, and the stale
/// socket is torn down (see [_onConnectTimeout]) before rediscovery starts
/// scanning, not left retrying in the background alongside it.
class ConnectionBootstrap extends StateNotifier<BootstrapOutcome> {
  ConnectionBootstrap(this._ref) : super(const BootstrapIdle());

  final Ref _ref;
  bool _started = false;
  PairingInfo? _pairing;
  Timer? _connectTimeout;
  StreamSubscription<SocketState>? _socketSub;

  /// Bumped on every fresh attempt (initial connect, retry, or a rediscovered
  /// re-pair) and checked by every async continuation before it writes
  /// [state] — the same seq-guard pattern `sync_service.dart` uses for menu
  /// parses. Without it, a cancelled attempt's rediscovery scan or resync
  /// check could still land and overwrite whatever the user's retry/cancel
  /// moved on to.
  int _generation = 0;

  /// Idempotent so it's safe to call from `main()` unconditionally — a hot
  /// restart in debug mode re-runs `main()` against the same provider
  /// container's already-resolved state.
  void start() {
    if (_started) return;
    _started = true;
    // CC-LAT-009: fired here, in parallel with the connect race below, not
    // from TablesScreen.initState(). The router never mounts that screen
    // before isAuthenticatedProvider is true, and that flag is only set
    // after a real sync has already applied live data — so calling this
    // from the screen always lost the race and overwrote live state with a
    // stale disk snapshot. Starting it here means the disk read and the
    // socket connect genuinely happen concurrently, and whichever screen
    // paints first sees the cache instead of nothing.
    unawaited(_ref.read(syncServiceProvider).hydrateFromFloorCache());
    unawaited(_run());
  }

  Future<void> _run() async {
    final pairing = await SessionService().getSavedPairing();
    Trace.mark('pairing_read_done');
    if (pairing == null) {
      logD(_tag, 'No saved pairing → /scan');
      state = const BootstrapNoPairing();
      return;
    }
    _pairing = pairing;
    _ref.read(hasSavedPairingProvider.notifier).state = true;
    await _attemptConnect(pairing);
  }

  Future<void> _attemptConnect(PairingInfo pairing) async {
    final gen = ++_generation;
    _pairing = pairing;
    state = BootstrapConnecting(pairing, stage: 0);

    if (kDebugMode && pairing.token == 'demo-token') {
      logD(_tag, 'Demo pairing — skipping real socket handshake');
      unawaited(_runDemoStages(pairing, gen));
      return;
    }

    logD(_tag, 'Pairing loaded: ${pairing.host}:${pairing.port}');
    final socketService = _ref.read(socketServiceProvider);
    unawaited(_socketSub?.cancel());
    _socketSub = socketService.stateStream
        .listen((s) => _onSocketState(s, pairing, gen));

    _connectTimeout?.cancel();
    _connectTimeout = Timer(
      const Duration(seconds: 10),
      () => _onConnectTimeout(pairing, gen),
    );

    logD(_tag, 'Starting socket connection...');
    Trace.mark('socket_connect_called');
    socketService.connect(pairing.host, pairing.port, pairing.token);
  }

  void _onSocketState(SocketState s, PairingInfo pairing, int gen) {
    if (gen != _generation) return;
    logD(_tag, 'Socket state changed: $s');
    final socketService = _ref.read(socketServiceProvider);

    if (s == SocketState.connected) {
      Trace.mark('socket_connected');
      logD(_tag, '✓ Connected → checking for a resumable session');
      _connectTimeout?.cancel();
      state = BootstrapConnecting(pairing, stage: 1);
      unawaited(_attemptSilentResume(pairing, gen));
    } else if (s == SocketState.disconnected &&
        socketService.lastConnectFailure == ConnectFailure.authRejected) {
      // No point burning the full connect timeout, and no point letting
      // socket.io retry this forever — the token will be just as dead next
      // time. Tear it down and say so.
      logD(_tag, '✗ Pairing rejected by the desk');
      _connectTimeout?.cancel();
      socketService.disconnect();
      state = const BootstrapPairingRejected();
    } else if (s == SocketState.disconnected &&
        state is BootstrapConnecting &&
        (state as BootstrapConnecting).stage > 0) {
      logD(_tag, '✗ Connection lost during handshake');
      state = BootstrapConnecting(pairing,
          stage: (state as BootstrapConnecting).stage,
          errorMsg: 'Connection lost — retrying…');
    }
  }

  /// If the operator was disconnected for less than the backend's PIN grace
  /// window (app killed/backgrounded and relaunched, or a WiFi blip just
  /// reconnected), the desk still trusts the prior PIN verification —
  /// resume straight to `/tables` instead of prompting again.
  Future<void> _attemptSilentResume(PairingInfo pairing, int gen) async {
    final resumed = await _ref.read(syncServiceProvider).requestResync();
    if (gen != _generation) return;
    if (resumed) {
      logD(_tag, '✓ Session resumed silently');
      // registerListeners() is idempotent — it unregisters itself first.
      _ref.read(syncServiceProvider).registerListeners();
      state = const BootstrapResumed();
      return;
    }
    logD(_tag, 'Session needs PIN');
    state = BootstrapNeedsAuth(pairing);
  }

  /// The saved host stopped answering — most often because the desk's own
  /// network address changed. Tears the stale socket down first (see the
  /// class doc's invariant), then listens briefly for the desk's discovery
  /// beacon and verifies any candidate with an unauthenticated `GET /ping`
  /// before giving up.
  Future<void> _onConnectTimeout(PairingInfo pairing, int gen) async {
    if (gen != _generation) return;
    logD(_tag, 'Timed out on ${pairing.host} — scanning for the desk');
    unawaited(_socketSub?.cancel());
    _ref.read(socketServiceProvider).disconnect();
    state = BootstrapRediscovering(pairing);

    final candidates = await scanForDesks();
    if (gen != _generation) return;

    final toProbe = candidates
        .where((c) => !(c.ip == pairing.host && c.port == pairing.port))
        .toList();
    final verified = await _firstVerifiedDesk(
      toProbe,
      pairing.deskInstanceId,
      priorityHost: pairing.host,
    );
    if (gen != _generation) return;

    if (verified != null) {
      logD(
        _tag,
        '✓ Found desk at new address ${verified.ip}:${verified.port} — re-pairing silently',
      );
      final updated = PairingInfo(
        host: verified.ip,
        port: verified.port,
        token: pairing.token,
        deviceSecret: pairing.deviceSecret,
        deskInstanceId: pairing.deskInstanceId,
      );
      await SessionService().savePairing(updated);
      if (gen != _generation) return;
      unawaited(_attemptConnect(updated));
      return;
    }

    logD(_tag, '✗ Rediscovery found nothing reachable');
    state = BootstrapFailed(pairing);
  }

  /// Pings every (candidate × address) pair concurrently — a plain
  /// unauthenticated `GET /ping`, never a real socket — and resolves with the
  /// first one that answers, without waiting for slower non-matching pairs to
  /// finish timing out. Resolves null only once every pair has been
  /// accounted for.
  ///
  /// Each candidate's `ip` AND every address in its `ips[]` are tried — a
  /// multi-homed desk can be unreachable on the interface the beacon
  /// happened to key the candidate by while still reachable on another one
  /// it also holds. The winning address, not necessarily `candidate.ip`, is
  /// what gets returned and re-paired to.
  ///
  /// When [expectedId] is known, a candidate must report the same id to be
  /// accepted — this is what stops re-pairing to a different desk that
  /// happens to answer on the same LAN. Older pairings have no id to check
  /// against, so any reachable candidate is accepted.
  ///
  /// Deliberately has no real-socket fallback for a desk too old to answer
  /// `/ping` (the previous connecting_screen.dart implementation had one).
  /// That fallback opened a disposable *authenticated* socket per candidate
  /// while the primary socket could still be mid-reconnect — exactly the
  /// second-operator-socket risk this rewrite's invariant rules out. An
  /// unpatched desk simply won't be found by rediscovery; it will if the
  /// operator moves it back to its last-known address or reconnects Wi-Fi.
  /// Same `/24` as [host] — a cheap heuristic, not a real subnet-mask
  /// check, but every device on a shared restaurant router (and therefore
  /// every plausible new address for a desk that just moved) satisfies it.
  static bool _sameSubnet(String a, String host) {
    final partsA = a.split('.');
    final partsB = host.split('.');
    if (partsA.length != 4 || partsB.length != 4) return false;
    return partsA[0] == partsB[0] &&
        partsA[1] == partsB[1] &&
        partsA[2] == partsB[2];
  }

  Future<DiscoveredDesk?> _firstVerifiedDesk(
    List<DiscoveredDesk> candidates,
    String? expectedId, {
    String? priorityHost,
  }) {
    final targets = <DiscoveredDesk>[];
    for (final candidate in candidates) {
      for (final address in {candidate.ip, ...candidate.ips}) {
        targets.add(DiscoveredDesk(
          ip: address,
          port: candidate.port,
          id: candidate.id,
        ));
      }
    }
    if (targets.isEmpty) return Future.value(null);
    final completer = Completer<DiscoveredDesk?>();
    var remaining = targets.length;

    void pingTarget(DiscoveredDesk target) {
      SocketService.ping(
        target.ip,
        target.port,
        // The race's wall-clock is set by the fastest responder regardless
        // of this ceiling — shrunk from the 3s default because the only
        // case that ever burns the full timeout is a black-holed IP with no
        // ARP entry, which is exactly what rediscovery expects to hit for
        // most of the fan-out.
        timeout: const Duration(milliseconds: 1500),
      ).then((result) {
        if (completer.isCompleted) return;
        final matches = switch (result) {
          PingOk(id: final id) => expectedId == null || id == expectedId,
          PingFailed() => false,
        };
        if (matches) {
          completer.complete(target);
        } else if (--remaining == 0) {
          completer.complete(null);
        }
      });
    }

    // The previously-known address's subnet is by far the likeliest match
    // (a desk that "moved" almost always just got a new DHCP lease on the
    // same router) — probe it immediately, and give it a short head start
    // before opening every other candidate's socket. Doesn't change
    // best-case latency (the race still resolves on whichever responds
    // first), only the number of concurrent connections/radio wake-ups in
    // the common case.
    final priority = <DiscoveredDesk>[];
    final rest = <DiscoveredDesk>[];
    for (final target in targets) {
      (priorityHost != null && _sameSubnet(target.ip, priorityHost)
              ? priority
              : rest)
          .add(target);
    }
    for (final target in priority) {
      pingTarget(target);
    }
    if (rest.isEmpty) {
      return completer.future;
    }
    if (priority.isEmpty) {
      // Nothing to give a head start to — no point delaying.
      for (final target in rest) {
        pingTarget(target);
      }
    } else {
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (completer.isCompleted) return;
        for (final target in rest) {
          pingTarget(target);
        }
      });
    }
    return completer.future;
  }

  /// Debug-only sandbox path (`demo-token`) — no server, just a staged
  /// animation ending at the PIN screen, matching the old
  /// `_runDemoStages()` timing.
  Future<void> _runDemoStages(PairingInfo pairing, int gen) async {
    state = BootstrapConnecting(pairing, stage: 1);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (gen != _generation) return;
    state = BootstrapConnecting(pairing, stage: 2);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (gen != _generation) return;
    state = BootstrapNeedsAuth(pairing);
  }

  void retry() {
    final pairing = _pairing;
    if (pairing == null) return;
    _connectTimeout?.cancel();
    _socketSub?.cancel();
    _ref.read(socketServiceProvider).disconnect();
    unawaited(_attemptConnect(pairing));
  }

  Future<void> cancelToScan() async {
    _generation++;
    _connectTimeout?.cancel();
    unawaited(_socketSub?.cancel());
    _ref.read(socketServiceProvider).disconnect();
    await SessionService().clearPairing();
    _pairing = null;
    state = const BootstrapNoPairing();
  }

  @override
  void dispose() {
    _connectTimeout?.cancel();
    _socketSub?.cancel();
    super.dispose();
  }
}
