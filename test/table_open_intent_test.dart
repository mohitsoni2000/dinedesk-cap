import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/data/table_open_intent.dart';

/// Tapping a table does what the desk's floor plan does: a table with a bill
/// goes to the bill, not back into the order, and a table being cleaned stays shut.
void main() {
  RestaurantTable table(
    TableState state, {
    String? orderId,
    int bills = 0,
  }) =>
      RestaurantTable(
        id: 't-5',
        serverId: 'srv-5',
        seats: 4,
        floor: 'Ground',
        state: state,
        activeOrderId: orderId,
        activeBillCount: bills,
      );

  group('a table with a bill generated', () {
    for (final state in <TableState>[
      TableState.mine,
      TableState.other,
      TableState.reserved,
    ]) {
      test('opens the bill, not the order (${state.name})', () {
        final intent =
            resolveTableOpenIntent(table(state, orderId: 'ord-9', bills: 1));

        expect(intent.action, TableOpenAction.openBill);
        expect(intent.route, '/history/ord-9');
        expect(intent.orderId, 'ord-9');
      });
    }

    test('several bills on the order still open the bill', () {
      final intent = resolveTableOpenIntent(
          table(TableState.mine, orderId: 'ord-9', bills: 3));

      expect(intent.action, TableOpenAction.openBill);
    });

    test('without a running order id there is no bill to open', () {
      expect(
          resolveTableOpenIntent(table(TableState.mine, bills: 1)).action,
          TableOpenAction.openOrder);
      expect(
          resolveTableOpenIntent(table(TableState.mine, orderId: '', bills: 1))
              .action,
          TableOpenAction.openOrder);
    });
  });

  group('a table without a bill', () {
    test('an occupied table opens its order', () {
      for (final state in <TableState>[
        TableState.mine,
        TableState.other,
        TableState.reserved,
      ]) {
        final intent =
            resolveTableOpenIntent(table(state, orderId: 'ord-9'));

        expect(intent.action, TableOpenAction.openOrder, reason: state.name);
        expect(intent.route, '/order/srv-5');
      }
    });

    test('a free table with nothing running starts a new order', () {
      final intent = resolveTableOpenIntent(table(TableState.free));

      expect(intent.action, TableOpenAction.createDraft);
      expect(intent.route, '/order/srv-5');
    });

    test('a free table that still has a running order opens it', () {
      final intent =
          resolveTableOpenIntent(table(TableState.free, orderId: 'ord-9'));

      expect(intent.action, TableOpenAction.openOrder);
    });

    test('the desk ignores a stray bill count on a free table, so does the phone',
        () {
      final intent = resolveTableOpenIntent(
          table(TableState.free, orderId: 'ord-9', bills: 1));

      expect(intent.action, TableOpenAction.openOrder);
    });
  });

  test('a table that needs cleaning stays shut, bill or not', () {
    final intent = resolveTableOpenIntent(
        table(TableState.dirty, orderId: 'ord-9', bills: 1));

    expect(intent.action, TableOpenAction.blocked);
    expect(intent.message, 'Table needs cleaning');
  });
}
