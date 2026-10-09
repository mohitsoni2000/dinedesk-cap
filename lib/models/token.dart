import '../data/ist_time.dart';
import 'wire.dart';

final RegExp _digitsOnly = RegExp(r'^\d+$');
final RegExp _digits = RegExp(r'\d+');

/// How a token is shown to staff and guests: a unified token is a number
/// (`42` → `#42`), a prefixed one is shown as the desk made it (`T-07`).
String tokenDisplay(String label) {
  final trimmed = label.trim();
  return _digitsOnly.hasMatch(trimmed) ? '#$trimmed' : trimmed;
}

/// The number in a token label (`42` → 42, `T-07` → 7), for sorting; null
/// when it has none.
int? tokenNumberOf(String label) {
  final match = _digits.allMatches(label).lastOrNull;
  return match == null ? null : int.tryParse(match.group(0)!);
}

/// How a table-less order leaves the counter.
enum FulfillmentType {
  takeaway('takeaway', 'Takeaway'),
  standing('standing', 'Standing');

  const FulfillmentType(this.wire, this.label);
  final String wire;
  final String label;

  /// Null for anything else (a dine-in or room order has no fulfillment).
  static FulfillmentType? fromWire(Object? raw) =>
      enumFromWire(values, raw, (v) => v.wire);
}

/// Where a token is in its day: cooking, waiting on the pass, handed over.
enum TokenStatus {
  preparing('preparing'),
  ready('ready'),
  collected('collected'),

  /// Missing, or a word this app does not know yet.
  unknown('');

  const TokenStatus(this.wire);
  final String wire;

  static TokenStatus fromWire(Object? raw) =>
      enumFromWire(values, raw, (v) => v.wire) ?? unknown;
}

/// A table-less order's daily token, as the desk allocated it (at the first
/// KOT, or at billing for an order with nothing to cook). The label is what
/// the guest is called by: `42` (unified) or `T-07` (prefixed).
class TokenInfo {
  final int? number;
  final String label;

  /// The business day the token belongs to (numbering restarts each day).
  final String? date;
  final TokenStatus status;
  final DateTime? readyAt;
  final DateTime? collectedAt;

  const TokenInfo({
    required this.label,
    this.number,
    this.date,
    this.status = TokenStatus.unknown,
    this.readyAt,
    this.collectedAt,
  });

  /// "Token T-07" / "Token 42": how the phone names a token order.
  String get title => 'Token $label';

  /// From an order's `token_*` fields; null when the order has no token
  /// (a table order, tokens off, or an older desk).
  static TokenInfo? fromOrderMap(Map<String, dynamic> m) {
    final label = optionalString(m, 'token_label');
    if (label == null) return null;
    return TokenInfo(
      number: optionalInt(m, 'token_number'),
      label: label,
      date: optionalString(m, 'token_date'),
      status: TokenStatus.fromWire(m['token_status']),
      readyAt: parseDbTimestamp(optionalString(m, 'token_ready_at')),
      collectedAt: parseDbTimestamp(optionalString(m, 'token_collected_at')),
    );
  }

  /// The token an order ack carries: the `qsr:checkout` ack's `token`, else
  /// the order's `token_*` fields (`kot:send` / `order:create` acks), else
  /// the KOT's `token_label` / `token_number` / `token_date`. Null when none
  /// has one (no KOT yet, tokens off, a dine-in order, an older desk).
  static TokenInfo? fromAck(Map<String, dynamic> ack) {
    final direct = tryParse(ack['token']);
    if (direct != null) return direct;
    final order = optionalMap(ack, 'order');
    final fromOrder = order == null ? null : fromOrderMap(order);
    if (fromOrder != null) return fromOrder;
    final kot = optionalMap(ack, 'kot');
    final label = kot == null ? null : optionalString(kot, 'token_label');
    if (kot == null || label == null) return null;
    return TokenInfo(
      number: optionalInt(kot, 'token_number'),
      label: label,
      date: optionalString(kot, 'token_date'),
    );
  }

  /// From a `token` object such as the `qsr:checkout` ack's
  /// `{number, label, date, status}`; null when it carries no label.
  static TokenInfo? tryParse(Object? raw) {
    final m = asMap(raw);
    final label = optionalString(m, 'label');
    if (label == null) return null;
    return TokenInfo(
      number: optionalInt(m, 'number'),
      label: label,
      date: optionalString(m, 'date'),
      status: TokenStatus.fromWire(m['status']),
    );
  }
}
