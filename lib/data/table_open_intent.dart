import 'ist_time.dart';
import 'providers.dart';
import 'room_card_view.dart';

enum TableOpenAction { createDraft, openOrder, openBill, blocked }

class TableOpenIntent {
  final TableOpenAction action;
  final String? route;
  final String? message;

  /// The running order, for the intents that go straight to it.
  final String? orderId;

  const TableOpenIntent._(this.action,
      {this.route, this.message, this.orderId});

  const TableOpenIntent.createDraft(String tableId)
      : this._(TableOpenAction.createDraft, route: '/order/$tableId');
  const TableOpenIntent.openOrder(String tableId)
      : this._(TableOpenAction.openOrder, route: '/order/$tableId');
  const TableOpenIntent.openBill(String orderId)
      : this._(TableOpenAction.openBill,
            route: '/history/$orderId', orderId: orderId);
  const TableOpenIntent.blocked(String message)
      : this._(TableOpenAction.blocked, message: message);
}

TableOpenIntent resolveTableOpenIntent(RestaurantTable table) {
  if (table.state == TableState.dirty) {
    return const TableOpenIntent.blocked('Table needs cleaning');
  }

  if (table.state == TableState.free &&
      (table.activeOrderId == null || table.activeOrderId!.isEmpty)) {
    return TableOpenIntent.createDraft(table.serverId);
  }

  // Same as the desk's floor plan: a table that has been billed goes to its
  // bill (payment, reprint), not back into the order.
  final orderId = table.activeOrderId;
  if (table.state != TableState.free &&
      table.activeBillCount > 0 &&
      orderId != null &&
      orderId.isNotEmpty) {
    return TableOpenIntent.openBill(orderId);
  }

  return TableOpenIntent.openOrder(table.serverId);
}

TableOpenIntent resolveRoomOpenIntent(RestaurantRoom room, {DateTime? now}) {
  final view = roomCardView(room, istDateOf(now ?? DateTime.now()));
  switch (view.state) {
    case RoomCardState.held:
      return TableOpenIntent.blocked(
          'Held for ${view.guest} \u2014 desk checks the guest in first');
    case RoomCardState.dirty:
      return const TableOpenIntent.blocked('Room needs cleaning');
    case RoomCardState.cleaning:
      return const TableOpenIntent.blocked('Room is being cleaned');
    case RoomCardState.inspect:
      return const TableOpenIntent.blocked('Room is awaiting inspection');
    case RoomCardState.blocked:
      return const TableOpenIntent.blocked('Room is blocked');
    case RoomCardState.free:
    case RoomCardState.mine:
    case RoomCardState.occupied:
      break;
  }
  final route = '/order/room/${room.serverId}';
  // A room's order starts at check-in (dates, rate, guest), which only the
  // desk does; the desk refuses an order for a free room without them.
  if (view.state == RoomCardState.free &&
      (room.activeOrderId == null || room.activeOrderId!.isEmpty)) {
    return const TableOpenIntent.blocked('Check the guest in at the Desk first');
  }
  return TableOpenIntent._(TableOpenAction.openOrder, route: route);
}
