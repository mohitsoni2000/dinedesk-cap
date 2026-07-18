import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';

void main() {
  test('RestaurantTable.copyWith replaces joinedOperatorNames', () {
    const table = RestaurantTable(
      id: 'T1',
      serverId: 't1',
      seats: 4,
      floor: 'Ground',
      state: TableState.mine,
      joinedOperatorNames: ['Priya'],
    );

    final updated = table.copyWith(joinedOperatorNames: ['Priya', 'Rahul']);

    expect(updated.joinedOperatorNames, ['Priya', 'Rahul']);
    expect(table.joinedOperatorNames, ['Priya']); // original unchanged
  });

  test('RestaurantTable.copyWith replaces joinedOperatorIds', () {
    const table = RestaurantTable(
      id: 'T1',
      serverId: 't1',
      seats: 4,
      floor: 'Ground',
      state: TableState.mine,
      joinedOperatorIds: ['op1'],
    );

    final updated = table.copyWith(joinedOperatorIds: ['op1', 'op2']);

    expect(updated.joinedOperatorIds, ['op1', 'op2']);
    expect(table.joinedOperatorIds, ['op1']); // original unchanged
  });

  test('RestaurantTable defaults joinedOperatorNames to an empty list', () {
    const table = RestaurantTable(
      id: 'T1',
      serverId: 't1',
      seats: 4,
      floor: 'Ground',
      state: TableState.free,
    );

    expect(table.joinedOperatorNames, <String>[]);
  });
}
