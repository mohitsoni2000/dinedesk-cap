import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/server_models.dart';

void main() {
  test('ServerTable preserves desktop operator table counters', () {
    final table = ServerTable.fromMap({
      'id': 'table-1',
      'name': 'T-01',
      'capacity': 4,
      'status': 'occupied',
      'floor_id': 'floor-1',
      'active_order_id': 'order-1',
      'active_bill_count': 2,
      'order_item_count': 5,
      'oldest_kot_minutes': 14,
      'kot_count': 3,
    });

    expect(table.activeOrderId, 'order-1');
    expect(table.activeBillCount, 2);
    expect(table.orderItemCount, 5);
    expect(table.oldestKotMinutes, 14);
    expect(table.kotCount, 3);
  });

  test('ServerMenuItem can carry desktop item option groups', () {
    final group = ServerMenuOptionGroup.fromMap({
      'id': 'group-1',
      'item_id': 'item-1',
      'name': 'Size',
      'is_required': 1,
      'min_select': 1,
      'max_select': 1,
    });
    final option = ServerMenuOption.fromMap({
      'id': 'option-1',
      'group_id': 'group-1',
      'name': 'Large',
      'price_modifier': 40,
    });

    final item = ServerMenuItem.fromMap({
      'id': 'item-1',
      'name': 'Paneer Tikka',
      'category_name': 'Tandoor',
      'category_type': 'food',
      'base_price': 260,
    }).copyWith(optionGroups: [
      group.copyWith(options: [option]),
    ]);

    expect(item.optionGroups.single.name, 'Size');
    expect(item.optionGroups.single.options.single.priceModifier, 40);
  });
}
