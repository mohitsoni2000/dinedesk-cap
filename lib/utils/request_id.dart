import 'dart:convert';
import 'dart:math';

final _random = Random();

String newRequestId() {
  final rand =
      List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();
  return 'req_${DateTime.now().microsecondsSinceEpoch}_$rand';
}

/// Idempotency ids for events that mutate desk state, one per *user intent*.
///
/// The desk replays a cached success for a `client_request_id` it has already
/// answered (48h), so a retry whose first attempt actually landed — the ack was
/// lost on a weak link — returns the original result instead of applying the
/// action twice. That only works if every retry of one intent carries the SAME
/// id and a genuinely new intent carries a new one:
///
/// - the intent is identified by the event plus its payload (key order
///   irrelevant), so tapping "Apply 10%" again after an unanswered attempt
///   reuses the id, while editing the value starts a fresh intent;
/// - an id is retired on success ([settleRequestId]), so doing the same thing
///   again *deliberately* afterwards is a new action, not a replay;
/// - an unanswered id expires after [kRequestIdTtl] so a much later identical
///   action isn't mistaken for a retry.
///
/// The map key is a hash of the payload, never the payload itself: some of
/// these payloads carry PINs and must not sit in memory as map keys.
const Duration kRequestIdTtl = Duration(minutes: 15);

final Map<String, ({String id, DateTime at})> _intentIds =
    <String, ({String id, DateTime at})>{};

/// Override for tests.
DateTime Function() requestIdClock = DateTime.now;

String _fnv1a(String input) {
  var hash = 0xcbf29ce484222325;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16);
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return <String, Object?>{for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _intentKey(String event, Map<String, dynamic> payload) {
  final clean = <String, dynamic>{...payload}..remove('client_request_id');
  return '$event#${_fnv1a(jsonEncode(_canonical(clean)))}';
}

/// The id for this intent: the existing one for a retry, a fresh one otherwise.
String requestIdFor(String event, Map<String, dynamic> payload) {
  final now = requestIdClock();
  _intentIds.removeWhere((_, v) => now.difference(v.at) > kRequestIdTtl);
  final key = _intentKey(event, payload);
  final existing = _intentIds[key];
  if (existing != null) return existing.id;
  final id = newRequestId();
  _intentIds[key] = (id: id, at: now);
  return id;
}

/// The intent completed: retire its id so the next identical action is new.
void settleRequestId(String event, Map<String, dynamic> payload) {
  _intentIds.remove(_intentKey(event, payload));
}

/// Test hook.
void resetRequestIds() => _intentIds.clear();
