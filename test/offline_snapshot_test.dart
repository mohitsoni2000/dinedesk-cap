import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/floor_cache.dart';
import 'package:restro/services/offline_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late OfflineSnapshotStore store;

  final menu = <String, dynamic>{
    'categories': [
      {'id': 'c1', 'name': 'Starters', 'type': 'food', 'sort_order': 1},
    ],
    'items': [
      {
        'id': 'i1',
        'name': 'Paneer Tikka',
        'category_id': 'c1',
        'price': 250,
        'is_veg': 1,
      },
    ],
  };

  final order = <String, dynamic>{
    'id': 'o1',
    'table_id': 't1',
    'order_number': 'ORD-1',
    'status': 'open',
    'total': 250,
    'item_count': 1,
    'created_at': '2026-10-05T04:00:00Z',
    'items': <Object>[],
    'some_future_field': {'kept': true},
  };

  OfflineSnapshot snapshot({
    String? desk = 'desk-1',
    Map<String, dynamic>? menuMap,
    List<Map<String, dynamic>>? orders,
  }) =>
      OfflineSnapshot(
        savedAt: DateTime.utc(2026, 10, 5, 4),
        deskInstanceId: desk,
        restaurantInfo: const <String, dynamic>{'name': 'Spice Hub'},
        featureFlags: const <String, dynamic>{'flag_rooms': 1},
        menu: menuMap ?? menu,
        menuVersion: 'mv-9',
        fastAdd: const <String, dynamic>{
          'pinned': <Object>[],
          'auto': <Object>[]
        },
        offers: const [
          {'id': 'of1', 'name': '10% off', 'rule_type': 'pct'},
        ],
        activeOrders: orders ?? [order],
        linkGroups: const {
          'g1': ['t1', 't2']
        },
        kotPrintConfig: const <String, dynamic>{
          'version': 'kv1',
          'groups': [
            {
              'id': 'g',
              'name': 'Kitchen',
              'is_fallback': true,
              'destinations': [
                {'host': '10.0.0.5', 'port': 9100}
              ],
            }
          ],
        },
        sessionPolicy: const <String, dynamic>{'pin_grace_minutes': 30},
        slotFloorIds: const {'t1': 'f1'},
        qsrConfig: const <String, dynamic>{
          'operating_mode': 'qsr',
          'qsr_payment_flow': 'prepaid',
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('snapshot_test');
    store = OfflineSnapshotStore(directory: dir);
  });

  tearDown(() async {
    await store.idle;
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  File file() => File('${dir.path}/$offlineSnapshotFileName');

  group('store', () {
    test('round trips every field through a gzip file', () async {
      await store.save(snapshot());

      final bytes = await file().readAsBytes();
      expect(bytes.take(2), [0x1f, 0x8b], reason: 'gzip magic');
      final raw =
          jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;
      expect(raw['schema'], 1);
      expect(raw['desk_instance_id'], 'desk-1');
      expect(
          raw.keys,
          containsAll(<String>[
            'saved_at',
            'menu',
            'menu_version',
            'fast_add',
            'offers',
            'active_orders',
            'link_groups',
            'kot_print_config',
            'session_policy',
            'restaurant_info',
            'feature_flags',
            'qsr_config',
          ]));

      final back = (await store.load(deskInstanceId: 'desk-1'))!;
      expect(back.deskInstanceId, 'desk-1');
      expect(back.savedAt, DateTime.utc(2026, 10, 5, 4));
      expect(back.menu, menu);
      expect(back.menuVersion, 'mv-9');
      expect(back.restaurantInfo!['name'], 'Spice Hub');
      expect(back.featureFlags, {'flag_rooms': 1});
      expect(back.offers.single['id'], 'of1');
      expect(back.activeOrders.single, order,
          reason: 'raw desk JSON, unknown fields included');
      expect(back.linkGroups, {
        'g1': ['t1', 't2']
      });
      expect(back.kotPrintConfig!['version'], 'kv1');
      expect(back.pinGraceMinutes, 30);
      expect(back.slotFloorIds, {'t1': 'f1'});
      expect(back.qsrConfig,
          {'operating_mode': 'qsr', 'qsr_payment_flow': 'prepaid'});
    });

    test('a file written before QSR existed reads with no qsr_config',
        () async {
      await file().writeAsBytes(gzip.encode(utf8.encode(jsonEncode({
        'schema': 1,
        'saved_at': '2026-10-05T04:00:00Z',
        'desk_instance_id': 'desk-1',
      }))));
      final back = (await store.load(deskInstanceId: 'desk-1'))!;
      expect(back.qsrConfig, isNull);
    });

    test('no tmp file is left behind and a re-save replaces the file',
        () async {
      await store.save(snapshot());
      await store.save(snapshot(orders: const []));
      expect(File('${file().path}.tmp').existsSync(), isFalse);
      final back = (await store.load())!;
      expect(back.activeOrders, isEmpty);
      expect(back.menu, menu, reason: 'the unchanged menu is still written');
    });

    test('a changed menu is re-encoded, an unchanged one is reused', () async {
      await store.save(snapshot());
      final changed = <String, dynamic>{
        ...menu,
        'items': [
          {
            ...(menu['items'] as List).first as Map<String, dynamic>,
            'price': 300
          },
        ],
      };
      await store.save(snapshot(menuMap: changed));
      final back = (await store.load())!;
      expect(((back.menu!['items'] as List).first as Map)['price'], 300);
    });

    test('a corrupt file loads as nothing and is discarded', () async {
      await file().writeAsBytes(<int>[1, 2, 3, 4, 5]);
      expect(await store.load(), isNull);
      expect(file().existsSync(), isFalse);

      await file().writeAsBytes(gzip.encode(utf8.encode('{not json')));
      expect(await store.load(), isNull);
      expect(file().existsSync(), isFalse);
    });

    test('an unknown schema is not trusted', () async {
      await file().writeAsBytes(gzip.encode(utf8.encode(
          jsonEncode({'schema': 99, 'saved_at': '2026-01-01T00:00:00Z'}))));
      expect(await store.load(), isNull);
    });

    test('a snapshot of another desk is discarded', () async {
      await store.save(snapshot(desk: 'desk-1'));
      expect(await store.load(deskInstanceId: 'desk-2'), isNull);
      expect(file().existsSync(), isFalse,
          reason: 'not re-parsed on every launch');
    });

    test('idle waits for every queued save, in order', () async {
      unawaited(store.save(snapshot(orders: const [])));
      unawaited(store.save(snapshot()));
      await store.idle;
      expect(File('${file().path}.tmp').existsSync(), isFalse);
      expect((await store.load())!.activeOrders.single['id'], 'o1',
          reason: 'the later save is the one on disk');
    });

    test('a missing file is simply null', () async {
      expect(await store.load(deskInstanceId: 'desk-1'), isNull);
    });

    test('a missing session_policy means grace 0 (fail closed)', () {
      final s = OfflineSnapshot(savedAt: DateTime.utc(2026));
      expect(s.pinGraceMinutes, 0);
    });
  });

  group('SyncService', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [offlineSnapshotStoreProvider.overrideWithValue(store)],
      );
    });

    tearDown(() => container.dispose());

    test('hydrate keeps the FloorCache floor names and sets the menu version',
        () async {
      await FloorCache.save(const FloorCacheSnapshot(
        floorNames: <String>['Ground', 'Terrace'],
        tables: <RestaurantTable>[
          RestaurantTable(
              id: 'T1',
              serverId: 't1',
              seats: 4,
              floor: 'Ground',
              state: TableState.free),
        ],
        rooms: <RestaurantRoom>[],
      ));
      await store.save(snapshot());

      final sync = container.read(syncServiceProvider);
      await sync.hydrateFromFloorCache();
      expect(await sync.hydrateFromSnapshot(deskInstanceId: 'desk-1'), isTrue);

      expect(container.read(floorNamesProvider), ['Ground', 'Terrace'],
          reason: 'the snapshot has no `floors`; hydrating must not wipe them '
              '(applyInitialSync would)');
      expect(container.read(tablesProvider).single.id, 'T1');
      expect(sync.cachedMenuVersion, 'mv-9');
      expect(container.read(menuProvider).map((i) => i.id), ['i1']);
      expect(container.read(rawMenuDataProvider), menu);
      expect(container.read(activeOrdersProvider).single.id, 'o1');
      expect(container.read(activeOrdersProvider).single.raw, order);
      expect(container.read(restaurantProvider)!.name, 'Spice Hub');
      expect(container.read(flagsProvider).rooms, isTrue);
      expect(container.read(offersProvider).single.id, 'of1');
      expect(container.read(linkGroupsProvider), {
        'g1': ['t1', 't2']
      });
      expect(container.read(kotPrintConfigProvider)!.version, 'kv1');
      expect(container.read(slotFloorIdsProvider), {'t1': 'f1'});
      expect(container.read(isFloorDataStaleProvider), isTrue);
      expect(container.read(connectionProvider).online, isFalse,
          reason: 'hydrating is not being online');
    });

    test('hydrate refuses a snapshot of another desk', () async {
      await store.save(snapshot(desk: 'desk-1'));
      final sync = container.read(syncServiceProvider);
      expect(await sync.hydrateFromSnapshot(deskInstanceId: 'desk-2'), isFalse);
      expect(container.read(menuProvider), isEmpty);
    });

    test('hydrate does nothing once a live sync has landed', () async {
      await store.save(snapshot());
      final sync = container.read(syncServiceProvider);
      await sync.applyInitialSync(<String, dynamic>{'tables': <Object>[]});
      expect(await sync.hydrateFromSnapshot(deskInstanceId: 'desk-1'), isFalse);
    });

    test('a live sync writes the snapshot (menu, orders, print config, policy)',
        () async {
      final sync = container.read(syncServiceProvider)
        ..deskInstanceIdOverride = 'desk-1';
      await sync.applyInitialSync(<String, dynamic>{
        'restaurant_info': {'name': 'Spice Hub'},
        'feature_flags': {'flag_rooms': 1},
        'floors': [
          {'id': 'f1', 'name': 'Ground'}
        ],
        'tables': [
          {'id': 't1', 'name': 'T1', 'floor_id': 'f1', 'status': 'free'}
        ],
        'menu': menu,
        'menu_version': 'mv-9',
        'active_orders': [order],
        'kot_print_config': {
          'version': 'kv1',
          'groups': [
            {
              'id': 'g',
              'name': 'Kitchen',
              'is_fallback': true,
              'destinations': [
                {'host': '10.0.0.5', 'port': 9100}
              ],
            }
          ],
        },
        'session_policy': {'pin_grace_minutes': 45},
      });
      // saveSnapshot is fire-and-forget at the end of the sync; drain it.
      await sync.saveSnapshot();

      final saved = (await store.load(deskInstanceId: 'desk-1'))!;
      expect(saved.menuVersion, 'mv-9');
      expect(saved.menu, menu);
      expect(saved.activeOrders.single['id'], 'o1');
      expect(saved.kotPrintConfig!['version'], 'kv1');
      expect(saved.pinGraceMinutes, 45);
      expect(saved.slotFloorIds, {'t1': 'f1'});
      expect(container.read(kotPrintConfigProvider)!.groups.single.id, 'g');
    });

    test('a full sync without session_policy writes grace 0', () async {
      final sync = container.read(syncServiceProvider)
        ..deskInstanceIdOverride = 'desk-1';
      await sync.applyInitialSync(<String, dynamic>{'tables': <Object>[]});
      await sync.saveSnapshot();
      expect((await store.load())!.pinGraceMinutes, 0);
    });

    test(
        'a null kot_print_config clears direct printing; an absent one keeps it',
        () async {
      final sync = container.read(syncServiceProvider);
      final cfg = {
        'version': 'kv1',
        'groups': [
          {
            'id': 'g',
            'name': 'K',
            'destinations': [
              {'host': '10.0.0.5', 'port': 9100}
            ],
          }
        ],
      };
      await sync.applyInitialSync(<String, dynamic>{'kot_print_config': cfg});
      expect(container.read(kotPrintConfigProvider), isNotNull);

      await sync.applyInitialSync(<String, dynamic>{'menu_version': 'x'});
      expect(container.read(kotPrintConfigProvider), isNotNull,
          reason: 'a menu-only reply says nothing about printers');

      await sync.applyInitialSync(<String, dynamic>{'kot_print_config': null});
      expect(container.read(kotPrintConfigProvider), isNull);
    });

    test('nothing is saved for a demo / unpaired session', () async {
      final sync = container.read(syncServiceProvider);
      await sync.applyInitialSync(<String, dynamic>{'menu': menu});
      await sync.saveSnapshot();
      expect(file().existsSync(), isFalse);
    });
  });
}
