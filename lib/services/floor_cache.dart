import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/money.dart';
import '../data/providers.dart';
import 'log.dart';

const String _tag = '[FloorCache]';
const String _cacheKey = 'floor_cache_v1';

class FloorCacheSnapshot {
  final List<String> floorNames;
  final List<RestaurantTable> tables;
  final List<RestaurantRoom> rooms;
  const FloorCacheSnapshot({
    required this.floorNames,
    required this.tables,
    required this.rooms,
  });
}

class FloorCache {
  FloorCache._();

  static Future<void> save(FloorCacheSnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(<String, dynamic>{
        'floor_names': snapshot.floorNames,
        'tables': snapshot.tables.map(_tableToJson).toList(),
        'rooms': snapshot.rooms.map(_roomToJson).toList(),
      });
      await prefs.setString(_cacheKey, json);
    } catch (e) {
      logD(_tag, 'save failed: $e');
    }
  }

  static Future<FloorCacheSnapshot?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final floorNames = (decoded['floor_names'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      final tables = (decoded['tables'] as List<dynamic>? ?? const [])
          .map((e) => _tableFromJson(e as Map<String, dynamic>))
          .whereType<RestaurantTable>()
          .toList();
      final rooms = (decoded['rooms'] as List<dynamic>? ?? const [])
          .map((e) => _roomFromJson(e as Map<String, dynamic>))
          .whereType<RestaurantRoom>()
          .toList();
      return FloorCacheSnapshot(
          floorNames: floorNames, tables: tables, rooms: rooms);
    } catch (e) {
      logD(_tag, 'load failed (treating as no cache): $e');
      return null;
    }
  }

  static Map<String, dynamic> _tableToJson(RestaurantTable t) =>
      <String, dynamic>{
        'id': t.id,
        'server_id': t.serverId,
        'seats': t.seats,
        'floor': t.floor,
        'state': t.state.name,
        'joined_operator_ids': t.joinedOperatorIds,
        'joined_operator_names': t.joinedOperatorNames,
        'cover_count': t.coverCount,
        'bill_paise': t.bill?.paise,
        'note': t.note,
        'active_order_id': t.activeOrderId,
        'active_bill_count': t.activeBillCount,
        'order_item_count': t.orderItemCount,
        'oldest_kot_minutes': t.oldestKotMinutes,
        'kot_count': t.kotCount,
        'occupied_since': t.occupiedSince?.toIso8601String(),
      };

  static RestaurantTable? _tableFromJson(Map<String, dynamic> m) {
    try {
      final billPaise = m['bill_paise'] as int?;
      final occupiedSinceRaw = m['occupied_since'] as String?;
      return RestaurantTable(
        id: m['id'] as String,
        serverId: m['server_id'] as String,
        seats: m['seats'] as int,
        floor: m['floor'] as String,
        state: TableState.values.byName(m['state'] as String),
        joinedOperatorIds:
            (m['joined_operator_ids'] as List<dynamic>? ?? const [])
                .cast<String>(),
        joinedOperatorNames:
            (m['joined_operator_names'] as List<dynamic>? ?? const [])
                .cast<String>(),
        coverCount: m['cover_count'] as int?,
        bill: billPaise == null ? null : Money(billPaise),
        note: m['note'] as String?,
        activeOrderId: m['active_order_id'] as String?,
        activeBillCount: m['active_bill_count'] as int? ?? 0,
        orderItemCount: m['order_item_count'] as int? ?? 0,
        oldestKotMinutes: m['oldest_kot_minutes'] as int? ?? 0,
        kotCount: m['kot_count'] as int? ?? 0,
        occupiedSince: occupiedSinceRaw == null
            ? null
            : DateTime.tryParse(occupiedSinceRaw),
      );
    } catch (e) {
      logD(_tag, 'dropping one malformed cached table: $e');
      return null;
    }
  }

  static Map<String, dynamic> _roomToJson(RestaurantRoom r) =>
      <String, dynamic>{
        'id': r.id,
        'server_id': r.serverId,
        'capacity': r.capacity,
        'state': r.state.name,
        'guest_name': r.guestName,
        'active_order_id': r.activeOrderId,
        'active_bill_count': r.activeBillCount,
        'order_item_count': r.orderItemCount,
        'bill_paise': r.bill?.paise,
      };

  static RestaurantRoom? _roomFromJson(Map<String, dynamic> m) {
    try {
      final billPaise = m['bill_paise'] as int?;
      return RestaurantRoom(
        id: m['id'] as String,
        serverId: m['server_id'] as String,
        capacity: m['capacity'] as int,
        state: RoomState.values.byName(m['state'] as String),
        guestName: m['guest_name'] as String?,
        activeOrderId: m['active_order_id'] as String?,
        activeBillCount: m['active_bill_count'] as int? ?? 0,
        orderItemCount: m['order_item_count'] as int? ?? 0,
        bill: billPaise == null ? null : Money(billPaise),
      );
    } catch (e) {
      logD(_tag, 'dropping one malformed cached room: $e');
      return null;
    }
  }
}
