import '../data/money.dart';
import '../services/log.dart';

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
  String toString() => 'WireFormatException($entity.$field): $reason '
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

String requireString(Map<String, dynamic> map, String field, String entity) {
  final raw = map[field];
  if (raw == null) _fail(entity, field, 'missing', raw);
  final value = raw.toString().trim();
  if (value.isEmpty) _fail(entity, field, 'empty', raw);
  return value;
}

String? optionalString(Map<String, dynamic> map, String field) {
  final raw = map[field];
  if (raw == null) return null;
  final value = raw.toString().trim();
  return value.isEmpty ? null : value;
}

String stringOr(Map<String, dynamic> map, String field, String fallback) =>
    optionalString(map, field) ?? fallback;

String? optionalStringAny(Map<String, dynamic> map, List<String> fields) {
  for (final field in fields) {
    final value = optionalString(map, field);
    if (value != null) return value;
  }
  return null;
}

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
  if (value == null) {
    _fail(entity, field, 'missing or not an integer', map[field]);
  }
  return value;
}

int intOr(Map<String, dynamic> map, String field, int fallback) =>
    optionalInt(map, field) ?? fallback;

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

bool requireBool(Map<String, dynamic> map, String field, String entity) {
  final value = optionalBool(map, field);
  if (value == null) {
    _fail(entity, field, 'missing or not a boolean', map[field]);
  }
  return value;
}

Money requireMoney(Map<String, dynamic> map, String field, String entity) {
  final value = Money.fromWire(map[field]);
  if (value == null) {
    _fail(entity, field, 'missing or not an amount', map[field]);
  }
  return value;
}

Money? optionalMoney(Map<String, dynamic> map, String field) =>
    Money.fromWire(map[field]);

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
