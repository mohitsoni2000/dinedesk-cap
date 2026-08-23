import 'package:intl/intl.dart';

import 'money.dart';

final NumberFormat _withPaise = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '\u20B9',
  decimalDigits: 2,
);

final NumberFormat _wholeRupees = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '\u20B9',
  decimalDigits: 0,
);

String formatRupees(Money amount) =>
    _withPaise.format(amount.asRupeesForDisplay);

String formatRupeesCompact(Money amount) => amount.paise % 100 == 0
    ? _wholeRupees.format(amount.asRupeesForDisplay)
    : _withPaise.format(amount.asRupeesForDisplay);

String formatRupeesSigned(Money amount) {
  if (amount.isZero) return formatRupeesCompact(Money.zero);
  final magnitude = formatRupeesCompact(amount.abs());
  return amount.isNegative ? '\u2212$magnitude' : '+$magnitude';
}
