import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show protected, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/gate_providers.dart' show ticketIssueFormProvider;
import '../data/providers.dart';
import 'biometric_service.dart';
import 'discovery_service.dart';
import 'log.dart';
import 'offline_order_queue_service.dart';
import 'offline_session.dart';
import 'pending_slips_store.dart' show pendingSlipsStoreProvider;
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

/// The desk could not be reached at boot, but the last confirmed operator
/// session is still inside the PIN grace window, so the app opened on the
/// cached floor/menu/orders (cold-start offline). The socket keeps dialling; a
/// reachable desk takes over through the normal resume path (and asks for the
/// PIN if its own grace has run out).
class BootstrapOfflineResumed extends BootstrapOutcome {
  const BootstrapOfflineResumed();
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
  StreamSubscription<ConnectFailure>? _failureSub;
  Timer? _authRecheck;

  /// Whether the process is currently bound to the Wi-Fi network (Android).
  bool _wifiBound = false;

  /// A handshake refused with an auth code may be a race, not a verdict: only
  /// this many in a row, [_authRecheckDelay] apart, mean the pairing is dead.
  static const int _authRejectionsToGiveUp = 2;
  static const Duration _authRecheckDelay = Duration(seconds: 3);

  /// Boot connect budget. 10s was shorter than a weak-WiFi websocket upgrade
  /// plus the first sync can take, and tripped rediscovery on a desk that had
  /// not moved.
  static const Duration _bootConnectTimeout = Duration(seconds: 15);

  int _generation = 0;

  /// Once a session is up, `_onSocketState`'s "connection lost" handling
  /// stops at just showing "Reconnecting…" (see `_onSocketState` below) —
  /// there's no equivalent to `_connectTimeout` watching for a stall.
  /// socket.io's own `enableReconnection()` keeps retrying forever, but only
  /// the *same* host:port — if the desk's LAN IP changed mid-shift (DHCP
  /// renewal, POS restarted on a new address), that retry loop never
  /// succeeds. This timer re-arms the same UDP-scan rediscovery boot uses,
  /// so a long mid-session outage can still self-heal instead of sitting
  /// disconnected until someone force-closes the app or rescans a QR.
  Timer? _midSessionRediscovery;

  /// Escalating, rather than the flat 45s this used to wait.
  ///
  /// The flat delay was sized for the expensive case — the desk genuinely moved
  /// and a UDP scan is the only way to find it. But the common case is a Wi-Fi
  /// blip where the desk never moved at all, and there the first scan is cheap
  /// (one 3s broadcast listen) and answers the question immediately. Starting
  /// at 8s means a session that socket.io can't repair on its own self-heals in
  /// under ten seconds instead of three quarters of a minute; the later steps
  /// keep a genuinely absent desk from being scanned for every 8s all shift.
  static const List<Duration> _rediscoveryBackoff = <Duration>[
    Duration(seconds: 8),
    Duration(seconds: 20),
    Duration(seconds: 45),
  ];
  int _rediscoveryAttempt = 0;

  /// The pairing this bootstrap is currently working with, if any.
  PairingInfo? get currentPairing => _pairing;

  /// True when nothing automatic may dial the desk: there is no pairing (signed
  /// out / unpaired), the desk has refused it (two auth rejections), or it
  /// force-disconnected this device (token revoked / expired). The link
  /// monitor's ladder and watchdog consult this, so they never resurrect a
  /// pairing the desk refused or a session the operator ended. Only a person
  /// ("Try reconnect") or a fresh pairing leaves this state.
  bool get isStoodDown =>
      _pairing == null ||
      state is BootstrapPairingRejected ||
      _ref.read(forceDisconnectedProvider);

  void start() {
    if (_started) return;
    _started = true;

    unawaited(_ref.read(syncServiceProvider).hydrateFromFloorCache());
    // The outbox drain worker: flushes queued orders/KOTs on every verified
    // session and keeps retrying (with backoff) if a flush stalls.
    _ref.read(outboxDrainProvider).start();
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
    // One socket per pairing, and never a replacement while a PIN is being
    // checked: `connect()` disposes the socket carrying the operator:verify,
    // and the new one presents the same token, so the desk drops the old
    // session either way — the verify's ack is lost and the operator sees
    // "Connection lost". Every repair path funnels through here (connect
    // timeout, mid-session rediscovery, network change), so this is the one
    // place to hold them. If the verify succeeded meanwhile, the link is
    // proven and the queued reconnect is moot.
    final socketService = _ref.read(socketServiceProvider);
    if (socketService.isVerifyInFlight) {
      logD(_tag,
          'PIN verify in flight — holding the reconnect until it settles');
      final heldGen = _generation;
      await socketService.whenVerifyIdle();
      if (heldGen != _generation) return;
      if (socketService.state == SocketState.verified) {
        logD(_tag, 'verify succeeded meanwhile — dropping the held reconnect');
        return;
      }
    }

    final gen = ++_generation;
    _pairing = pairing;
    _midSessionRediscovery?.cancel();
    _midSessionRediscovery = null;
    _authRecheck?.cancel();
    _rediscoveryAttempt = 0;
    state = BootstrapConnecting(pairing, stage: 0);

    if (pairing.token == 'demo-token') {
      logD(_tag, 'Demo pairing — skipping real socket handshake');
      unawaited(_runDemoStages(pairing, gen));
      return;
    }

    logD(_tag, 'Pairing loaded: ${pairing.host}:${pairing.port}');
    unawaited(_socketSub?.cancel());
    _socketSub = socketService.stateStream
        .listen((s) => _onSocketState(s, pairing, gen));
    unawaited(_failureSub?.cancel());
    _failureSub = socketService.connectFailureStream
        .listen((f) => _onConnectFailure(f, pairing, gen));

    // Before dialling: the app version for the handshake, and (Android) the
    // Wi-Fi binding. Neither may ever block or fail the connect — see
    // [_prepareNetwork].
    _connectTimeout?.cancel();
    await _prepareNetwork();
    if (gen != _generation) return;
    _connectTimeout = Timer(
      _bootConnectTimeout,
      () => _onConnectTimeout(pairing, gen),
    );

    logD(_tag, 'Starting socket connection...');
    Trace.mark('socket_connect_called');
    socketService.connect(pairing.host, pairing.port, pairing.token);
  }

  /// Everything that has to happen before the first byte goes out, bounded so
  /// it can never hold the connect hostage.
  Future<void> _prepareNetwork() async {
    await SocketService.loadAppVersion();
    if (_wifiBound) return;
    try {
      // Pins the process to Wi-Fi so LAN traffic can't be rerouted over mobile
      // data when the AP has no internet. A missing native half, a platform
      // error or a hang all simply mean "unbound" — the old behaviour.
      _wifiBound = await _ref
          .read(wifiBindingProvider)
          .bindWifi()
          .timeout(const Duration(milliseconds: 1500));
    } catch (err) {
      logD(_tag, 'Wi-Fi binding unavailable ($err) — continuing unbound');
      _wifiBound = false;
    }
  }

  /// One failed handshake. Auth refusals need to repeat before they are
  /// believed; anything else just means "unreachable", and socket.io keeps
  /// dialling on its own.
  void _onConnectFailure(ConnectFailure failure, PairingInfo pairing, int gen) {
    if (gen != _generation) return;
    final socketService = _ref.read(socketServiceProvider);
    if (failure != ConnectFailure.authRejected) {
      _authRecheck?.cancel();
      return;
    }
    final streak = socketService.authRejectionStreak;
    if (streak >= _authRejectionsToGiveUp) {
      logD(_tag, '✗ Pairing rejected by the desk ($streak times running)');
      _authRecheck?.cancel();
      _connectTimeout?.cancel();
      _midSessionRediscovery?.cancel();
      _midSessionRediscovery = null;
      socketService.disconnect();
      _ref.read(connectionProvider.notifier).state = const ConnectionStatus(
        online: false,
        label: 'Pairing expired — ask the admin for a new QR',
      );
      state = const BootstrapPairingRejected();
      return;
    }
    logD(_tag,
        'Handshake refused with an auth code (#$streak) — confirming once more');
    // A CONNECT_ERROR packet deactivates the io.Socket (socket.io will not
    // retry the namespace by itself), so the confirming attempt is ours.
    _authRecheck?.cancel();
    _authRecheck = Timer(_authRecheckDelay, () {
      if (gen != _generation) return;
      _ref.read(socketServiceProvider).reconnectIfNeeded();
    });
  }

  void _onSocketState(SocketState s, PairingInfo pairing, int gen) {
    if (gen != _generation) return;
    logD(_tag, 'Socket state changed: $s');

    if (s == SocketState.connected) {
      Trace.mark('socket_connected');
      logD(_tag, '✓ Connected → checking for a resumable session');
      _connectTimeout?.cancel();
      _authRecheck?.cancel();
      _midSessionRediscovery?.cancel();
      _midSessionRediscovery = null;
      _rediscoveryAttempt = 0;
      state = BootstrapConnecting(pairing, stage: 1);
      unawaited(_attemptSilentResume(pairing, gen));
    } else if (s == SocketState.disconnected &&
        state is BootstrapConnecting &&
        (state as BootstrapConnecting).stage > 0) {
      logD(_tag, '✗ Connection lost during handshake');
      state = BootstrapConnecting(pairing,
          stage: (state as BootstrapConnecting).stage,
          errorMsg: 'Connection lost — retrying…');
    } else if (s == SocketState.disconnected &&
        (state is BootstrapResumed || state is BootstrapOfflineResumed)) {
      // A session was already up and running; socket.io will keep retrying
      // the same host on its own. Arm a rediscovery watchdog in case that
      // never succeeds because the desk moved.
      _armMidSessionRediscovery(pairing, gen);
    }
  }

  void _armMidSessionRediscovery(PairingInfo pairing, int gen) {
    if (_midSessionRediscovery != null) return;
    final delay = _rediscoveryBackoff[
        math.min(_rediscoveryAttempt, _rediscoveryBackoff.length - 1)];
    _rediscoveryAttempt++;
    _midSessionRediscovery = Timer(delay, () {
      _midSessionRediscovery = null;
      unawaited(_onMidSessionRediscoveryDue(pairing, gen, delay));
    });
  }

  /// Called by [ConnectionSupervisor] when the OS reports the network changed.
  ///
  /// A network change is the single best moment to rescan: it is both when a
  /// stalled reconnect is most likely to succeed, and when the desk's reachable
  /// address is most likely to have changed underneath us. Waiting out the
  /// remaining backoff here would be waiting for information we already have.
  void onNetworkChanged() {
    final pairing = _pairing;
    if (pairing == null || isStoodDown) return;
    _rediscoveryAttempt = 0;
    if (_ref.read(socketServiceProvider).state != SocketState.disconnected) {
      return;
    }
    logD(_tag, 'Network changed while disconnected — rescanning now');
    _midSessionRediscovery?.cancel();
    _midSessionRediscovery = null;
    unawaited(_onMidSessionRediscoveryDue(pairing, _generation, Duration.zero));
  }

  Future<void> _onMidSessionRediscoveryDue(
    PairingInfo pairing,
    int gen,
    Duration waited,
  ) async {
    if (gen != _generation) return;
    if (_ref.read(socketServiceProvider).state != SocketState.disconnected) {
      return; // self-healed already
    }
    logD(_tag,
        'Still disconnected ${waited.inSeconds}s in — scanning for the desk');
    final found = await _rediscoverOrPoke(pairing, gen);
    if (gen != _generation) return;
    if (!found &&
        _ref.read(socketServiceProvider).state == SocketState.disconnected) {
      // Nothing reachable yet — try again later rather than giving up.
      // BootstrapResumed stays the reported state throughout; only
      // `ConnectionStatus.online` (driven by SyncService) reflects the
      // ongoing outage to the UI.
      _armMidSessionRediscovery(pairing, gen);
    }
  }

  Future<bool>? _rediscovering;

  /// Scans for the desk; when nothing *new* turns up, pokes the existing socket
  /// instead. The scan deliberately excludes the address we are already failing
  /// on, so "desk didn't move" used to end the repair right there and leave a
  /// socket nothing was driving. The poke is idempotent (it leaves a socket
  /// that socket.io is already redialling alone).
  Future<bool> _rediscoverOrPoke(PairingInfo pairing, int gen) {
    final running = _rediscovering;
    if (running != null) return running;
    final run = () async {
      final found = await _rediscoverAndRepair(pairing, gen);
      if (!found && gen == _generation) {
        _ref.read(socketServiceProvider).reconnectIfNeeded();
      }
      return found;
    }();
    _rediscovering = run.whenComplete(() => _rediscovering = null);
    return _rediscovering!;
  }

  /// One rediscovery pass, for the link monitor's escalation ladder. No-op when
  /// there is nothing to rediscover (no pairing, a rejected pairing) or the
  /// socket healed in the meantime.
  Future<void> rediscoverNow() async {
    final pairing = _pairing;
    if (pairing == null || isStoodDown) return;
    if (_ref.read(socketServiceProvider).state != SocketState.disconnected) {
      return;
    }
    await _rediscoverOrPoke(pairing, _generation);
  }

  /// Sets the pairing without connecting (tests).
  @visibleForTesting
  void debugSetPairing(PairingInfo pairing) => _pairing = pairing;

  /// Feeds one failed handshake in as if the socket had reported it (tests).
  @visibleForTesting
  void debugOnConnectFailure(ConnectFailure failure, PairingInfo pairing) =>
      _onConnectFailure(failure, pairing, _generation);

  /// Runs the post-connect resume step directly (tests).
  @visibleForTesting
  Future<void> debugAttemptSilentResume(PairingInfo pairing) =>
      _attemptSilentResume(pairing, _generation);

  Future<void> _attemptSilentResume(PairingInfo pairing, int gen) async {
    // The socket came (back) up while the operator's PIN is being checked —
    // typically the verify itself waiting out a reconnect. A resync now would
    // race it on an unverified session, earn `reauth_required`, and pop a
    // second PIN prompt over the one just typed. Let the verify decide.
    final socketService = _ref.read(socketServiceProvider);
    if (socketService.isVerifyInFlight) {
      await socketService.whenVerifyIdle();
      if (gen != _generation) return;
      if (socketService.state == SocketState.verified) {
        logD(_tag, '✓ Session verified by the in-flight PIN — resumed');
        state = const BootstrapResumed();
        return;
      }
    }

    // A recovered socket kept its desk-side session and had its missed
    // broadcasts replayed, so it is resumed by definition — asking again would
    // only confirm what recovery already guaranteed, at the cost of the full
    // sync payload. Only trusted for an already-authenticated session: the
    // desk refuses recovery when the operator's PIN has lapsed, but a session
    // this process never authenticated has nothing to skip.
    if (socketService.wasRecovered && _ref.read(isAuthenticatedProvider)) {
      logD(_tag, '✓ Session recovered by the desk — skipping resync');
      final sync = _ref.read(syncServiceProvider);
      sync.registerListeners();
      // A recovered socket is as verified as it ever was. Without this it
      // stayed `connected` forever: the heartbeat (which only runs verified)
      // never started, and the outbox never flushed.
      sync.completeResume();
      state = const BootstrapResumed();
      return;
    }
    // The single owner of the post-connect resync (SyncService's state
    // listener used to fire a second one concurrently). Transport failures are
    // retried here rather than read as "needs PIN": on a weak link a timed-out
    // resync says nothing about the operator's session.
    final sync = _ref.read(syncServiceProvider);
    var resumed = false;
    for (var attempt = 0; attempt < _resyncAttempts; attempt++) {
      resumed = await sync.requestResync();
      if (gen != _generation) return;
      if (resumed || !sync.lastResyncWasTransportFailure) break;
      if (socketService.state == SocketState.disconnected) return;
      logD(_tag, 'Resync hit a weak link (attempt ${attempt + 1}) — retrying');
      state = BootstrapConnecting(pairing,
          stage: 1, errorMsg: 'Slow connection — still trying…');
      await Future<void>.delayed(Duration(milliseconds: 1500 * (attempt + 1)));
      if (gen != _generation) return;
    }
    if (resumed) {
      logD(_tag, '✓ Session resumed silently');

      sync.registerListeners();
      state = const BootstrapResumed();
      return;
    }
    if (sync.lastResyncWasTransportFailure) {
      // Still nothing coming back across this socket: it is a zombie. Close
      // the engine so socket.io redials; the next `connected` resumes again.
      logD(_tag, 'Resync never got through — nudging the connection');
      socketService.nudgeEngine('resync unanswered');
      return;
    }
    logD(_tag, 'Session needs PIN');
    state = BootstrapNeedsAuth(pairing);
  }

  static const int _resyncAttempts = 3;

  Future<void> _onConnectTimeout(PairingInfo pairing, int gen) async {
    if (gen != _generation) return;
    logD(_tag, 'Timed out on ${pairing.host} — scanning for the desk');
    // The socket keeps dialling while we scan: tearing it down first (as this
    // used to) turned a handshake that was merely slow into a hard failure and
    // threw away the attempt that was about to land. If it connects meanwhile
    // `_onSocketState` carries on as normal.
    // An authenticated session (a ladder retry mid-shift) keeps its state: the
    // boot-only "Rediscovering" / "Failed" outcomes describe a boot that has
    // not got anywhere, not a working shift whose desk is briefly away.
    if (!_ref.read(isAuthenticatedProvider)) {
      state = BootstrapRediscovering(pairing);
    }

    final found = await _rediscoverAndRepair(pairing, gen);
    if (gen != _generation || found) return;
    if (_ref.read(socketServiceProvider).state != SocketState.disconnected) {
      return; // connected (or mid-handshake) while we scanned
    }

    logD(_tag, '✗ Rediscovery found nothing reachable');
    if (await onUnreachableAtBoot(pairing, gen)) return;
    if (gen != _generation) return;
    if (_ref.read(isAuthenticatedProvider)) return;
    state = BootstrapFailed(pairing);
  }

  /// Hook: the desk could not be reached at boot, even after rediscovery.
  ///
  /// Return true if something else has taken over the experience (for example
  /// cold-start offline mode showing the cached floor and menu) and
  /// [BootstrapFailed] must NOT be shown. The default shows the failure screen
  /// but leaves socket.io dialling and re-arms the background rescan, so a desk
  /// that comes up later is picked up without anyone pressing anything.
  ///
  /// Cold-start offline: if the last confirmed session is still inside the PIN
  /// grace window (and the biometric gate, when enabled, passes) the app opens
  /// on the cached data instead of the failure screen. Either way the rescan
  /// stays armed and the socket keeps dialling.
  @protected
  Future<bool> onUnreachableAtBoot(PairingInfo pairing, int gen) async {
    _armMidSessionRediscovery(pairing, gen);
    return _tryOfflineResume(pairing, gen);
  }

  /// Whether "Continue offline" may be offered right now (the PIN screen asks).
  /// Does not touch the biometric: that is the interactive step of the resume
  /// itself.
  Future<bool> offlineResumeEligible() async {
    final pairing = _pairing;
    if (pairing == null || pairing.token == 'demo-token') return false;
    try {
      return canResumeOffline(
        await SessionService().getOfflineSession(),
        DateTime.now(),
        pairingDeskInstanceId: pairing.deskInstanceId,
      );
    } catch (_) {
      return false;
    }
  }

  /// The PIN screen's "Continue offline". True when the app is now running on
  /// the cached session.
  Future<bool> resumeOffline() async {
    final pairing = _pairing;
    if (pairing == null) return false;
    return _tryOfflineResume(pairing, _generation);
  }

  bool _offlineResuming = false;

  Future<bool> _tryOfflineResume(PairingInfo pairing, int gen) async {
    if (_offlineResuming || pairing.token == 'demo-token') return false;
    // Before ANY biometric call. Every link-monitor `retry()` re-arms the
    // connect timeout, which lands here when the desk is still down; on a live
    // (or already offline-resumed) session there is nothing to resume, and the
    // fingerprint prompt used to pop up repeatedly mid-shift during a long
    // outage. Cold start has neither flag set, so it is unaffected.
    if (_ref.read(isAuthenticatedProvider) ||
        _ref.read(syncServiceProvider).liveSyncApplied) {
      logD(_tag, 'Offline resume: session already live — nothing to resume');
      return false;
    }
    _offlineResuming = true;
    try {
      final session = await SessionService().getOfflineSession();
      if (!canResumeOffline(session, DateTime.now(),
          pairingDeskInstanceId: pairing.deskInstanceId)) {
        logD(_tag, 'Offline resume: no session inside the grace window');
        return false;
      }
      // The grace window stands in for the PIN; a phone that guards its shift
      // with a fingerprint keeps guarding the offline one the same way.
      final bio = _ref.read(biometricServiceProvider);
      if (await bio.isEnabled() && await bio.unlock() == null) {
        logD(_tag, 'Offline resume: biometric not passed');
        return false;
      }
      if (gen != _generation || session == null) return false;
      // Reachable in the meantime: the normal path owns it.
      if (_ref.read(socketServiceProvider).state != SocketState.disconnected) {
        return false;
      }

      final sync = _ref.read(syncServiceProvider);
      // Floors/tables/rooms first (the snapshot's order history reads them).
      await sync.hydrateFromFloorCache();
      if (!await sync.hydrateFromSnapshot(
          deskInstanceId: pairing.deskInstanceId)) {
        logD(_tag, 'Offline resume: no usable snapshot');
        return false;
      }
      if (gen != _generation) return false;

      _ref.read(operatorProvider.notifier).state = Operator(
        name: session.name,
        role: session.role,
        shift: session.shift,
        id: session.operatorId,
        employeeId: session.employeeId,
      );
      _ref.read(offlineResumedProvider.notifier).state = true;
      _ref.read(connectionProvider.notifier).state = const ConnectionStatus(
        online: false,
        label: 'Offline — working from the last sync',
      );
      // Listeners + the reauth hooks the outbox needs for when the desk is back.
      sync.registerListeners();
      _ref.read(isAuthenticatedProvider.notifier).state = true;
      logD(_tag, '✓ Resumed offline as ${session.name}');
      state = const BootstrapOfflineResumed();
      return true;
    } catch (err, stack) {
      logE(_tag, 'Offline resume failed', err, stack);
      return false;
    } finally {
      _offlineResuming = false;
    }
  }

  /// Scans the LAN for the paired desk (by `deskInstanceId`), and if found
  /// at a different address, saves the updated pairing and reconnects.
  /// Shared by the boot-time connect timeout and the mid-session
  /// rediscovery watchdog. Returns true iff a reconnect was kicked off.
  Future<bool> _rediscoverAndRepair(PairingInfo pairing, int gen) async {
    // The QR's `hosts` fan-out (and every address this pairing has since
    // moved off) is known without hearing a beacon at all — which matters,
    // because a beacon only crosses the subnet it was broadcast on. Those are
    // probed straight away, *concurrently* with the UDP scan rather than after
    // it: the scan always costs its full listen window, and a multi-homed desk
    // reachable on an address we already hold shouldn't make the operator
    // wait that out first.
    final scan = scanForDesks();
    final known = expandDeskEndpoints(
      <DiscoveredDesk>[
        if (pairing.altHosts.isNotEmpty)
          DiscoveredDesk(
            ip: pairing.host,
            port: pairing.port,
            id: pairing.deskInstanceId,
            ips: pairing.altHosts,
          ),
      ],
      excludeIp: pairing.host,
      excludePort: pairing.port,
    );
    var verified = await firstVerifiedEndpoint(
      known,
      pairing.deskInstanceId,
      priorityHost: pairing.host,
    );
    final candidates = await scan;
    if (gen != _generation) return false;

    if (verified == null) {
      // Flatten to individual addresses BEFORE excluding the one we're failing
      // on. Excluding at desk granularity used to discard the whole beacon
      // record — alternates included — whenever its primary `ip` matched the
      // pairing host, which is precisely the multi-homed desk this repair path
      // exists to rescue. See expandDeskEndpoints' doc comment. Addresses the
      // known-address pass above already ruled out are skipped too.
      final alreadyTried = {for (final k in known) '${k.ip}:${k.port}'};
      final targets = expandDeskEndpoints(
        candidates,
        excludeIp: pairing.host,
        excludePort: pairing.port,
      ).where((t) => !alreadyTried.contains('${t.ip}:${t.port}')).toList();
      verified = await firstVerifiedEndpoint(
        targets,
        pairing.deskInstanceId,
        priorityHost: pairing.host,
      );
    }
    if (gen != _generation) return false;
    if (verified == null) return false;

    logD(
      _tag,
      '✓ Found desk at new address ${verified.ip}:${verified.port} — re-pairing silently',
    );
    final updated = pairing.movedTo(verified.ip, verified.port);
    await SessionService().savePairing(updated);
    if (gen != _generation) return false;
    unawaited(_attemptConnect(updated));
    return true;
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

  /// Rebuilds the connection from scratch (new socket, new session, full
  /// resync). [automatic] is for callers that are not a person pressing a
  /// button (the link monitor): those must never resurrect a pairing the desk
  /// has refused. A person's "Try reconnect" always goes through.
  void retry({bool automatic = false}) {
    // No saved pairing (signed out / unpaired): there is nothing to dial, and a
    // deferred retry (see the verify hold below) may fire after a sign-out.
    final pairing = _pairing;
    if (pairing == null) return;
    if (automatic && isStoodDown) return;
    final socketService = _ref.read(socketServiceProvider);
    if (socketService.isVerifyInFlight) {
      // Tearing down here would kill the verify's socket before
      // _attemptConnect's own hold could help. Re-evaluate once it settles:
      // a verified socket needs no retry at all.
      logD(_tag, 'retry requested mid-verify — deferring');
      unawaited(socketService.whenVerifyIdle().then((_) {
        if (socketService.state != SocketState.verified) {
          retry(automatic: automatic);
        }
      }));
      return;
    }
    _connectTimeout?.cancel();
    unawaited(_socketSub?.cancel());
    unawaited(_failureSub?.cancel());
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

  /// The connecting screen's "scan a new QR". Same teardown as [signOut].
  Future<void> cancelToScan() => signOut();

  /// The one teardown for every way a device leaves its pairing (profile
  /// sign-out, "Scan a new QR" on the refused/force-disconnected screens,
  /// cancelling a pairing). Before this only [cancelToScan] bumped
  /// `_generation` and dropped `_pairing`; the other paths just cleared the
  /// stored pairing, so the link monitor's ladder kept redialling the desk with
  /// the signed-out token and the orders listener kept re-saving the snapshot
  /// that the unpair had just cleared.
  ///
  /// Everything that can act on the old session is stopped synchronously (the
  /// part before the first `await`), so callers may `unawaited` it and carry on
  /// navigating.
  Future<void> signOut() async {
    _generation++;
    // First: from here `isStoodDown` is true, so the ladder / watchdog that the
    // disconnect below wakes up find nothing to dial.
    _pairing = null;
    _connectTimeout?.cancel();
    _midSessionRediscovery?.cancel();
    _midSessionRediscovery = null;
    _authRecheck?.cancel();
    unawaited(_socketSub?.cancel());
    unawaited(_failureSub?.cancel());
    // Stops the snapshot saves and the live listeners of the ended session.
    _ref.read(syncServiceProvider).onSignedOut();
    _ref.read(isAuthenticatedProvider.notifier).state = false;
    // A half-made ticket sale may hold a guest's name and phone.
    _ref.read(ticketIssueFormProvider.notifier).clear();
    _ref.read(offlineResumedProvider.notifier).state = false;
    _ref.read(socketServiceProvider).disconnect();
    // The next pairing may be on another network entirely.
    _wifiBound = false;
    await _ref.read(wifiBindingProvider).unbind();
    await SessionService().clearPairing();
    // The slips owed to guests hold their names and admission codes, and
    // belong to the desk being left. (An unanswered sale or Pay & Fire is
    // kept: its own desk and operator get it back.)
    await _ref.read(pendingSlipsStoreProvider).wipe();
    state = const BootstrapNoPairing();
  }

  @override
  void dispose() {
    _connectTimeout?.cancel();
    _midSessionRediscovery?.cancel();
    _authRecheck?.cancel();
    _socketSub?.cancel();
    _failureSub?.cancel();
    super.dispose();
  }
}
