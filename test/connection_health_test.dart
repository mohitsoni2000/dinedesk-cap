import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/connection_health.dart';

void main() {
  group('RttTracker', () {
    test('reports no estimate until it has seen enough samples', () {
      final tracker = RttTracker();
      expect(tracker.p95, isNull);
      tracker.record(const Duration(milliseconds: 40));
      tracker.record(const Duration(milliseconds: 50));
      // One or two samples on a link that has barely been used is not evidence
      // of anything — widening every timeout off them would be worse than the
      // fixed defaults.
      expect(tracker.p95, isNull);
    });

    test('estimates from the slow tail, not the average', () {
      final tracker = RttTracker();
      // A link that is usually quick but occasionally stalls: the timeout has
      // to cover the stall, so the mean (~200ms) is the wrong statistic.
      for (var i = 0; i < 9; i++) {
        tracker.record(const Duration(milliseconds: 50));
      }
      tracker.record(const Duration(milliseconds: 1600));
      expect(tracker.p95!.inMilliseconds, greaterThan(1000));
    });

    test('forgets old samples so a recovered link tightens back up', () {
      final tracker = RttTracker();
      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(milliseconds: 2000));
      }
      expect(tracker.p95!.inMilliseconds, greaterThan(1500));

      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(milliseconds: 30));
      }
      expect(tracker.p95!.inMilliseconds, lessThan(100));
    });

    test('reset clears the estimate', () {
      final tracker = RttTracker();
      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(milliseconds: 500));
      }
      expect(tracker.p95, isNotNull);
      tracker.reset();
      expect(tracker.p95, isNull);
    });
  });

  group('AdaptiveTimeoutPolicy', () {
    test('never returns less than the caller-supplied base', () {
      final tracker = RttTracker();
      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(milliseconds: 15));
      }
      final policy = AdaptiveTimeoutPolicy(tracker);
      // A fast LAN must not shrink the ack timeout below the value the call
      // site asked for — tightening it buys nothing and only adds flakiness.
      expect(
        policy.forAck(const Duration(seconds: 4)),
        const Duration(seconds: 4),
      );
    });

    test('widens the base once the link is measurably slow', () {
      final tracker = RttTracker();
      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(milliseconds: 2200));
      }
      final policy = AdaptiveTimeoutPolicy(tracker);
      final widened = policy.forAck(const Duration(seconds: 4));
      expect(widened, greaterThan(const Duration(seconds: 4)));
    });

    test('caps the ack timeout below the desk heartbeat ceiling', () {
      final tracker = RttTracker();
      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(seconds: 30));
      }
      final policy = AdaptiveTimeoutPolicy(tracker);
      // The desk kills a socket at pingInterval + pingTimeout (40s). An app
      // timeout above that would let the transport give up first, which is the
      // failure mode syncBundledAckTimeout's comment warns about.
      expect(
        policy.forAck(const Duration(seconds: 4)),
        lessThanOrEqualTo(AdaptiveTimeoutPolicy.ackCeiling),
      );
    });

    test('falls back to the base while there is no estimate', () {
      final policy = AdaptiveTimeoutPolicy(RttTracker());
      expect(
        policy.forAck(const Duration(seconds: 4)),
        const Duration(seconds: 4),
      );
      expect(
        policy.forConnect(const Duration(seconds: 3)),
        const Duration(seconds: 3),
      );
    });

    test('widens the connect timeout on a slow link, within its own cap', () {
      final tracker = RttTracker();
      for (var i = 0; i < RttTracker.window; i++) {
        tracker.record(const Duration(milliseconds: 1800));
      }
      final policy = AdaptiveTimeoutPolicy(tracker);
      final connect = policy.forConnect(const Duration(seconds: 3));
      expect(connect, greaterThan(const Duration(seconds: 3)));
      expect(connect, lessThanOrEqualTo(AdaptiveTimeoutPolicy.connectCeiling));
    });
  });

  group('FixedTimeoutPolicy', () {
    test('passes every base through untouched', () {
      const policy = FixedTimeoutPolicy();
      expect(
        policy.forAck(const Duration(seconds: 7)),
        const Duration(seconds: 7),
      );
      expect(
        policy.forConnect(const Duration(seconds: 3)),
        const Duration(seconds: 3),
      );
    });
  });
}
