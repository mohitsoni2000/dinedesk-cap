import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/slot_order.dart';
import 'package:restro/models/server_models.dart';

ServerOrder order(String id,
    {String tableId = 't6', String status = 'placed'}) {
  return ServerOrder(
    id: id,
    tableId: tableId,
    orderNumber: 'ORD-$id',
    status: status,
    total: Money.zero,
    itemCount: 1,
    createdAt: '2026-10-04 17:19:45',
    items: const [],
  );
}

void main() {
  // Table 6 on 17 Oct: ORD-1104 (placed, never settled) still in the active
  // list; the table itself just paid out, so its active_order_id is null.
  final stale = order('1104');
  final live = order('1004');

  test('an empty slot is an empty slot — no order is picked from the list', () {
    expect(runningOrderForSlot([stale], null), isNull);
    expect(runningOrderForSlot([stale], ''), isNull);
  });

  test('the slot’s own order is returned, not another one on the same table',
      () {
    expect(runningOrderForSlot([stale, live], '1004'), same(live));
  });

  test('a slot id the list does not carry yet yields null (never a stand-in)',
      () {
    expect(runningOrderForSlot([stale], '1004'), isNull);
  });

  test('settled statuses are the ones the desk has finished with', () {
    for (final s in ['paid', 'credit', 'closed', 'cancelled', 'voided']) {
      expect(isSettledOrderStatus(s), isTrue, reason: s);
    }
    for (final s in [
      'draft',
      'placed',
      'served',
      'billed',
      'held',
      'partially_paid'
    ]) {
      expect(isSettledOrderStatus(s), isFalse, reason: s);
    }
  });
}
