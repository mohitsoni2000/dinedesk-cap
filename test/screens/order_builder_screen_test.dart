import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/screens/order_builder_screen.dart';

void main() {
  testWidgets('running table renders current order and menu', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tablesProvider.overrideWith((ref) => [
                const RestaurantTable(
                  id: 'F1',
                  serverId: 'table-1',
                  seats: 4,
                  floor: 'First Floor',
                  state: TableState.mine,
                  activeOrderId: 'order-1',
                  bill: 560,
                  orderItemCount: 1,
                ),
              ]),
          activeOrdersProvider.overrideWith((ref) => [
                {
                  'id': 'order-1',
                  'table_id': 'table-1',
                  'order_number': 'O-1',
                  'status': 'draft',
                  'total': 560,
                  'items': [
                    {
                      'id': 'line-1',
                      'item_id': 'item-1',
                      'item_name': 'Paneer Tikka',
                      'quantity': 2,
                      'unit_price': 280,
                      'total_price': 560,
                      'item_type': 'food',
                    },
                  ],
                },
              ]),
          menuProvider.overrideWith((ref) => [
                const MenuItem(
                  id: 'item-2',
                  name: 'Veg Biryani',
                  section: 'Rice',
                  kitchenSection: 'food',
                  price: 220,
                  isVeg: true,
                ),
              ]),
        ],
        child: const MaterialApp(
          home: OrderBuilderScreen(tableId: 'table-1'),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Table F1'), findsOneWidget);
    expect(find.text('Running order'), findsOneWidget);
    expect(find.text('Paneer Tikka'), findsOneWidget);
    expect(find.text('Veg Biryani'), findsOneWidget);
  });

  testWidgets('running table shows item count when synced order has no lines',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tablesProvider.overrideWith((ref) => [
                const RestaurantTable(
                  id: 'F2',
                  serverId: 'table-2',
                  seats: 4,
                  floor: 'First Floor',
                  state: TableState.mine,
                  activeOrderId: 'order-2',
                  bill: 840,
                  orderItemCount: 3,
                ),
              ]),
          activeOrdersProvider.overrideWith((ref) => [
                {
                  'id': 'order-2',
                  'table_id': 'table-2',
                  'order_number': 'O-2',
                  'status': 'draft',
                  'total': 840,
                  'item_count': 3,
                },
              ]),
          menuProvider.overrideWith((ref) => [
                const MenuItem(
                  id: 'item-3',
                  name: 'Dal Fry',
                  section: 'Main Course',
                  kitchenSection: 'food',
                  price: 180,
                  isVeg: true,
                ),
              ]),
        ],
        child: const MaterialApp(
          home: OrderBuilderScreen(tableId: 'table-2'),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Table F2'), findsOneWidget);
    expect(find.text('Running order'), findsOneWidget);
    expect(find.text('3 items already sent'), findsOneWidget);
    expect(find.text('Dal Fry'), findsOneWidget);
  });
}
