import 'dart:math' as math;

/// Rolling round-trip-time estimate for the socket link to the desk.
///
/// Exists because every timeout in this app was a constant sized for a healthy
/// single-AP LAN — `SocketService.connect`'s 3s handshake timeout and the 4s
/// [SocketService.ackTimeout] in particular. On the multi-AP restaurant LANs
/// this app actually runs on (a phone on one floor relaying through another
/// floor's router), a perfectly recoverable request routinely takes longer than
/// that, and the fixed timeout turns a slow reply into a hard failure the
/// operator has to retry by hand.
class RttTracker {
  /// Samples kept. Small enough that a link which recovers tightens back up
  /// within a few heartbeats rather than staying stretched for minutes.
  static const int window = 12;

  /// Below this, the sample set is too thin to justify moving off the caller's
  /// chosen default.
  static const int _minSamples = 4;

  final List<int> _samplesMs = <int>[];

  void record(Duration rtt) {
    _samplesMs.add(rtt.inMilliseconds);
    if (_samplesMs.length > window) _samplesMs.removeAt(0);
  }

  void reset() => _samplesMs.clear();

  /// Null until [_minSamples] have been seen.
  ///
  /// The slow tail rather than the mean: a link that is usually fast but
  /// stalls every tenth request needs timeouts that cover the stall, and an
  /// average hides exactly that.
  Duration? get p95 {
    if (_samplesMs.length < _minSamples) return null;
    final sorted = List<int>.from(_samplesMs)..sort();
    final index = ((sorted.length - 1) * 0.95).round();
    return Duration(milliseconds: sorted[index]);
  }
}

/// How a measured link translates into the timeouts [SocketService] uses.
/// Injected rather than baked in so the socket stays a dumb transport and the
/// adaptivity is unit-testable without a live connection.
abstract interface class TimeoutPolicy {
  Duration forAck(Duration base);
  Duration forConnect(Duration base);
}

/// The pre-existing behaviour: whatever the call site asked for.
class FixedTimeoutPolicy implements TimeoutPolicy {
  const FixedTimeoutPolicy();

  @override
  Duration forAck(Duration base) => base;

  @override
  Duration forConnect(Duration base) => base;
}

class AdaptiveTimeoutPolicy implements TimeoutPolicy {
  AdaptiveTimeoutPolicy(this._rtt);

  final RttTracker _rtt;

  /// Headroom over the observed slow tail. Four is deliberately generous:
  /// being too slow to fail costs one late error message, being too quick to
  /// fail costs the operator a re-tap on a request that was about to succeed.
  static const int _multiplier = 4;

  /// The desk drops a socket after `pingInterval + pingTimeout` = 40s
  /// (`operator-server.ts`). Every app-side timeout has to expire first, or the
  /// transport gives up underneath a request that was still in flight — the
  /// exact failure `SocketService.syncBundledAckTimeout` documents. 24s leaves
  /// the same kind of margin that value does.
  static const Duration ackCeiling = Duration(seconds: 24);

  /// A handshake that hasn't landed in 12s is not going to; past this point,
  /// rediscovery (the desk may have moved) beats waiting longer.
  static const Duration connectCeiling = Duration(seconds: 12);

  @override
  Duration forAck(Duration base) => _scaled(base, ackCeiling);

  @override
  Duration forConnect(Duration base) => _scaled(base, connectCeiling);

  /// Only ever widens. A fast link keeps the caller's default — shrinking
  /// timeouts on a good LAN buys nothing and adds flakiness the moment it
  /// briefly stops being good.
  Duration _scaled(Duration base, Duration ceiling) {
    final tail = _rtt.p95;
    if (tail == null) return base;
    final scaledMs = tail.inMilliseconds * _multiplier;
    final ms = math.min(
      math.max(base.inMilliseconds, scaledMs),
      ceiling.inMilliseconds,
    );
    // A ceiling lower than the caller's own base means the call site knows
    // something the estimate doesn't (the bundled-sync acks); honour the base.
    return Duration(milliseconds: math.max(ms, base.inMilliseconds));
  }
}
