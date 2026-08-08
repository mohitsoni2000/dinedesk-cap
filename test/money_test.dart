import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';

void main() {
  group('Money.fromWire', () {
    test('rounds float rupees to the nearest paisa', () {
      // 12.34 arrives from SQLite REAL as 12.339999999999999 often enough to
      // matter. Truncation would shave a paisa off every such line.
      expect(Money.fromWire(12.339999999999999), const Money(1234));
      expect(Money.fromWire(0.1 + 0.2), const Money(30));
      // 1234.005 is not representable: the nearest double is
      // 1234.0050000000001091, which sits just above the half-paisa mark, so
      // the nearest paisa is 123401 (₹1234.01). Rounding is on the value the
      // machine actually holds, not on the decimal literal in the source.
      expect(Money.fromWire(1234.005), const Money(123401));
    });

    test('accepts ints and numeric strings', () {
      expect(Money.fromWire(250), const Money(25000));
      expect(Money.fromWire('99.50'), const Money(9950));
      expect(Money.fromWire(' 12 '), const Money(1200));
    });

    test('returns null rather than a substitute zero', () {
      // The old _toDouble returned 0 for all of these, so a malformed price
      // became a free item with no signal anywhere.
      expect(Money.fromWire(null), isNull);
      expect(Money.fromWire('abc'), isNull);
      expect(Money.fromWire(''), isNull);
      expect(Money.fromWire(double.nan), isNull);
      expect(Money.fromWire(double.infinity), isNull);
    });
  });

  group('arithmetic is exact', () {
    test('summing many lines does not drift', () {
      // 0.1 + 0.2 != 0.3 in IEEE-754; this is the whole reason the type exists.
      final lines = List<Money>.filled(1000, const Money(10));
      expect(lines.sumMoney(), const Money(10000));
    });

    test('quantity scaling', () {
      expect(const Money(3333).times(3), const Money(9999));
    });

    test('weighed lines round exactly once', () {
      // 1.4 kg of a 449.99/kg item.
      expect(const Money(44999).timesWeight(1.4), const Money(62999));
      expect(const Money(100).timesWeight(0), Money.zero);
      expect(const Money(100).timesWeight(double.nan), Money.zero);
    });

    test('negatives and abs', () {
      expect(-const Money(500), const Money(-500));
      expect(const Money(-500).abs(), const Money(500));
      expect(const Money(-1).isNegative, isTrue);
    });

    test('zero is a value, not an absence', () {
      expect(Money.zero.isZero, isTrue);
      expect(Money.zero.isPositive, isFalse);
      expect(Money.zero == const Money(0), isTrue);
    });
  });

  group('allocateProportionally', () {
    test('parts always sum back to the amount', () {
      // The float pro-rata this replaces could not do this, which is why the
      // old payment sheet had to invent up to 99 paise to close the gap.
      final cases = <(Money, List<Money>)>[
        (const Money(10000), <Money>[const Money(3333), const Money(6667)]),
        (const Money(1), <Money>[const Money(1), const Money(1), const Money(1)]),
        (const Money(99999), <Money>[const Money(1), const Money(99998)]),
        (
          const Money(100000),
          <Money>[const Money(33333), const Money(33333), const Money(33334)]
        ),
      ];
      for (final (amount, weights) in cases) {
        final parts = allocateProportionally(amount, weights);
        expect(parts.sumMoney(), amount,
            reason: 'allocation of $amount over $weights must be exact');
      }
    });

    test('exhaustive: every split of 1..200 paise over 3 uneven bills', () {
      final weights = <Money>[
        const Money(1999),
        const Money(4550),
        const Money(701),
      ];
      for (var paise = 1; paise <= 200; paise++) {
        final parts = allocateProportionally(Money(paise), weights);
        expect(parts.sumMoney(), Money(paise));
        expect(parts.every((p) => !p.isNegative), isTrue);
      }
    });

    test('zero total weight yields zeros, not NaN', () {
      // This is the case that made the old sheet compute NaN, skip its own
      // `< 0.01` guard, and throw FormatException from double.parse("NaN")
      // *after* earlier bills in the loop had already been charged.
      final parts = allocateProportionally(
        const Money(5000),
        <Money>[Money.zero, Money.zero],
      );
      expect(parts, <Money>[Money.zero, Money.zero]);
    });

    test('a zero-weight bill receives nothing', () {
      final parts = allocateProportionally(
        const Money(10000),
        <Money>[const Money(5000), Money.zero, const Money(5000)],
      );
      expect(parts[1], Money.zero);
      expect(parts.sumMoney(), const Money(10000));
    });

    test('empty weights', () {
      expect(allocateProportionally(const Money(100), <Money>[]), isEmpty);
    });

    test('deterministic across repeated calls', () {
      final weights = <Money>[
        const Money(1000),
        const Money(1000),
        const Money(1000),
      ];
      final first = allocateProportionally(const Money(1001), weights);
      final second = allocateProportionally(const Money(1001), weights);
      expect(first, second);
    });
  });
}
