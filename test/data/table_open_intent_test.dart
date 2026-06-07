import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/data/table_open_intent.dart';

RestaurantTable _table({
  TableState state = TableState.free,
  String? activeOrderId,
  int activeBillCount = 0,
}) {
  return RestaurantTable(
    id: 'T-01',
    serverId: 'table-1',
    seats: 4,
    floor: 'Ground',
    state: state,
    activeOrderId: activeOrderId,
    activeBillCount: activeBillCount,
  );
}

void main() {
  test('free table without active order creates draft before opening', () {
    final intent = resolveTableOpenIntent(_table());

    expect(intent.action, TableOpenAction.createDraft);
    expect(intent.route, '/order/table-1');
  });

  test('running table opens order even when not marked mine', () {
    for (final state in [
      TableState.mine,
      TableState.other,
      TableState.reserved
    ]) {
      final intent = resolveTableOpenIntent(
        _table(state: state, activeOrderId: 'order-1'),
      );

      expect(intent.action, TableOpenAction.openOrder);
      expect(intent.route, '/order/table-1');
    }
  });

  test('billed running table still opens order screen from table grid', () {
    final intent = resolveTableOpenIntent(
      _table(
        state: TableState.mine,
        activeOrderId: 'order-1',
        activeBillCount: 1,
      ),
    );

    expect(intent.action, TableOpenAction.openOrder);
    expect(intent.route, '/order/table-1');
  });

  test('dirty table stays blocked', () {
    final intent = resolveTableOpenIntent(
      _table(state: TableState.dirty, activeOrderId: 'order-1'),
    );

    expect(intent.action, TableOpenAction.blocked);
  });
}
