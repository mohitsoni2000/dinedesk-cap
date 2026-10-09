import '../data/ist_time.dart';
import 'wire.dart';

/// How a table-less order leaves the counter.
enum FulfillmentType {
  takeaway('takeaway', 'Takeaway'),
  standing('standing', 'Standing');

  const FulfillmentType(this.wire, this.label);
  final String wire;
  final String label;

  /// Null for anything else (a dine-in or room order has no fulfillment).
  static FulfillmentType? fromWire(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    for (final v in values) {
      if (v.wire == key) return v;
    }
    return null;
  }
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

  static TokenStatus fromWire(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    if (key == null || key.isEmpty) return unknown;
    for (final v in values) {
      if (v.wire == key) return v;
    }
    return unknown;
  }
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
