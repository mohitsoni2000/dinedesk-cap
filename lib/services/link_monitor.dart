import 'dart:async';
import 'dart:math' as math;

import 'socket_service.dart' show SocketState;

/// How trustworthy the path to the desk looks right now.
///
/// - [healthy]: traffic is flowing (or nothing has suggested otherwise).
/// - [suspect]: something looked wrong (an ack timed out, a heartbeat was
///   missed, the network changed, the app just woke up) and the monitor is
///   probing to find out. The session is NOT torn down while suspect: a slow
///   reply on a weak link is not a dead link, and tearing the socket down on it
///   is what used to cost a full resync on every blip.
/// - [dead]: proven down — the socket reported a disconnect, or probing showed
///   the connection is half-open. The escalation ladder is running.
enum LinkHealth { healthy, suspect, dead }

enum NetworkEventType { available, lost, changed }

/// An OS-level network change, from connectivity_plus or from the native
/// Wi-Fi binding (`wifi_binding.dart`). Lives here, not there, so the monitor
/// stays free of Flutter imports.
class NetworkEvent {
  final NetworkEventType type;

  /// Identity of the network involved (Android `Network.toString()`), when the
  /// platform can supply one. A change of identity is what means "roamed to a
  /// different AP/network" — the link's RTT history no longer applies.
  final String? networkId;

  const NetworkEvent(this.type, {this.networkId});

  /// Parses the `{type, networkId}` map the native EventChannel emits. Unknown
  /// shapes yield null instead of throwing: a platform glitch must never take
  /// the monitor down.
  static NetworkEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final type = switch (raw['type']) {
      'available' => NetworkEventType.available,
      'lost' => NetworkEventType.lost,
      'changed' => NetworkEventType.changed,
      _ => null,
    };
    if (type == null) return null;
    final id = raw['networkId'];
    return NetworkEvent(type, networkId: id is String ? id : null);
  }

  @override
  String toString() => 'NetworkEvent(${type.name}, $networkId)';
}

/// Every duration the monitor uses, in one place so tests (and tuning) don't
/// have to chase literals.
class LinkMonitorConfig {
  const LinkMonitorConfig({
    this.minProbeGap = const Duration(seconds: 2),
    this.heartbeatTimeout = const Duration(seconds: 3),
    this.pingTimeout = const Duration(seconds: 2),
    this.retryGap = const Duration(milliseconds: 1500),
    this.unsupportedRetryGap = const Duration(seconds: 10),
    this.resumeThreshold = const Duration(seconds: 20),
    this.nudgeWait = const Duration(seconds: 12),
    this.retryWait = const Duration(seconds: 15),
    this.watchdogInterval = const Duration(seconds: 5),
    this.ladderBackoff = const <Duration>[
      Duration(seconds: 3),
      Duration(seconds: 6),
      Duration(seconds: 12),
      Duration(seconds: 20),
      Duration(seconds: 30),
    ],
  });

  /// Minimum spacing between two probe rounds.
  final Duration minProbeGap;

  /// Base ack timeout of the probing heartbeat (widened by the link policy).
  final Duration heartbeatTimeout;

  /// Timeout of the HTTP `/ping` that runs in parallel with it.
  final Duration pingTimeout;

  /// Pause after a round where both probes failed, before the confirming one.
  final Duration retryGap;

  /// Re-probe cadence on a desk that never answers heartbeats.
  final Duration unsupportedRetryGap;

  /// Backgrounded for longer than this => probe on resume.
  final Duration resumeThreshold;

  /// Ladder step 1: how long to wait for a nudged engine to reconnect.
  final Duration nudgeWait;

  /// Ladder steps 2-3: how long to wait for each heavier retry.
  final Duration retryWait;

  /// How often the watchdog pokes an idle, disconnected socket.
  final Duration watchdogInterval;

  /// Pause between rounds of the never-ending ladder tail.
  final List<Duration> ladderBackoff;
}

/// Decides whether the link to the desk is really down, and drives recovery
/// until it is back. Pure Dart: no Riverpod, no Flutter, and every effect
/// (probes, nudges, reconnects) is an injected callback, so the whole policy is
/// unit-testable with a fake clock.
///
/// The ground rules it exists to enforce:
/// - **One bad signal is only suspicion.** Ack timeouts, missed heartbeats and
///   network events move the link to [LinkHealth.suspect] and trigger probing;
///   they never tear anything down by themselves.
/// - **A half-open link is proven, not guessed.** A missed heartbeat while the
///   desk's HTTP `/ping` answers means the TCP session is dead but the desk is
///   fine — dead immediately. Both failing twice in a row is dead too.
/// - **Dead never gives up.** The ladder escalates (nudge the engine → rebuild
///   the connection → rediscover the desk) and then loops with backoff forever;
///   the old "stuck on Reconnecting… until the app is restarted" state cannot
///   occur because nothing in here ever stops trying.
class LinkMonitor {
  LinkMonitor({
    required this.probeHeartbeat,
    required this.probePing,
    required this.nudgeEngine,
    required this.retryConnect,
    required this.rediscover,
    required this.reconnectIfNeeded,
    this.heartbeatSupported = _always,
    this.heartbeatProven = _never,
    this.onHeartbeatUnsupported,
    this.ackTimeoutFor = _identity,
    this.onHealthChanged,
    this.config = const LinkMonitorConfig(),
    DateTime Function()? now,
    void Function(String message)? log,
  })  : _now = now ?? DateTime.now,
        _log = log ?? _noLog;

  /// Sends the app-level heartbeat; true iff an ack came back in time.
  final Future<bool> Function(Duration timeout) probeHeartbeat;

  /// Plain HTTP `/ping` to the desk; true iff it answered in time.
  final Future<bool> Function(Duration timeout) probePing;

  /// Ladder step 1: close the engine under the live socket (keeps recovery).
  /// Returns false when it declined to act (a PIN verify is in flight).
  final bool Function(String why) nudgeEngine;

  /// Ladder step 2: rebuild the connection from scratch (bootstrap.retry).
  final void Function() retryConnect;

  /// Ladder step 3: look for the desk on the LAN (it may have moved).
  final Future<void> Function() rediscover;

  /// Idempotent "if socket.io isn't already redialling, poke it".
  final void Function() reconnectIfNeeded;

  /// False once this desk is known never to answer heartbeats (old build).
  final bool Function() heartbeatSupported;

  /// True once this desk has answered a heartbeat at least once.
  final bool Function() heartbeatProven;

  /// Called when a missed heartbeat on a reachable, never-answered desk shows
  /// it simply doesn't speak the event.
  final void Function()? onHeartbeatUnsupported;

  /// Link-adaptive widening of a base ack timeout ([TimeoutPolicy.forAck]).
  final Duration Function(Duration base) ackTimeoutFor;

  final void Function(LinkHealth health)? onHealthChanged;

  final LinkMonitorConfig config;

  final DateTime Function() _now;
  final void Function(String message) _log;

  static bool _always() => true;
  static bool _never() => false;
  static Duration _identity(Duration d) => d;
  static void _noLog(String _) {}

  LinkHealth _health = LinkHealth.healthy;
  LinkHealth get health => _health;

  SocketState _state = SocketState.disconnected;

  bool _disposed = false;
  bool _probing = false;
  bool get isProbing => _probing;
  DateTime? _lastProbeAt;

  /// Bumped whenever outstanding probes stop being relevant.
  int _probeEpoch = 0;

  /// Bumped whenever the ladder should stop (connected) or restart.
  int _ladderEpoch = 0;
  bool _ladderActive = false;
  bool get isLadderRunning => _ladderActive;

  Timer? _watchdog;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  // ------------------------------------------------------------------ inputs

  /// An ack (not a probe) timed out.
  void onAckTimeout(String event) {
    if (_state != SocketState.verified) return;
    _suspect('ack timeout on $event');
  }

  /// The supervisor's periodic heartbeat result.
  void onBeat({required bool ok}) {
    if (_state != SocketState.verified) return;
    if (ok) {
      if (_health == LinkHealth.suspect) {
        _probeEpoch++;
        _setHealth(LinkHealth.healthy, 'heartbeat answered');
      }
    } else {
      _suspect('missed heartbeat');
    }
  }

  void onSocketState(SocketState next) {
    if (_disposed) return;
    final prev = _state;
    _state = next;
    _changes.add(null);
    switch (next) {
      case SocketState.verified:
      case SocketState.connected:
        // Connected is proof enough that the path works (a handshake just
        // crossed it); the heavier verified step belongs to the bootstrap.
        _probeEpoch++;
        _ladderEpoch++;
        _ladderActive = false;
        _stopWatchdog();
        _setHealth(LinkHealth.healthy, 'socket ${next.name}');
      case SocketState.connecting:
        break;
      case SocketState.disconnected:
        if (prev == SocketState.disconnected) return;
        _probeEpoch++;
        _setHealth(LinkHealth.dead, 'socket disconnected');
        _startWatchdog();
        // The socket dropped by itself, so socket.io is already redialling:
        // the ladder gives that its window before escalating.
        unawaited(_runLadder(nudgeFirst: false));
    }
  }

  /// The OS (or the native Wi-Fi binding) reported a network change.
  void onNetworkEvent(NetworkEvent event) {
    if (_disposed) return;
    if (_state == SocketState.verified) {
      _suspect('network ${event.type.name}');
    } else if (_state == SocketState.disconnected &&
        event.type != NetworkEventType.lost) {
      _log('network ${event.type.name} while disconnected — poking now');
      reconnectIfNeeded();
      _restartLadder();
    }
  }

  /// An explicit "check the link now" (the banner's Retry action while the
  /// link merely looks weak).
  void probeNow() => _suspect('manual probe');

  /// The app returned to the foreground after [backgroundedFor].
  void onResume(Duration backgroundedFor) {
    if (_disposed) return;
    if (_state == SocketState.verified) {
      if (backgroundedFor > config.resumeThreshold) {
        _suspect('resumed after ${backgroundedFor.inSeconds}s in background');
      }
    } else if (_state == SocketState.disconnected) {
      reconnectIfNeeded();
      _restartLadder();
    }
  }

  // ----------------------------------------------------------------- probing

  void _suspect(String why) {
    if (_disposed || _state != SocketState.verified) return;
    if (_health == LinkHealth.dead) return;
    if (_health == LinkHealth.healthy) {
      _setHealth(LinkHealth.suspect, why);
    }
    unawaited(_probe());
  }

  bool _probeAlive(int epoch) =>
      !_disposed && epoch == _probeEpoch && _state == SocketState.verified;

  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    final epoch = _probeEpoch;
    try {
      var failures = 0;
      while (_probeAlive(epoch) && _health == LinkHealth.suspect) {
        final last = _lastProbeAt;
        if (last != null) {
          final gap = _now().difference(last);
          if (gap < config.minProbeGap) {
            await Future<void>.delayed(config.minProbeGap - gap);
            if (!_probeAlive(epoch)) return;
          }
        }
        _lastProbeAt = _now();

        final supported = heartbeatSupported();
        // In parallel: the heartbeat proves the socket.io session, /ping proves
        // the desk is reachable at all. Their disagreement is the diagnosis.
        final beat = supported
            ? probeHeartbeat(ackTimeoutFor(config.heartbeatTimeout))
            : Future<bool>.value(false);
        final ping = probePing(config.pingTimeout);
        final beatOk = await beat;
        final pingOk = await ping;
        if (!_probeAlive(epoch)) return;

        if (beatOk) {
          _setHealth(LinkHealth.healthy, 'probe heartbeat answered');
          return;
        }
        if (!supported) {
          // An old desk can't be proven dead by silence it was always going to
          // keep. Reachable => fine; unreachable => keep watching (the
          // engine's own ping timeout will end a genuinely dead socket).
          if (pingOk) {
            _setHealth(LinkHealth.healthy, '/ping ok on a heartbeat-less desk');
            return;
          }
          await Future<void>.delayed(config.unsupportedRetryGap);
          continue;
        }
        if (pingOk) {
          if (!heartbeatProven()) {
            // Never answered one: this desk just doesn't know the event.
            onHeartbeatUnsupported?.call();
            _setHealth(LinkHealth.healthy, 'desk has no heartbeat handler');
            return;
          }
          _goDead('half-open: heartbeat missed while /ping answers');
          return;
        }
        failures++;
        if (failures >= 2) {
          _goDead('heartbeat and /ping both failed twice');
          return;
        }
        await Future<void>.delayed(config.retryGap);
      }
    } finally {
      _probing = false;
    }
  }

  void _goDead(String why) {
    if (_disposed) return;
    _setHealth(LinkHealth.dead, why);
    _startWatchdog();
    unawaited(_runLadder(nudgeFirst: true, why: why));
  }

  // ------------------------------------------------------------------ ladder

  void _restartLadder() {
    _ladderEpoch++;
    _ladderActive = false;
    unawaited(_runLadder(nudgeFirst: false));
  }

  bool get _up =>
      _state == SocketState.connected || _state == SocketState.verified;

  Future<bool> _waitUp(Duration timeout) async {
    if (_up || _disposed) return true;
    final done = Completer<bool>();
    final sub = _changes.stream.listen((_) {
      if ((_up || _disposed) && !done.isCompleted) done.complete(true);
    });
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  /// Escalation, reset whenever the socket comes back up:
  ///  1. nudge the engine (keeps the session recoverable) and wait;
  ///  2. rebuild the connection (new session, full resync) and wait;
  ///  3. rediscover the desk, then keep cycling 2-3 with growing pauses.
  /// There is deliberately no terminal state.
  Future<void> _runLadder({required bool nudgeFirst, String? why}) async {
    if (_ladderActive || _disposed) return;
    _ladderActive = true;
    final epoch = _ladderEpoch;
    bool live() => !_disposed && epoch == _ladderEpoch;
    try {
      if (nudgeFirst) {
        _log('ladder 1: nudging the engine (${why ?? 'link dead'})');
        if (nudgeEngine(why ?? 'link dead')) {
          // The socket's own state event is still in flight; don't let the
          // wait below mistake the stale "verified" for a recovery.
          _state = SocketState.disconnected;
          _probeEpoch++;
        } else {
          // Declined (a verify owns the socket right now): the link is not
          // proven dead after all. Go back to suspecting and look again soon.
          _ladderActive = false;
          _setHealth(LinkHealth.suspect, 'nudge declined — re-probing');
          unawaited(Future<void>.delayed(config.minProbeGap).then((_) {
            if (_state == SocketState.verified && !_disposed) {
              unawaited(_probe());
            }
          }));
          return;
        }
      }
      if (await _waitUp(config.nudgeWait) || !live()) return;

      _log('ladder 2: rebuilding the connection');
      retryConnect();
      if (await _waitUp(config.retryWait) || !live()) return;

      _log('ladder 3: rediscovering the desk');
      await rediscover();
      if (!live() || _up) return;
      if (await _waitUp(config.retryWait) || !live()) return;

      var round = 0;
      while (live()) {
        final pause =
            config.ladderBackoff[math.min(round, config.ladderBackoff.length - 1)];
        round++;
        await Future<void>.delayed(pause);
        if (!live() || _up) return;
        _log('ladder loop #$round: retrying');
        retryConnect();
        if (await _waitUp(config.retryWait) || !live()) return;
        await rediscover();
        if (!live() || _up) return;
        if (await _waitUp(config.retryWait) || !live()) return;
      }
    } finally {
      if (epoch == _ladderEpoch) _ladderActive = false;
    }
  }

  // ---------------------------------------------------------------- watchdog

  void _startWatchdog() {
    if (_watchdog != null) return;
    _watchdog = Timer.periodic(config.watchdogInterval, (_) {
      if (_state == SocketState.disconnected) reconnectIfNeeded();
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  // ------------------------------------------------------------------- misc

  void _setHealth(LinkHealth next, String why) {
    if (_health == next) return;
    _log('link $_health -> $next ($why)');
    _health = next;
    onHealthChanged?.call(next);
  }

  void dispose() {
    _disposed = true;
    _probeEpoch++;
    _ladderEpoch++;
    _stopWatchdog();
    _changes.add(null);
    unawaited(_changes.close());
  }
}
