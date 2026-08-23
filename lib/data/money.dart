final class Money implements Comparable<Money> {
  final int paise;

  const Money(this.paise);

  static const Money zero = Money(0);

  const Money.rupees(int rupees) : paise = rupees * 100;

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

  double get asRupeesForDisplay => paise / 100;

  bool get isZero => paise == 0;
  bool get isPositive => paise > 0;
  bool get isNegative => paise < 0;

  Money operator +(Money other) => Money(paise + other.paise);
  Money operator -(Money other) => Money(paise - other.paise);
  Money operator -() => Money(-paise);

  Money times(int count) => Money(paise * count);

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

  double toWire() => paise / 100;
}

extension MoneyIterable on Iterable<Money> {
  Money sumMoney() => Money(fold<int>(0, (total, m) => total + m.paise));
}

List<Money> allocateProportionally(Money amount, List<Money> weights) {
  if (weights.isEmpty) return const <Money>[];

  final totalWeight = weights.fold<int>(0, (sum, w) => sum + w.paise);
  if (totalWeight == 0) {
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
