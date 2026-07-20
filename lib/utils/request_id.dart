import 'dart:math';

/// Idempotency key for a single mutating socket call (order:create,
/// order:update, kot:send, bill:payment). The server dedupes on this and
/// replays the stored ack instead of re-running the mutation — needed
/// because these calls get auto-retried (queue flush, ack timeout) and a
/// lost ack followed by a retry would otherwise duplicate the order/KOT/
/// payment server-side.
final _random = Random();

String newRequestId() {
  final rand = List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();
  return 'req_${DateTime.now().microsecondsSinceEpoch}_$rand';
}
