import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/offline_session.dart';

/// canResumeOffline decides whether a cold-started phone may carry on without
/// asking the desk for a PIN. It must fail closed on every doubt.
void main() {
  final now = DateTime.utc(2026, 10, 5, 12);

  OfflineSession session({
    int grace = 30,
    Duration ago = const Duration(minutes: 10),
    String? desk = 'desk-1',
  }) =>
      OfflineSession(
        operatorId: 'op1',
        name: 'Asha',
        role: 'Waiter',
        shift: 'Day',
        deskInstanceId: desk,
        lastSeenAt: now.subtract(ago),
        pinGraceMinutes: grace,
      );

  group('canResumeOffline', () {
    test('no session -> no', () {
      expect(canResumeOffline(null, now), isFalse);
    });

    test('grace 0 means a PIN on every reconnect -> never resumable', () {
      expect(canResumeOffline(session(grace: 0, ago: Duration.zero), now),
          isFalse);
    });

    test('a negative grace is as bad as none', () {
      expect(canResumeOffline(session(grace: -5, ago: Duration.zero), now),
          isFalse);
    });

    test('inside the desk grace -> yes', () {
      expect(canResumeOffline(session(), now), isTrue);
    });

    test('past the desk grace -> no', () {
      expect(canResumeOffline(session(ago: const Duration(minutes: 31)), now),
          isFalse);
    });

    test('exactly at the edge is still inside, one millisecond later is not',
        () {
      expect(canResumeOffline(session(ago: const Duration(minutes: 30)), now),
          isTrue);
      expect(
          canResumeOffline(
              session(ago: const Duration(minutes: 30, milliseconds: 1)), now),
          isFalse);
    });

    test('a huge grace is capped at 24h', () {
      final longGrace = session(grace: 60 * 24 * 7);
      expect(
          canResumeOffline(
              longGrace.copyWith(
                  lastSeenAt: now.subtract(const Duration(hours: 23))),
              now),
          isTrue);
      expect(
          canResumeOffline(
              longGrace.copyWith(
                  lastSeenAt: now.subtract(const Duration(hours: 25))),
              now),
          isFalse);
    });

    test('the cap is injectable and wins over a longer grace', () {
      expect(
          canResumeOffline(
              session(grace: 120, ago: const Duration(minutes: 20)), now,
              cap: const Duration(minutes: 15)),
          isFalse);
      expect(
          canResumeOffline(
              session(grace: 120, ago: const Duration(minutes: 10)), now,
              cap: const Duration(minutes: 15)),
          isTrue);
    });

    test('a session from another desk is refused', () {
      expect(
          canResumeOffline(session(desk: 'desk-1'), now,
              pairingDeskInstanceId: 'desk-2'),
          isFalse);
      expect(
          canResumeOffline(session(desk: null), now,
              pairingDeskInstanceId: 'desk-2'),
          isFalse);
      expect(
          canResumeOffline(session(desk: 'desk-1'), now,
              pairingDeskInstanceId: 'desk-1'),
          isTrue);
    });

    test('a lastSeenAt in the future (clock set back) is not trusted', () {
      expect(canResumeOffline(session(ago: const Duration(minutes: -5)), now),
          isFalse);
    });
  });

  group('OfflineSession storage format', () {
    test('round trips and carries no PIN material', () {
      final original = session().copyWith(pinGraceMinutes: 45);
      final encoded = original.encode();
      expect(encoded.toLowerCase(), isNot(contains('pin"')));
      expect(encoded.toLowerCase(), isNot(contains('hash')));
      final back = OfflineSession.tryDecode(encoded)!;
      expect(back.operatorId, 'op1');
      expect(back.name, 'Asha');
      expect(back.pinGraceMinutes, 45);
      expect(back.lastSeenAt, original.lastSeenAt);
      expect(back.deskInstanceId, 'desk-1');
    });

    test('garbage decodes to no session, never a throw', () {
      expect(OfflineSession.tryDecode(null), isNull);
      expect(OfflineSession.tryDecode(''), isNull);
      expect(OfflineSession.tryDecode('not json'), isNull);
      expect(OfflineSession.tryDecode('[1,2]'), isNull);
      expect(OfflineSession.tryDecode('{"operator_id":"x"}'), isNull,
          reason: 'no lastSeenAt: unusable');
    });
  });
}
