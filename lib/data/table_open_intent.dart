import 'ist_time.dart';
import 'providers.dart';
import 'room_card_view.dart';

enum TableOpenAction { createDraft, openOrder, blocked }

class TableOpenIntent {
  final TableOpenAction action;
  final String? route;
  final String? message;

  const TableOpenIntent._(this.action, {this.route, this.message});

  const TableOpenIntent.createDraft(String tableId)
      : this._(TableOpenAction.createDraft, route: '/order/$tableId');
  const TableOpenIntent.openOrder(String tableId)
      : this._(TableOpenAction.openOrder, route: '/order/$tableId');
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
  if (view.state == RoomCardState.free &&
      (room.activeOrderId == null || room.activeOrderId!.isEmpty)) {
    return TableOpenIntent._(TableOpenAction.createDraft, route: route);
  }
  return TableOpenIntent._(TableOpenAction.openOrder, route: route);
}
