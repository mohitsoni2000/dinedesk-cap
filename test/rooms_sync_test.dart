import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/floor_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hold = <String, dynamic>{
    'reservation_id': 'b1',
    'guest_name': 'Ravi Sharma',
    'guest_phone': '9800000001',
    'arrives_at': '2026-10-01 08:30:00',
    'first_night': '2026-10-01',
    'last_night': '2026-10-02',
    'deposit_held': 1000,
  };

  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('the initial sync keeps every room, its real status and its hold',
      () async {
    await container.read(syncServiceProvider).applyInitialSync({
      'rooms': [
        {'id': 'r1', 'name': '101', 'status': 'free', 'arrival_hold': hold},
        {'id': 'r2', 'name': '102', 'status': 'dirty', 'arrival_hold': hold},
        {
          'id': 'r3',
          'name': '103',
          'status': 'occupied',
          'active_order_id': 'o1',
          'arrival_hold': hold,
        },
        {'id': 'r4', 'name': '104', 'status': 'blocked'},
        {'id': 'r5', 'name': '105', 'status': 'clean'},
        {'id': 'r6', 'name': '106', 'status': 'cleaning', 'arrival_hold': 'x'},
      ],
    });

    final rooms = {
      for (final r in container.read(roomsProvider)) r.serverId: r,
    };
    expect(rooms.keys.toSet(), {'r1', 'r2', 'r3', 'r4', 'r5', 'r6'});
    expect(rooms['r1']!.state, RoomState.free);
    expect(rooms['r1']!.arrivalHold?.guestName, 'Ravi Sharma');
    expect(rooms['r2']!.state, RoomState.dirty);
    expect(rooms['r3']!.state, RoomState.occupied);
    expect(rooms['r4']!.state, RoomState.blocked);
    expect(rooms['r5']!.state, RoomState.inspect);
    expect(rooms['r6']!.state, RoomState.cleaning);
    expect(rooms['r6']!.arrivalHold, isNull);
  });

  group('floor cache', () {
    test('keeps the real status and the hold across a restart', () async {
      await container.read(syncServiceProvider).applyInitialSync({
        'rooms': [
          {'id': 'r2', 'name': '102', 'status': 'dirty', 'arrival_hold': hold},
        ],
      });
      final cached = await FloorCache.load();
      final room = cached!.rooms.single;
      expect(room.state, RoomState.dirty);
      expect(room.arrivalHold?.guestName, 'Ravi Sharma');
      expect(room.arrivalHold?.arrivesAt, DateTime.utc(2026, 10, 1, 8, 30));
    });

    test('writes a state an older app can read', () async {
      await FloorCache.save(const FloorCacheSnapshot(
        floorNames: [],
        tables: [],
        rooms: [
          RestaurantRoom(
              id: '102', serverId: 'r2', capacity: 2, state: RoomState.blocked),
        ],
      ));
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString('floor_cache_v1')!)
          as Map<String, dynamic>;
      final row =
          (raw['rooms'] as List<dynamic>).single as Map<String, dynamic>;
      expect(row['state'], 'free');
      expect(row['status'], 'blocked');
    });

    test('reads an old cache, and an unknown state falls back to free',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'floor_cache_v1': jsonEncode({
          'floor_names': <String>[],
          'tables': <Object>[],
          'rooms': [
            {
              'id': '101',
              'server_id': 'r1',
              'capacity': 2,
              'state': 'occupied'
            },
            {
              'id': '102',
              'server_id': 'r2',
              'capacity': 2,
              'state': 'later',
              'status': 'gone',
              'arrival_hold': 'x',
            },
          ],
        }),
      });
      final cached = await FloorCache.load();
      final rooms = {for (final r in cached!.rooms) r.serverId: r};
      expect(rooms['r1']!.state, RoomState.occupied);
      expect(rooms['r2']!.state, RoomState.free);
      expect(rooms['r2']!.arrivalHold, isNull);
    });
  });
}
