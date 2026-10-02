import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/ist_time.dart';

void main() {
  group('parseDbTimestamp — every format the desk stores', () {
    final at = DateTime.utc(2026, 9, 30, 8, 30);

    test('SQLite UTC, ISO Z, offsets and zone-less IST are the same instant',
        () {
      for (final raw in [
        '2026-09-30 08:30:00',
        '2026-09-30 08:30',
        '2026-09-30T08:30:00.000Z',
        '2026-09-30T14:00:00+05:30',
        '2026-09-30T14:00:00+0530',
        '2026-09-30T03:30:00-05:00',
        '2026-09-30T14:00',
        '2026-09-30T14:00:00',
      ]) {
        final parsed = parseDbTimestamp(raw);
        expect(parsed, at, reason: raw);
        expect(parsed!.isUtc, isTrue, reason: raw);
      }
    });

    test('a zone-less time is IST, never device-local or UTC', () {
      expect(parseDbTimestamp('2026-09-30T14:00'),
          isNot(DateTime.utc(2026, 9, 30, 14)));
    });

    test('a date alone is UTC midnight; junk is null', () {
      expect(parseDbTimestamp('2026-09-30'), DateTime.utc(2026, 9, 30));
      expect(parseDbTimestamp(''), isNull);
      expect(parseDbTimestamp(null), isNull);
      expect(parseDbTimestamp('30/09/2026 14:00'), isNull);
    });
  });

  group('IST dates and labels', () {
    test('the IST day turns at 18:30 UTC', () {
      expect(istDateOf(DateTime.utc(2026, 9, 30, 18, 29, 59)), '2026-09-30');
      expect(istDateOf(DateTime.utc(2026, 9, 30, 18, 30)), '2026-10-01');
    });

    test('times read like the desk: 12-hour, lowercase am/pm', () {
      expect(formatIstTime(DateTime.utc(2026, 9, 30, 6, 30)), '12:00 pm');
      expect(formatIstTime(DateTime.utc(2026, 9, 30, 18, 30)), '12:00 am');
      expect(formatIstTime(DateTime.utc(2026, 9, 30, 8, 30)), '2:00 pm');
      expect(formatIstDayTime(DateTime.utc(2026, 9, 30, 20)), '1 Oct, 1:30 am');
    });

    test('slip date/time: zero-padded, with seconds, shifted to IST', () {
      // 04:45:09 UTC = 10:15:09 IST; 19:00:00 UTC = 00:30 IST the next day.
      expect(formatIstSlipDate(DateTime.utc(2026, 10, 5, 4, 45, 9)),
          '05 Oct 2026');
      expect(formatIstSlipTime(DateTime.utc(2026, 10, 5, 4, 45, 9)),
          '10:15:09 am');
      expect(formatIstSlipDate(DateTime.utc(2026, 10, 5, 19)), '06 Oct 2026');
      expect(formatIstSlipTime(DateTime.utc(2026, 10, 5, 19)), '12:30:00 am');
      expect(formatIstSlipTime(DateTime.utc(2026, 10, 5, 6, 30)), '12:00:00 pm');
    });

    test('time to the next IST midnight', () {
      expect(untilNextIstMidnight(DateTime.utc(2026, 9, 30, 18)),
          const Duration(minutes: 30));
      expect(untilNextIstMidnight(DateTime.utc(2026, 9, 30, 18, 30)),
          const Duration(hours: 24));
    });
  });
}
