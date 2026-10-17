import '../models/server_models.dart';

/// The order a table or room is running, by the one rule the desk uses:
/// the slot's `active_order_id`. Nothing else.
///
/// Every screen used to fall back to "any open order in the list whose
/// table_id matches" when the slot carried no order id. That is how a
/// table paid out seconds ago (slot id cleared by `table:updated`) got its
/// next round added to a thirteen-day-old `placed` order the desk had long
/// stopped showing — the items and KOT vanished from every bill. An empty
/// slot now means a new order, full stop.
/// An order the desk has finished with. Adopting one from an `order:updated`
/// broadcast (the desk sends one for a paid order too) must not mark its
/// table as running it again — the table was freed a beat earlier.
bool isSettledOrderStatus(String status) {
  switch (status) {
    case 'paid':
    case 'credit':
    case 'closed':
    case 'cancelled':
    case 'voided':
      return true;
    default:
      return false;
  }
}

ServerOrder? runningOrderForSlot(
  Iterable<ServerOrder> orders,
  String? activeOrderId,
) {
  if (activeOrderId == null || activeOrderId.isEmpty) return null;
  return orders.where((o) => o.id == activeOrderId).firstOrNull;
}
