

import 'package:intl/intl.dart';

String formatRupees(double amount, {bool showDecimals = true}) {
  final fmt = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: showDecimals ? 2 : 0,
  );
  return fmt.format(amount);
}

String formatRupeesCompact(double amount) {
  if ((amount - amount.roundToDouble()).abs() < 0.01) {
    return formatRupees(amount, showDecimals: false);
  }
  return formatRupees(amount);
}
