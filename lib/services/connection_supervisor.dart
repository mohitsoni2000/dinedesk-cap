import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'connection_health.dart';
import 'link_monitor.dart';
import 'log.dart';
import 'socket_service.dart';

const String _tag = '[Supervisor]';

/// Watches the link to the desk and repairs it faster than the transport can
/// on its own.
///
/// [SocketService] deliberately stays a dumb transport and [ConnectionBootstrap]
/// owns the pairing lifecycle; this sits between them and owns what neither had
/// a home for:
///
/// - **Liveness.** socket.io only learns a connection is dead when the desk's
///   heartbeat lapses (`pingInterval + pingTimeout` away). A cheap app-level
///   heartbeat turns that ambiguity into seconds. What a missed beat *means* is
///   decided by the [LinkMonitor] (suspect → probe → dead), not here: one missed
///   beat used to be a verdict, and the verdict was a full socket teardown.
/// - **Link measurement.** Every ack that comes back feeds an [RttTracker], and
///   every ack that does not feeds it a censored sample at the timeout. The
///   estimate survives socket blips and is reset only when the network identity
///   or the desk host changes (a different path).
/// - **Network changes.** connectivity_plus and the native Wi-Fi binding both
///   feed the monitor; a change is suspicion while connected and an immediate
///   redial while not.
class ConnectionSupervisor {
  ConnectionSupervisor(this._ref);

  final Ref _ref;
  final RttTracker _rtt = RttTracker();
  late final AdaptiveTimeoutPolicy _policy = AdaptiveTimeoutPolicy(_rtt);

  LinkMonitor? _monitor;

  /// The monitor, once [start] has run. Exposed for the lifecycle hook in
  /// `main.dart` (`onResume`); the banner's "Retry now" goes through [retryNow].
  LinkMonitor get monitor => _monitor!;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<NetworkEvent>? _wifiSub;
  StreamSubscription<SocketState>? _socketSub;
  Timer? _heartbeatTimer;
  Timer? _connectivityDebounce;

  bool _started = false;
  bool _appForeground = true;

  /// Cleared the first time a heartbeat goes unanswered on a desk that is
  /// demonstrably reachable and has never answered one — see the monitor's
  /// probe. Stays cleared for the life of the app process: the alternative is
  /// re-paying the probe on every reconnect for every desk that will never
  /// answer, and the fallback is simply the behaviour this app shipped with
  /// before heartbeats existed (such a desk is never declared dead from
  /// heartbeat silence).
  bool _heartbeatSupported = true;
  int _heartbeatSuccesses = 0;

  /// On a slow link [_policy] can widen a beat's timeout past the interval
  /// between beats; don't stack overlapping probes.
  bool _beatInFlight = false;

  String? _rttHost;
  String? _networkId;
  String? _connectivitySignature;

  static const Duration _foregroundInterval = Duration(seconds: 12);
  static const Duration _backgroundInterval = Duration(seconds: 30);
  static const Duration _heartbeatBaseTimeout = Duration(seconds: 5);

  /// Connectivity streams are chatty — an interface change can arrive as three
  /// events in as many hundred milliseconds. Let it settle before dialling.
  static const Duration _connectivitySettle = Duration(milliseconds: 600);

  static const String heartbeatEvent = 'operator:heartbeat';

  void start() {
    if (_started) return;
    _started = true;

    final socket = _ref.read(socketServiceProvider);
    socket.timeoutPolicy = _policy;
    socket.onAckRtt = _rtt.record;

    final monitor = _monitor = LinkMonitor(
      probeHeartbeat: _probeHeartbeat,
      probePing: _probePing,
      nudgeEngine: (why) =>
          _ref.read(socketServiceProvider).nudgeEngine('monitor: $why'),
      // `automatic`: the ladder is not a person, so it must never resurrect a
      // pairing the desk refused (see ConnectionBootstrap.retry).
      retryConnect: () =>
          _ref.read(connectionBootstrapProvider.notifier).retry(automatic: true),
      standDown: () =>
          _ref.read(connectionBootstrapProvider.notifier).isStoodDown,
      rediscover: () =>
          _ref.read(connectionBootstrapProvider.notifier).rediscoverNow(),
      reconnectIfNeeded: () =>
          _ref.read(socketServiceProvider).reconnectIfNeeded(),
      heartbeatSupported: () => _heartbeatSupported,
      heartbeatProven: () => _heartbeatSuccesses > 0,
      onHeartbeatUnsupported: () {
        logD(_tag, 'desk has no $heartbeatEvent handler — heartbeat disabled');
        _heartbeatSupported = false;
        _stopHeartbeat();
      },
      ackTimeoutFor: _policy.forAck,
      onHealthChanged: (health) {
        _ref.read(linkHealthProvider.notifier).state = health;
      },
      log: (message) => logD(_tag, message),
    );

    // A timeout is evidence, not a verdict: feed the estimate (censored at the
    // timeout) and let the monitor decide whether to probe.
    socket.onAckTimeout = (event, timeout) {
      _rtt.recordTimeout(timeout);
      monitor.onAckTimeout(event);
    };

    _socketSub = socket.stateStream.listen(_onSocketState);

    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged, onError: (Object err) {
      logE(_tag, 'connectivity stream failed', err);
    });

    _wifiSub = _ref.read(wifiBindingProvider).events.listen(
      _onWifiEvent,
      onError: (Object err) {
        logE(_tag, 'wifi binding events failed', err);
      },
    );

    logD(_tag, 'watching');
  }

  /// Driven by the app lifecycle in `main.dart`. Only affects how often the
  /// heartbeat fires; the session itself is unaffected.
  void setAppForeground(bool foreground) {
    if (_appForeground == foreground) return;
    _appForeground = foreground;
    if (_heartbeatTimer != null) _restartHeartbeat();
  }

  /// The banner's "Retry now" and the disconnected screen's "Try reconnect": do
  /// everything that could help, immediately. A person pressed it, so the
  /// bootstrap retry is deliberately not `automatic` and goes through even for
  /// a pairing the desk refused.
  void retryNow() {
    final socket = _ref.read(socketServiceProvider);
    if (socket.state == SocketState.verified) {
      _monitor?.probeNow();
      return;
    }
    socket.reconnectIfNeeded();
    _ref.read(connectionBootstrapProvider.notifier).retry();
  }

  /// Whether the socket was verified before it last dropped: only then did the
  /// desk vouch for the operator moments ago (see `touchOfflineSession`).
  bool _wasVerified = false;

  void _onSocketState(SocketState state) {
    _monitor?.onSocketState(state);
    if (state == SocketState.verified) {
      _wasVerified = true;
      _restartHeartbeat();
    } else if (state == SocketState.disconnected) {
      _stopHeartbeat();
      // The last moment the desk was demonstrably with this phone — what a
      // cold start offline measures its grace window from.
      // Not after a revocation / sign-out: then the desk did NOT vouch for the
      // operator and there is no session to refresh (SyncService gates the
      // write too; this keeps the intent explicit).
      if (_wasVerified) {
        _wasVerified = false;
        if (!_ref.read(forceDisconnectedProvider)) {
          _ref.read(syncServiceProvider).touchOfflineSession(force: true);
        }
      }
    } else if (state == SocketState.connecting) {
      _resetRttIfHostChanged();
    }
  }

  void _resetRttIfHostChanged() {
    final pairing =
        _ref.read(connectionBootstrapProvider.notifier).currentPairing;
    if (pairing == null) return;
    final host = '${pairing.host}:${pairing.port}';
    if (_rttHost != null && _rttHost != host) {
      logD(_tag, 'desk host changed — link estimate reset');
      _rtt.reset();
    }
    _rttHost = host;
  }

  // ---------------------------------------------------------------- heartbeat

  void _restartHeartbeat() {
    _stopHeartbeat();
    if (!_heartbeatSupported) return;
    final interval = _appForeground ? _foregroundInterval : _backgroundInterval;
    _heartbeatTimer = Timer.periodic(interval, (_) => unawaited(_beat()));
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// One scheduled beat. Its outcome only ever *informs* the monitor.
  Future<void> _beat() async {
    if (_beatInFlight) return;
    final socket = _ref.read(socketServiceProvider);
    if (socket.state != SocketState.verified) return;
    // A re-verify streams a sync-sized reply that this ack would queue behind.
    if (socket.isVerifyInFlight) return;
    // Don't pile a routine beat onto an investigation already under way.
    if (_monitor?.health != LinkHealth.healthy) return;
    _beatInFlight = true;
    try {
      final ok = await _probeHeartbeat(_policy.forAck(_heartbeatBaseTimeout));
      _monitor?.onBeat(ok: ok);
      // A beat the desk answered is fresh evidence for the offline session
      // (throttled to once a minute inside).
      if (ok) _ref.read(syncServiceProvider).touchOfflineSession();
    } finally {
      _beatInFlight = false;
    }
  }

  /// One heartbeat round trip; true iff the desk answered in time.
  /// emitAckProbe, not emitAck: silence here is ambiguous (an old desk never
  /// answers) and must not report itself as an ack timeout.
  Future<bool> _probeHeartbeat(Duration timeout) async {
    final socket = _ref.read(socketServiceProvider);
    if (socket.state != SocketState.verified) return false;
    // While a verify owns the socket its reply hogs the link; the verify has
    // its own drop detection. Treat as alive rather than risk a teardown.
    if (socket.isVerifyInFlight) return true;
    final response = await socket.emitAckProbe(
      heartbeatEvent,
      const <String, dynamic>{},
      timeout: timeout,
    );
    final ok = !isTransportFailure(response);
    if (ok) {
      _heartbeatSuccesses++;
    } else {
      _rtt.recordTimeout(timeout);
    }
    return ok;
  }

  Future<bool> _probePing(Duration timeout) async {
    final pairing =
        _ref.read(connectionBootstrapProvider.notifier).currentPairing;
    if (pairing == null) return false;
    final result =
        await SocketService.ping(pairing.host, pairing.port, timeout: timeout);
    return result is PingOk;
  }

  // ------------------------------------------------------------- connectivity

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasNetwork =
        results.any((result) => result != ConnectivityResult.none);
    logD(_tag, 'connectivity: ${results.map((r) => r.name).join(",")}');
    _connectivityDebounce?.cancel();

    final signature = (results.map((r) => r.name).toList()..sort()).join(',');
    if (_connectivitySignature != null && _connectivitySignature != signature) {
      // A different kind of network (wifi <-> mobile): a different path.
      _rtt.reset();
    }
    _connectivitySignature = signature;

    if (!hasNetwork) {
      _monitor?.onNetworkEvent(const NetworkEvent(NetworkEventType.lost));
      return;
    }
    _connectivityDebounce = Timer(
      _connectivitySettle,
      () => _onNetworkAvailable(const NetworkEvent(NetworkEventType.changed)),
    );
  }

  /// Native Wi-Fi binding events. An `available`/`changed` with a *different*
  /// network id means the phone roamed to another AP or network: the old RTT
  /// history describes a path it is no longer on.
  void _onWifiEvent(NetworkEvent event) {
    final id = event.networkId;
    if (id != null &&
        event.type != NetworkEventType.lost &&
        _networkId != null &&
        _networkId != id) {
      logD(_tag, 'network identity changed — link estimate reset');
      _rtt.reset();
    }
    if (id != null && event.type != NetworkEventType.lost) _networkId = id;
    if (event.type == NetworkEventType.lost) {
      _monitor?.onNetworkEvent(event);
      return;
    }
    _onNetworkAvailable(event);
  }

  void _onNetworkAvailable(NetworkEvent event) {
    final socket = _ref.read(socketServiceProvider);
    _monitor?.onNetworkEvent(event);
    if (socket.state != SocketState.disconnected) return;
    logD(_tag, 'network available while disconnected — reconnecting now');
    // Nudge the existing socket first: if the desk never moved, this is the
    // whole fix and it lands in one round trip. The rescan behind it covers the
    // case where the address changed with the network.
    socket.reconnectIfNeeded();
    _ref.read(connectionBootstrapProvider.notifier).onNetworkChanged();
  }

  void dispose() {
    _stopHeartbeat();
    _connectivityDebounce?.cancel();
    _monitor?.dispose();
    unawaited(_socketSub?.cancel());
    unawaited(_connectivitySub?.cancel());
    unawaited(_wifiSub?.cancel());
    try {
      // Provider teardown order isn't guaranteed — the socket may already be
      // disposed. Restoring its defaults is tidiness, not correctness.
      final socket = _ref.read(socketServiceProvider);
      socket.timeoutPolicy = const FixedTimeoutPolicy();
      socket.onAckRtt = null;
      socket.onAckTimeout = null;
    } catch (_) {}
    _started = false;
  }
}
