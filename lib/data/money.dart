/// The single canonical money representation for the whole app.
///
/// Every amount is a whole number of paise. There is no `double` money
/// anywhere past the wire boundary, and no code re-derives an amount the
/// server already owns. Two rules, both load-bearing:
///
///  1. Parse once, at the boundary ([Money.fromWire]). Format once, at the
///     render edge (`currency.dart`). Never in between.
///  2. Arithmetic is integer. A sum of [Money] is exact; a sum of doubles is
///     not, and the drift shows up as a bill that disagrees with the desk.
///
/// Deliberately a class rather than an `extension type`: the compile-time
/// safety is identical, the allocation is irrelevant at cart scale, and it
/// carries real `==`/`hashCode`/`compareTo` without ceremony.
final class Money implements Comparable<Money> {
  /// The amount, in whole paise. 100 paise = ₹1.
  final int paise;

  const Money(this.paise);

  static const Money zero = Money(0);

  /// ₹[rupees] exactly. For literals in code, not for wire data.
  const Money.rupees(int rupees) : paise = rupees * 100;

  /// Parses an amount off the wire.
  ///
  /// The desk sends rupees (SQLite REAL, or a numeric string). This is the
  /// *only* place a floating-point rupee value is allowed to exist, and it
  /// stops existing on the next line. `round()` — not `toInt()` — because
  /// 12.34 arrives as 12.339999999999999 often enough to matter, and
  /// truncation would quietly shave a paisa off every such line.
  ///
  /// Returns null when [raw] is absent or unparseable. Callers at the wire
  /// boundary must decide explicitly whether that is fatal; see
  /// `wire.dart`'s `requireMoney` / `optionalMoney`.
  static Money? fromWire(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return Money(raw * 100);
    if (raw is double) {
      if (raw.isNaN || raw.isInfinite) return null;
      return Money((raw * 100).round());
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final parsed = double.tryParse(trimmed);
      if (parsed == null || parsed.isNaN || parsed.isInfinite) return null;
      return Money((parsed * 100).round());
    }
    return null;
  }

  /// Rupees as a double — for display formatting only. Never feed the result
  /// back into arithmetic.
  double get asRupeesForDisplay => paise / 100;

  bool get isZero => paise == 0;
  bool get isPositive => paise > 0;
  bool get isNegative => paise < 0;

  Money operator +(Money other) => Money(paise + other.paise);
  Money operator -(Money other) => Money(paise - other.paise);
  Money operator -() => Money(-paise);

  /// Scales by a whole count (quantity). Exact by construction.
  Money times(int count) => Money(paise * count);

  /// Scales by a fractional weight (kg, litres) and rounds to the nearest
  /// paisa. Weighed items are the one place a non-integer multiplier is
  /// legitimate; the rounding happens here, once, and never again.
  Money timesWeight(double weight) {
    if (weight.isNaN || weight.isInfinite) return Money.zero;
    return Money((paise * weight).round());
  }

  Money abs() => Money(paise.abs());

  bool operator <(Money other) => paise < other.paise;
  bool operator <=(Money other) => paise <= other.paise;
  bool operator >(Money other) => paise > other.paise;
  bool operator >=(Money other) => paise >= other.paise;

  @override
  int compareTo(Money other) => paise.compareTo(other.paise);

  @override
  bool operator ==(Object other) => other is Money && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;

  @override
  String toString() => 'Money(${paise}p)';

  /// What goes back to the desk. Rupees, because that is what the desk's
  /// schema stores; the division is exact for any int paise value that fits
  /// in a double's 53-bit mantissa, which covers every amount a restaurant
  /// will ever bill.
  double toWire() => paise / 100;
}

extension MoneyIterable on Iterable<Money> {
  /// Exact sum. Replaces `fold(0.0, ...)` everywhere it appeared.
  Money sumMoney() => Money(fold<int>(0, (total, m) => total + m.paise));
}

/// Splits [amount] across [weights] so that the parts sum to *exactly*
/// [amount], using the largest-remainder method.
///
/// This replaces the old per-bill `entry.amount * (bill.total / grandTotal)`
/// float pro-rata in the payment sheet, which could not sum back to the
/// tendered amount and was patched by *adding* up to ₹0.99 the customer
/// never handed over.
///
/// Guarantees, all covered by tests:
///  - `allocateProportionally(a, w).sumMoney() == a` for every input
///  - a zero weight receives zero
///  - a zero total weight yields all zeros rather than NaN
///  - remainder paise go to the largest fractional parts first, ties by index
List<Money> allocateProportionally(Money amount, List<Money> weights) {
  if (weights.isEmpty) return const <Money>[];

  final totalWeight = weights.fold<int>(0, (sum, w) => sum + w.paise);
  if (totalWeight == 0) {
    // Nothing to weight against — a set of ₹0 bills. Everything gets zero
    // rather than the NaN the old float path produced here.
    return List<Money>.filled(weights.length, Money.zero);
  }

  final amountPaise = amount.paise;
  final base = <int>[];
  final remainders = <int>[];
  for (final weight in weights) {
    final numerator = amountPaise * weight.paise;
    base.add(numerator ~/ totalWeight);
    remainders.add(numerator.remainder(totalWeight).abs());
  }

  var leftover = amountPaise - base.fold<int>(0, (sum, p) => sum + p);

  // Hand out the leftover paise to the largest fractional remainders first.
  // Ties break by original index so the result is deterministic — the same
  // split twice in a row must produce the same numbers.
  final order = List<int>.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final cmp = remainders[b].compareTo(remainders[a]);
      return cmp != 0 ? cmp : a.compareTo(b);
    });

  final step = leftover >= 0 ? 1 : -1;
  var cursor = 0;
  while (leftover != 0) {
    base[order[cursor % order.length]] += step;
    leftover -= step;
    cursor++;
  }

  return base.map(Money.new).toList(growable: false);
}
