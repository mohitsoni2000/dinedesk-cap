import '../data/money.dart';
import '../services/log.dart';

/// The wire boundary.
///
/// The old helpers (`_toDouble`, `_toInt`, `_toStr`) silently returned 0 / 0 /
/// '' for anything they could not parse. A malformed price became ₹0, a
/// missing id became an empty string that then matched nothing, and no signal
/// reached anyone. That is the Dart equivalent of the `as any` we do not
/// allow on the TypeScript side.
///
/// Two kinds of accessor live here:
///
///  - `require*` — the field is load-bearing. Absent or unparseable throws
///    [WireFormatException]. Callers catch it per-entity so one bad row does
///    not take down a whole sync, but the failure is *visible*.
///  - `optional*` — the field is genuinely optional. Returns null. Never a
///    substitute zero.
///
/// There is deliberately no "parse with a default" accessor for money.

class WireFormatException implements Exception {
  final String entity;
  final String field;
  final String reason;
  final Object? received;

  const WireFormatException({
    required this.entity,
    required this.field,
    required this.reason,
    this.received,
  });

  @override
  String toString() =>
      'WireFormatException($entity.$field): $reason '
      '(received ${received == null ? 'null' : received.runtimeType})';
}

Never _fail(String entity, String field, String reason, Object? received) {
  throw WireFormatException(
    entity: entity,
    field: field,
    reason: reason,
    received: received,
  );
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

/// A required, non-empty string. An empty id is not a valid id — the old code
/// let `''` through, and it then silently matched nothing in every
/// `indexWhere` downstream.
String requireString(Map<String, dynamic> map, String field, String entity) {
  final raw = map[field];
  if (raw == null) _fail(entity, field, 'missing', raw);
  final value = raw.toString().trim();
  if (value.isEmpty) _fail(entity, field, 'empty', raw);
  return value;
}

/// An optional string. Empty is normalised to null so callers never have to
/// check both.
String? optionalString(Map<String, dynamic> map, String field) {
  final raw = map[field];
  if (raw == null) return null;
  final value = raw.toString().trim();
  return value.isEmpty ? null : value;
}

/// A string with an explicit, meaningful default (display labels only —
/// never ids, never money).
String stringOr(Map<String, dynamic> map, String field, String fallback) =>
    optionalString(map, field) ?? fallback;

/// First non-empty of several candidate keys, for payload-shape drift
/// (`item_name` vs `name`).
String? optionalStringAny(Map<String, dynamic> map, List<String> fields) {
  for (final field in fields) {
    final value = optionalString(map, field);
    if (value != null) return value;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Integers
// ---------------------------------------------------------------------------

int? optionalInt(Map<String, dynamic> map, String field) {
  final raw = map[field];
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is double) {
    if (raw.isNaN || raw.isInfinite) return null;
    return raw.round();
  }
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

int requireInt(Map<String, dynamic> map, String field, String entity) {
  final value = optionalInt(map, field);
  if (value == null) _fail(entity, field, 'missing or not an integer', map[field]);
  return value;
}

int intOr(Map<String, dynamic> map, String field, int fallback) =>
    optionalInt(map, field) ?? fallback;

// ---------------------------------------------------------------------------
// Booleans
// ---------------------------------------------------------------------------

/// Case-insensitive, unlike the old `_toBool`, which compared against the
/// literals `'1'` and `'true'` only. A desk sending `is_veg: "True"` was
/// parsed as false — a veg item rendered with a red non-veg dot, which is an
/// FSSAI labelling problem, not a cosmetic one.
bool? optionalBool(Map<String, dynamic> map, String field) {
  final raw = map[field];
  if (raw == null) return null;
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  if (raw is double) return raw != 0;
  if (raw is String) {
    switch (raw.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'y':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'n':
        return false;
      default:
        return null;
    }
  }
  return null;
}

bool boolOr(Map<String, dynamic> map, String field, bool fallback) =>
    optionalBool(map, field) ?? fallback;

/// For flags where guessing wrong is a safety or compliance problem
/// (`is_veg`). Forces the desk to be explicit.
bool requireBool(Map<String, dynamic> map, String field, String entity) {
  final value = optionalBool(map, field);
  if (value == null) _fail(entity, field, 'missing or not a boolean', map[field]);
  return value;
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

/// A required amount. Note that **zero is a valid amount** — a fully
/// discounted or comped order really does total ₹0. Only *absence* fails.
///
/// This is the guard that kills the `total > 0 ? total : recomputed` pattern:
/// there is no longer any way to express "0 means missing".
Money requireMoney(Map<String, dynamic> map, String field, String entity) {
  final value = Money.fromWire(map[field]);
  if (value == null) _fail(entity, field, 'missing or not an amount', map[field]);
  return value;
}

/// An amount that may genuinely be absent. Returns null — never `Money.zero`,
/// because the two mean different things and conflating them is what made a
/// voided table keep displaying its old total.
Money? optionalMoney(Map<String, dynamic> map, String field) =>
    Money.fromWire(map[field]);

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

/// A list of maps, skipping non-map entries. Never throws — a stray scalar in
/// a list is the desk's problem, not a reason to lose the other 40 rows.
List<Map<String, dynamic>> mapList(Object? raw) {
  if (raw is! List) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final entry in raw) {
    if (entry is Map) out.add(Map<String, dynamic>.from(entry));
  }
  return out;
}

Map<String, dynamic>? optionalMap(Map<String, dynamic> map, String field) {
  final raw = map[field];
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

Map<String, dynamic> asMap(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return const <String, dynamic>{};
}

/// Parses a list of entities, dropping (and logging) only the rows that fail
/// validation. One malformed table must not blank the floor plan, but it must
/// also not appear as a ₹0 phantom.
List<T> parseEach<T>(
  List<Map<String, dynamic>> rows,
  T Function(Map<String, dynamic>) parse,
  String entity,
) {
  final out = <T>[];
  for (final row in rows) {
    try {
      out.add(parse(row));
    } on WireFormatException catch (e) {
      logE('[Wire]', 'dropped one $entity', e);
    }
  }
  return out;
}
