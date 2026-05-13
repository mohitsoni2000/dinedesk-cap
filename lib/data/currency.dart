// ₹ currency formatting — Indian numbering (lakh/crore separators).

import 'package:intl/intl.dart';

/// Format a rupee amount with Indian-locale grouping.
/// e.g. 1234567.89 → "₹12,34,567.89"
String formatRupees(double amount, {bool showDecimals = true}) {
  final fmt = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: showDecimals ? 2 : 0,
  );
  return fmt.format(amount);
}

/// Compact rupee — drops decimals when whole number.
/// e.g. 480 → "₹480", 142.5 → "₹142.50"
String formatRupeesCompact(double amount) {
  if ((amount - amount.roundToDouble()).abs() < 0.01) {
    return formatRupees(amount, showDecimals: false);
  }
  return formatRupees(amount);
}
