import 'home_route.dart';

/// What an order is being built for.
enum OrderTargetKind { table, room, counter }

/// The order builder's slot: a table, a room, or the counter (table-less,
/// takeaway or standing, with a daily token).
final class OrderTarget {
  const OrderTarget.table(this.slotId) : kind = OrderTargetKind.table;
  const OrderTarget.room(this.slotId) : kind = OrderTargetKind.room;
  const OrderTarget.counter()
      : kind = OrderTargetKind.counter,
        slotId = '';

  final OrderTargetKind kind;

  /// The table's or room's server id; empty for the counter.
  final String slotId;

  bool get isTable => kind == OrderTargetKind.table;
  bool get isRoom => kind == OrderTargetKind.room;
  bool get isCounter => kind == OrderTargetKind.counter;

  /// Where "back" and "done" return: the tab the order began from, never
  /// blindly home. A waiter on a QSR desk who served a table goes back to
  /// Tables, not to the Counter. Table and room orders return to Tables, as
  /// they always did; counter orders to the Counter.
  String get originRoute => isCounter ? HomeRoutes.counter : HomeRoutes.tables;

  @override
  bool operator ==(Object other) =>
      other is OrderTarget && other.kind == kind && other.slotId == slotId;

  @override
  int get hashCode => Object.hash(kind, slotId);
}
