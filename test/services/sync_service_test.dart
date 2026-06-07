import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:restro/data/providers.dart';

void main() {
  test('initial sync maps desktop flat menu categories and option groups', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(syncServiceProvider).applyInitialSync({
      'floors': const [],
      'tables': const [],
      'menu': {
        'categories': [
          {'id': 'cat-1', 'name': 'Tandoor', 'type': 'food'},
        ],
        'items': [
          {
            'id': 'item-1',
            'name': 'Paneer Tikka',
            'category_id': 'cat-1',
            'category_type': 'food',
            'base_price': 260,
            'is_veg': 1,
            'is_available': 1,
          },
        ],
        'item_option_groups': [
          {
            'id': 'group-1',
            'item_id': 'item-1',
            'name': 'Size',
            'is_required': 1,
            'min_select': 1,
            'max_select': 1,
          },
        ],
        'item_options': [
          {
            'id': 'option-1',
            'group_id': 'group-1',
            'name': 'Large',
            'price_modifier': 40,
          },
        ],
      },
    });

    final item = container.read(menuProvider).single;
    expect(item.section, 'Tandoor');
    expect(item.optionGroups.single.name, 'Size');
    expect(item.optionGroups.single.options.single.name, 'Large');
  });

  test('order ack immediately marks table with active draft order', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(tablesProvider.notifier).state = const [
      RestaurantTable(
        id: 'T-01',
        serverId: 'table-1',
        seats: 4,
        floor: 'Ground',
        state: TableState.free,
      ),
    ];

    container.read(syncServiceProvider).applyOrderAck({
      'kind': 'success',
      'order': {
        'id': 'order-1',
        'table_id': 'table-1',
        'order_number': 'O-1',
        'status': 'draft',
        'item_count': 0,
        'total': 0,
      },
    });

    final table = container.read(tablesProvider).single;
    expect(table.activeOrderId, 'order-1');
    expect(container.read(activeOrdersProvider).single['id'], 'order-1');
  });
}
