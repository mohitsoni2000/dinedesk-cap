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

sealed class BootstrapOutcome {
  const BootstrapOutcome();
}

class BootstrapIdle extends BootstrapOutcome {
  const BootstrapIdle();
}

class BootstrapNoPairing extends BootstrapOutcome {
  const BootstrapNoPairing();
}

class BootstrapConnecting extends BootstrapOutcome {
  final PairingInfo pairing;
  final int stage;
  final String? errorMsg;
  const BootstrapConnecting(this.pairing, {this.stage = 0, this.errorMsg});
}

class BootstrapRediscovering extends BootstrapOutcome {
  final PairingInfo pairing;
  const BootstrapRediscovering(this.pairing);
}

class BootstrapNeedsAuth extends BootstrapOutcome {
  final PairingInfo pairing;
  const BootstrapNeedsAuth(this.pairing);
}

class BootstrapResumed extends BootstrapOutcome {
  const BootstrapResumed();
}

class BootstrapPairingRejected extends BootstrapOutcome {
  const BootstrapPairingRejected();
}

class BootstrapFailed extends BootstrapOutcome {
  final PairingInfo pairing;
  const BootstrapFailed(this.pairing);
}

class ConnectionBootstrap extends StateNotifier<BootstrapOutcome> {
  ConnectionBootstrap(this._ref) : super(const BootstrapIdle());

  final Ref _ref;
  bool _started = false;
  PairingInfo? _pairing;
  Timer? _connectTimeout;
  StreamSubscription<SocketState>? _socketSub;

  int _generation = 0;

  void start() {
    if (_started) return;
    _started = true;

    unawaited(_ref.read(syncServiceProvider).hydrateFromFloorCache());
    unawaited(_run());
  }

  Future<void> _run() async {
    PairingInfo? pairing;
    try {
      pairing = await SessionService()
          .getSavedPairing()
          .timeout(const Duration(seconds: 8));
    } catch (err, stack) {
      // A throw (corrupted secure storage, a platform-channel failure) or a
      // hang here used to leave `state` stuck at BootstrapIdle forever —
      // connecting_screen renders that as an empty host/port and an
      // infinite "Reaching the POS server" spinner with no way out but
      // force-closing the app, since ref.listen only reacts to a state
      // *change* and this one never came. Route to /scan instead: a fresh
      // QR self-heals whatever the read couldn't, same as "no pairing".
      logE(_tag, 'Failed to read saved pairing — sending to /scan', err, stack);
      state = const BootstrapNoPairing();
      return;
    }
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

  Future<void> _attemptSilentResume(PairingInfo pairing, int gen) async {
    final resumed = await _ref.read(syncServiceProvider).requestResync();
    if (gen != _generation) return;
    if (resumed) {
      logD(_tag, '✓ Session resumed silently');

      _ref.read(syncServiceProvider).registerListeners();
      state = const BootstrapResumed();
      return;
    }
    logD(_tag, 'Session needs PIN');
    state = BootstrapNeedsAuth(pairing);
  }

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

  /// Called by a pairing UI (QR scan, manual code entry, or Discover) right
  /// after it has already saved a fresh pairing to disk. `start()` only
  /// ever reads from storage once, at app boot — without this, a freshly
  /// paired device sits on `/connecting` forever within the same running
  /// app instance (SessionService.savePairing() writes to disk, but nothing
  /// tells the already-started ConnectionBootstrap about it). Only a full
  /// app restart would have picked the new pairing up.
  void connectWithFreshPairing(PairingInfo pairing) {
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
