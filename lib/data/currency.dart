import 'package:intl/intl.dart';

import 'money.dart';

/// The single render edge for money. Nothing else in the app turns a [Money]
/// into a string, and nothing anywhere turns a string back into money.
///
/// Both formatters take [Money] on purpose — the old `double` overloads are
/// gone. That is what stops a raw wire double, or a re-derived subtotal, from
/// reaching a label without passing through the paise boundary first.

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

/// Always shows paise: `₹1,234.50`, `₹1,234.00`.
String formatRupees(Money amount) =>
    _withPaise.format(amount.asRupeesForDisplay);

/// Drops `.00` when the amount is a whole number of rupees, and only then.
///
/// The old version compared against a 0.01 epsilon, which meant a genuine
/// ₹1,234.004 drift rendered as a clean `₹1,234` — hiding exactly the
/// float error that caused the phone and the desk to disagree. With integer
/// paise the test is exact and there is nothing left to hide.
String formatRupeesCompact(Money amount) => amount.paise % 100 == 0
    ? _wholeRupees.format(amount.asRupeesForDisplay)
    : _withPaise.format(amount.asRupeesForDisplay);

/// Signed, for modifier chips: `+₹60`, `−₹50`, `₹0`.
String formatRupeesSigned(Money amount) {
  if (amount.isZero) return formatRupeesCompact(Money.zero);
  final magnitude = formatRupeesCompact(amount.abs());
  return amount.isNegative ? '\u2212$magnitude' : '+$magnitude';
}
