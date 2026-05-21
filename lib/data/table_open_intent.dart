import 'providers.dart';

enum TableOpenAction { createDraft, openOrder, openBill, blocked }

class TableOpenIntent {
  final TableOpenAction action;
  final String? route;
  final String? message;

  const TableOpenIntent._(this.action, {this.route, this.message});

  const TableOpenIntent.createDraft(String tableId)
      : this._(TableOpenAction.createDraft, route: '/order/$tableId');
  const TableOpenIntent.openOrder(String tableId)
      : this._(TableOpenAction.openOrder, route: '/order/$tableId');
  const TableOpenIntent.openBill(String orderId)
      : this._(TableOpenAction.openBill, route: '/history/$orderId');
  const TableOpenIntent.blocked(String message)
      : this._(TableOpenAction.blocked, message: message);
}

TableOpenIntent resolveTableOpenIntent(RestaurantTable table) {
  if (table.state == TableState.dirty) {
    return const TableOpenIntent.blocked('Table needs cleaning');
  }

  if (table.activeBillCount > 0 &&
      table.activeOrderId != null &&
      table.activeOrderId!.isNotEmpty) {
    return TableOpenIntent.openBill(table.activeOrderId!);
  }

  if (table.state == TableState.free &&
      (table.activeOrderId == null || table.activeOrderId!.isEmpty)) {
    return TableOpenIntent.createDraft(table.serverId);
  }

  return TableOpenIntent.openOrder(table.serverId);
}
