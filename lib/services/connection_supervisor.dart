import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';
import 'app_messenger.dart';
import 'connection_health.dart';
import 'log.dart';
import 'network_keepalive.dart';
import 'socket_service.dart';

const String _tag = '[Supervisor]';

/// Watches the link to the desk and repairs it faster than the transport can
/// on its own.
///
/// [SocketService] deliberately stays a dumb transport and [ConnectionBootstrap]
/// owns the pairing lifecycle; this sits between them and owns the three things
/// neither had a home for:
///
/// - **Liveness.** socket.io only learns a connection is dead when the desk's
///   heartbeat lapses, `pingInterval + pingTimeout` = 40s away. Before this,
///   the app's own first hint was an operator tapping something and waiting out
///   an ack timeout — the connection was dead, but it looked like the app was
///   hanging. A cheap app-level heartbeat turns 40s of ambiguity into ~5s.
/// - **Link measurement.** Every ack that comes back feeds an [RttTracker],
///   which widens the app's timeouts on a slow LAN instead of failing requests
///   that were merely late. See [AdaptiveTimeoutPolicy].
/// - **Network changes.** Wi-Fi coming back is the single most useful signal
///   available for "try again now", and nothing was listening for it. socket.io
///   just kept dialling on its own blind schedule.
class ConnectionSupervisor {
  ConnectionSupervisor(this._ref);

  final Ref _ref;
  final RttTracker _rtt = RttTracker();
  late final AdaptiveTimeoutPolicy _policy = AdaptiveTimeoutPolicy(_rtt);

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<SocketState>? _socketSub;
  Timer? _heartbeatTimer;
  Timer? _connectivityDebounce;

  bool _started = false;
  bool _appForeground = true;

  /// Cleared the first time a heartbeat goes unanswered on a desk that is
  /// demonstrably reachable — see [_onHeartbeatSilence]. Stays cleared for the
  /// life of the app process, so a desk upgraded mid-shift only regains
  /// heartbeats after the operator next relaunches. That is deliberate: the
  /// alternative is re-paying the ~5s probe on every reconnect for every desk
  /// that will never answer, and the fallback in the meantime is simply the
  /// behaviour this app shipped with before heartbeats existed.
  bool _heartbeatSupported = true;
  int _heartbeatSuccesses = 0;

  /// On a slow link [_policy] can widen a beat's timeout past the interval
  /// between beats. Without this the timer would stack overlapping probes and,
  /// on a genuine outage, fire [_onHeartbeatSilence] — and so a full reconnect —
  /// several times over for the same failure.
  bool _beatInFlight = false;

  /// Tight enough that a dead link is caught within a few seconds of the
  /// operator's next glance at the screen, loose enough to be invisible on the
  /// battery. Backgrounded, nobody is looking, so the interval relaxes.
  static const Duration _foregroundInterval = Duration(seconds: 12);
  static const Duration _backgroundInterval = Duration(seconds: 30);

  /// Base for the heartbeat's own ack timeout, before the measured link widens
  /// it. Small: a heartbeat is one round trip with an empty payload.
  static const Duration _heartbeatBaseTimeout = Duration(seconds: 5);

  /// Connectivity streams are chatty — an interface change can arrive as three
  /// events in as many hundred milliseconds. Let it settle before dialling.
  static const Duration _connectivitySettle = Duration(milliseconds: 600);

  static const String heartbeatEvent = 'operator:heartbeat';

  static const String _batteryPromptKey = 'battery_opt_prompted';

  void start() {
    if (_started) return;
    _started = true;

    final socket = _ref.read(socketServiceProvider);
    socket.timeoutPolicy = _policy;
    socket.onAckRtt = _rtt.record;

    _socketSub = socket.stateStream.listen(_onSocketState);

    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged, onError: (Object err) {
      logE(_tag, 'connectivity stream failed', err);
    });

    // Unpair, an admin kick, or an expired token all land here. The foreground
    // service has nothing left to keep alive at that point, and leaving its
    // notification in the shade would be a lie.
    _ref.listen<bool>(isAuthenticatedProvider, (_, authed) {
      if (!authed) unawaited(NetworkKeepAlive.stop());
    });

    logD(_tag, 'watching');
  }

  /// Driven by the app lifecycle in `main.dart`. Only affects which Wi-Fi lock
  /// the Android service holds and how often the heartbeat fires; the session
  /// itself is unaffected.
  void setAppForeground(bool foreground) {
    if (_appForeground == foreground) return;
    _appForeground = foreground;
    unawaited(NetworkKeepAlive.setAppForeground(foreground));
    if (_heartbeatTimer != null) _restartHeartbeat();
  }

  void _onSocketState(SocketState state) {
    if (state == SocketState.verified) {
      unawaited(_onSessionUp());
      _restartHeartbeat();
    } else if (state == SocketState.disconnected) {
      _stopHeartbeat();
      // The estimate belongs to a link that is gone. Carrying it across a
      // reconnect would size the new link's timeouts off the old one's worst
      // moments — which, since the estimate is built from the traffic just
      // before a failure, are always the worst moments it ever saw.
      _rtt.reset();
    }
  }

  Future<void> _onSessionUp() async {
    if (NetworkKeepAlive.isRunning) return;
    final name = _ref.read(restaurantProvider)?.name;
    final started = await NetworkKeepAlive.start(restaurant: name);
    if (!started) return;
    await NetworkKeepAlive.setAppForeground(_appForeground);
    unawaited(_maybeAskForBatteryExemption());
  }

  /// Once per install, and only if the OS says the exemption is actually
  /// missing. Deliberately after the session is up rather than during pairing:
  /// at this point the operator has a working app in front of them, so the ask
  /// reads as "keep this working" instead of one more hurdle before it does.
  Future<void> _maybeAskForBatteryExemption() async {
    if (await NetworkKeepAlive.isIgnoringBatteryOptimizations()) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryPromptKey) ?? false) return;
    await prefs.setBool(_batteryPromptKey, true);

    // Let the tables screen settle first — this lands right after login, where
    // the update dialog may also be queuing for the same navigator.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (_ref.read(socketServiceProvider).state != SocketState.verified) return;

    showBatteryOptimizationDialog(
      onOpenSettings: () =>
          unawaited(NetworkKeepAlive.openBatteryOptimizationSettings()),
    );
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

  Future<void> _beat() async {
    if (_beatInFlight) return;
    final socket = _ref.read(socketServiceProvider);
    if (socket.state != SocketState.verified) return;
    _beatInFlight = true;
    try {
      // emitAckProbe, not emitAck: silence here is ambiguous (see
      // [_onHeartbeatSilence]) and must not be allowed to tear the session down
      // by itself.
      final response = await socket.emitAckProbe(
        heartbeatEvent,
        const <String, dynamic>{},
        timeout: _policy.forAck(_heartbeatBaseTimeout),
      );

      if (!isTransportFailure(response)) {
        _heartbeatSuccesses++;
        return;
      }
      await _onHeartbeatSilence(socket);
    } finally {
      _beatInFlight = false;
    }
  }

  /// A heartbeat went unanswered. That means one of two very different things,
  /// and guessing wrong is expensive either way:
  ///
  /// - the socket is a zombie and the session needs rebuilding, or
  /// - this desk is running a build older than [heartbeatEvent], so it will
  ///   *never* answer, and tearing down on that would put every un-upgraded
  ///   desk into a permanent reconnect loop of our own making.
  ///
  /// Only the first failure is ambiguous — a desk that has answered before
  /// clearly supports the event, so silence from it now is real. For that first
  /// one, the unauthenticated HTTP `/ping` endpoint (present on every desk
  /// build) settles it: reachable means the desk is fine and simply doesn't
  /// know this event, so stand down permanently and let the pre-existing
  /// timeout paths do their job.
  Future<void> _onHeartbeatSilence(SocketService socket) async {
    if (_heartbeatSuccesses == 0) {
      final pairing = _ref.read(connectionBootstrapProvider.notifier).currentPairing;
      if (pairing != null) {
        final reachable = await SocketService.ping(pairing.host, pairing.port);
        if (reachable is PingOk) {
          logD(_tag, 'desk has no $heartbeatEvent handler — heartbeat disabled');
          _heartbeatSupported = false;
          _stopHeartbeat();
          return;
        }
      }
    }

    logD(_tag, 'heartbeat unanswered — treating the socket as dead');
    socket.markDead();
    _ref.read(connectionBootstrapProvider.notifier).retry();
  }

  // ------------------------------------------------------------- connectivity

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasNetwork =
        results.any((result) => result != ConnectivityResult.none);
    logD(_tag, 'connectivity: ${results.map((r) => r.name).join(",")}');
    _connectivityDebounce?.cancel();
    if (!hasNetwork) return;
    _connectivityDebounce = Timer(_connectivitySettle, _onNetworkAvailable);
  }

  void _onNetworkAvailable() {
    final socket = _ref.read(socketServiceProvider);
    if (socket.state != SocketState.disconnected) return;
    logD(_tag, 'network available while disconnected — reconnecting now');
    _rtt.reset();
    // Nudge the existing socket first: if the desk never moved, this is the
    // whole fix and it lands in one round trip. The rescan behind it covers the
    // case where the address changed with the network.
    socket.reconnectIfNeeded();
    _ref.read(connectionBootstrapProvider.notifier).onNetworkChanged();
  }

  void dispose() {
    _stopHeartbeat();
    _connectivityDebounce?.cancel();
    unawaited(_socketSub?.cancel());
    unawaited(_connectivitySub?.cancel());
    unawaited(NetworkKeepAlive.stop());
    try {
      // Provider teardown order isn't guaranteed — the socket may already be
      // disposed. Restoring its defaults is tidiness, not correctness.
      final socket = _ref.read(socketServiceProvider);
      socket.timeoutPolicy = const FixedTimeoutPolicy();
      socket.onAckRtt = null;
    } catch (_) {}
    _started = false;
  }
}
