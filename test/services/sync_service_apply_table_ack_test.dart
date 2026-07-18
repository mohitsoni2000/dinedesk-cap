import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restro/data/providers.dart';

void main() {
  setUp(() {
    // sync_service.dart's table-timer bookkeeping touches SharedPreferences
    // as a fire-and-forget side effect of _serverTableToLocal; seed an
    // in-memory store so those calls don't hit a real platform channel.
    SharedPreferences.setMockInitialValues(const {});
  });

  RestaurantTable buildTable({
    required String serverId,
    TableState state = TableState.other,
  }) {
    return RestaurantTable(
      id: 'T1',
      serverId: serverId,
      seats: 4,
      floor: 'Main',
      state: state,
      joinedOperatorIds: const ['op1'],
      joinedOperatorNames: const ['Priya'],
    );
  }

  group('SyncService.applyTableAck', () {
    test('happy path: updates the matching table in tablesProvider', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(tablesProvider.notifier).state = [
        buildTable(serverId: 'tbl-1'),
      ];

      final syncService = container.read(syncServiceProvider);
      syncService.applyTableAck({
        'table': {
          'id': 'tbl-1',
          'name': 'T1',
          'capacity': 4,
          'status': 'occupied',
          'floor_id': 'Main',
          'order_total': 0,
          'operators': [
            {'operator_id': 'op1', 'operator_name': 'Priya'},
            {'operator_id': 'op2', 'operator_name': 'Rahul'},
          ],
        },
      });

      final tables = container.read(tablesProvider);
      expect(tables, hasLength(1));
      expect(tables.single.serverId, 'tbl-1');
      expect(tables.single.joinedOperatorIds, ['op1', 'op2']);
      expect(tables.single.joinedOperatorNames, ['Priya', 'Rahul']);
    });

    test('malformed input: missing table key is a no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initial = [buildTable(serverId: 'tbl-1')];
      container.read(tablesProvider.notifier).state = initial;

      final syncService = container.read(syncServiceProvider);
      expect(() => syncService.applyTableAck({'kind': 'success'}),
          returnsNormally);

      expect(container.read(tablesProvider), same(initial));
    });

    test('malformed input: table value is not a Map is a no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initial = [buildTable(serverId: 'tbl-1')];
      container.read(tablesProvider.notifier).state = initial;

      final syncService = container.read(syncServiceProvider);
      expect(
          () => syncService.applyTableAck({'table': 'not-a-map'}),
          returnsNormally);

      expect(container.read(tablesProvider), same(initial));
    });

    test('no match: well-formed table with an unknown serverId is a no-op',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initial = [buildTable(serverId: 'tbl-1')];
      container.read(tablesProvider.notifier).state = initial;

      final syncService = container.read(syncServiceProvider);
      expect(
        () => syncService.applyTableAck({
          'table': {
            'id': 'tbl-does-not-exist',
            'name': 'T9',
            'capacity': 2,
            'status': 'occupied',
            'floor_id': 'Main',
            'order_total': 0,
          },
        }),
        returnsNormally,
      );

      expect(container.read(tablesProvider), same(initial));
    });
  });
}
