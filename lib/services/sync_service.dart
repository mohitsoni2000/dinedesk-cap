import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import 'socket_service.dart';

const _tag = '[Sync]';

class SyncService {
  final SocketService _socket;
  StreamSubscription<SocketState>? _stateSubscription;
  Map<String, String> _floorMap = {};  // floor_id → floor_name lookup

  SyncService(this._socket);

  // ─── Listener registration ───────────────────────────────────────────────

  void registerListeners(WidgetRef ref) {
    debugPrint('$_tag Registering real-time listeners');
    // Listen to socket reconnection and update connectionProvider
    _stateSubscription = _socket.stateStream.listen((state) {
      if (state == SocketState.connected || state == SocketState.verified) {
        final restaurant = ref.read(restaurantProvider);
        ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: true,
          label: 'Connected · ${restaurant?.name ?? 'Restaurant'}',
        );
      } else if (state == SocketState.disconnected) {
        ref.read(connectionProvider.notifier).state = const ConnectionStatus(
          online: false,
          label: 'Reconnecting...',
        );
      }
    });

    _socket.on('table:updated', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final currentOperatorId = ref.read(operatorProvider)?.username;
      final updated = _parseTable(map, currentOperatorId, _floorMap);
      if (updated == null) return;
      final tables = [...ref.read(tablesProvider)];
      final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
      if (idx >= 0) {
        tables[idx] = updated;
      } else {
        tables.add(updated);
      }
      ref.read(tablesProvider.notifier).state = tables;
    });

    _socket.on('order:created', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderData = d['order'] as Map? ?? d;  // unwrap if nested
      final map = Map<String, dynamic>.from(orderData);
      final orders = [...ref.read(activeOrdersProvider), map];
      ref.read(activeOrdersProvider.notifier).state = orders;

      // Also add to history
      ref.read(historyProvider.notifier).state = [
        _parseHistoryOrder(map),
        ...ref.read(historyProvider),
      ];

      // Update table state if tables data is included in the broadcast.
      final tablesData = d['tables'];
      if (tablesData is List) {
        final currentOperatorId = ref.read(operatorProvider)?.username;
        final tables = tablesData
            .whereType<Map>()
            .map((m) => _parseTable(Map<String, dynamic>.from(m), currentOperatorId, _floorMap))
            .whereType<RestaurantTable>()
            .toList();
        ref.read(tablesProvider.notifier).state = tables;
      }

      // Update operator stats on new order.
      final stats = ref.read(operatorStatsProvider);
      ref.read(operatorStatsProvider.notifier).state = OperatorStats(
        ordersToday: stats.ordersToday + 1,
        tablesServed: stats.tablesServed,
        itemsSold: stats.itemsSold + ((map['item_count'] as int?) ?? 0),
      );
    });

    _socket.on('order:updated', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderData = d['order'] as Map? ?? d;  // unwrap if nested
      final map = Map<String, dynamic>.from(orderData);
      final orderId = map['id']?.toString();
      if (orderId == null) return;
      final orders = [
        for (final o in ref.read(activeOrdersProvider))
          if (o['id']?.toString() == orderId) map else o,
      ];
      ref.read(activeOrdersProvider.notifier).state = orders;

      // Update table state if tables data is included in the broadcast.
      final tablesData = d['tables'];
      if (tablesData is List) {
        final currentOperatorId = ref.read(operatorProvider)?.username;
        final tables = tablesData
            .whereType<Map>()
            .map((m) => _parseTable(Map<String, dynamic>.from(m), currentOperatorId, _floorMap))
            .whereType<RestaurantTable>()
            .toList();
        ref.read(tablesProvider.notifier).state = tables;
      }
    });

    _socket.on('order:cancelled', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      // Unwrap: check d['order_id'] first, then d['order']?['id'], then d['id']
      final orderData = d['order'] as Map?;
      final orderId = d['order_id']?.toString() ??
          (orderData != null ? orderData['id']?.toString() : null) ??
          d['id']?.toString();
      if (orderId == null) return;
      final orders = ref.read(activeOrdersProvider)
          .where((o) => o['id']?.toString() != orderId)
          .toList();
      ref.read(activeOrdersProvider.notifier).state = orders;

      // Update table state if tables data is included in the broadcast.
      final tablesData = d['tables'];
      if (tablesData is List) {
        final currentOperatorId = ref.read(operatorProvider)?.username;
        final tables = tablesData
            .whereType<Map>()
            .map((m) => _parseTable(Map<String, dynamic>.from(m), currentOperatorId, _floorMap))
            .whereType<RestaurantTable>()
            .toList();
        ref.read(tablesProvider.notifier).state = tables;
      }
    });

    // I3 fix: unwrap nested flags key.
    _socket.on('flags:updated', (data) {
      final envelope = Map<String, dynamic>.from(data as Map);
      final flagsMap = envelope['flags'] as Map? ?? envelope;
      ref.read(flagsProvider.notifier).state =
          FeatureFlags.fromMap(Map<String, dynamic>.from(flagsMap));
    });

    _socket.on('menu:updated', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final items = _parseMenuItems(map);
      ref.read(menuProvider.notifier).state = items;
      ref.read(rawMenuDataProvider.notifier).state = map;
    });

    // I1 fix: missing broadcast listeners.
    _socket.on('kot:sent', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderData = d['order'] as Map? ?? d;
      final map = Map<String, dynamic>.from(orderData);
      final orderId = map['id']?.toString();
      if (orderId == null) return;
      ref.read(activeOrdersProvider.notifier).state = [
        for (final o in ref.read(activeOrdersProvider))
          if (o['id']?.toString() == orderId) map else o,
      ];
      _updateTablesFromBroadcast(ref, d);
    });

    _socket.on('bill:generated', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderData = d['order'] as Map? ?? d;
      final map = Map<String, dynamic>.from(orderData);
      final orderId = map['id']?.toString();
      if (orderId == null) return;
      ref.read(activeOrdersProvider.notifier).state = [
        for (final o in ref.read(activeOrdersProvider))
          if (o['id']?.toString() == orderId) map else o,
      ];
    });

    _socket.on('bill:paid', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderData = d['order'] as Map?;
      final orderId = orderData?['id']?.toString();
      if (orderId != null) {
        ref.read(activeOrdersProvider.notifier).state = ref
            .read(activeOrdersProvider)
            .where((o) => o['id']?.toString() != orderId)
            .toList();
      }
      _updateTablesFromBroadcast(ref, d);
    });

    _socket.on('discount:applied', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderData = d['order'] as Map? ?? d;
      final map = Map<String, dynamic>.from(orderData);
      final orderId = map['id']?.toString();
      if (orderId == null) return;
      ref.read(activeOrdersProvider.notifier).state = [
        for (final o in ref.read(activeOrdersProvider))
          if (o['id']?.toString() == orderId) map else o,
      ];
    });

    // I2 fix: operator presence.
    _socket.on('operator:online', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final name = d['operatorName']?.toString() ?? '';
      final role = d['role']?.toString() ?? '';
      if (name.isEmpty) return;
      final current = ref.read(activeOperatorsProvider);
      if (current.any((o) => o.name == name)) return;
      ref.read(activeOperatorsProvider.notifier).state = [
        ...current,
        ActiveOperator(name: name, role: role),
      ];
    });

    _socket.on('operator:offline', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final name = d['operatorName']?.toString() ?? '';
      ref.read(activeOperatorsProvider.notifier).state =
          ref.read(activeOperatorsProvider).where((o) => o.name != name).toList();
    });

    // I5 fix: clean up listeners before disconnecting.
    _socket.on('force:disconnect', (_) {
      unregisterListeners();
      ref.read(isAuthenticatedProvider.notifier).state = false;
      ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Disconnected by admin');
      _socket.disconnect();
    });
  }

  // ─── Initial sync population ─────────────────────────────────────────────

  void applyInitialSync(WidgetRef ref, Map<String, dynamic> data) {
    debugPrint('$_tag ── Applying initial sync ──');
    debugPrint('$_tag   Keys received: ${data.keys.toList()}');

    // Restaurant info
    final restaurant = data['restaurant_info'] ?? data['restaurant'];
    if (restaurant is Map) {
      final r = Map<String, dynamic>.from(restaurant);
      ref.read(restaurantProvider.notifier).state = RestaurantInfo(
        name: r['restaurant_name']?.toString() ?? r['name']?.toString() ?? 'Restaurant',
        address: r['address']?.toString() ?? '',
        adminDeviceLabel: r['device_label']?.toString() ?? '',
        adminIp: r['ip']?.toString() ?? '',
      );
    }

    debugPrint('$_tag   Restaurant: ${restaurant is Map ? restaurant['name'] ?? restaurant['restaurant_name'] : 'not provided'}');

    // Feature flags
    final flags = data['feature_flags'] ?? data['flags'];
    if (flags is Map) {
      ref.read(flagsProvider.notifier).state =
          FeatureFlags.fromMap(Map<String, dynamic>.from(flags));
    }

    debugPrint('$_tag   Flags: ${flags is Map ? 'loaded' : 'not provided'}');

    // Floors — build a lookup map so tables can resolve floor_id → floor name.
    final floorsList = data['floors'];
    final floorMap = <String, String>{};
    if (floorsList is List) {
      for (final f in floorsList) {
        if (f is Map) {
          final fid = f['id']?.toString();
          final fname = f['name']?.toString();
          if (fid != null && fname != null) floorMap[fid] = fname;
        }
      }
    }
    _floorMap = floorMap;
    debugPrint('$_tag   Floors: ${floorMap.length} → ${floorMap.values.toList()}');

    // Tables
    final currentOperatorId = ref.read(operatorProvider)?.username;
    final tablesList = data['tables'];
    if (tablesList is List) {
      // Log first table's raw keys for debugging.
      if (tablesList.isNotEmpty && tablesList.first is Map) {
        final sample = Map<String, dynamic>.from(tablesList.first as Map);
        debugPrint('$_tag   Table[0] raw keys: ${sample.keys.toList()}');
        debugPrint('$_tag   Table[0] name=${sample['name']}, id=${sample['id']}, '
            'floor_id=${sample['floor_id']}, capacity=${sample['capacity']}, '
            'status=${sample['status']}');
      }

      final tables = tablesList
          .whereType<Map>()
          .map((m) => _parseTable(Map<String, dynamic>.from(m), currentOperatorId, floorMap))
          .whereType<RestaurantTable>()
          .toList();
      ref.read(tablesProvider.notifier).state = tables;

      // Log parsed result.
      for (final t in tables.take(3)) {
        debugPrint('$_tag   Parsed → name=${t.id}, serverId=${t.serverId}, '
            'floor=${t.floor}, seats=${t.seats}, state=${t.state}');
      }
    }

    debugPrint('$_tag   Tables: ${tablesList is List ? '${tablesList.length} loaded' : 'not provided'}');

    // Menu
    final menuData = data['menu'];
    if (menuData is Map) {
      final menuMap = Map<String, dynamic>.from(menuData);
      ref.read(menuProvider.notifier).state = _parseMenuItems(menuMap);
      ref.read(rawMenuDataProvider.notifier).state = menuMap;
    }

    debugPrint('$_tag   Menu items: ${menuData is Map ? ref.read(menuProvider).length.toString() : 'not provided'}');

    // Active orders
    final ordersList = data['active_orders'] ?? data['orders'];
    if (ordersList is List) {
      final orders = ordersList
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      ref.read(activeOrdersProvider.notifier).state = orders;

      // Populate history from active orders
      ref.read(historyProvider.notifier).state =
          orders.map(_parseHistoryOrder).toList();
    }

    debugPrint('$_tag   Active orders: ${ordersList is List ? '${ordersList.length} loaded' : 'not provided'}');

    // Discounts
    final discountsRaw = data['discounts'] as List<dynamic>? ?? [];
    ref.read(discountsProvider.notifier).state =
        discountsRaw.map((d) => Map<String, dynamic>.from(d as Map)).toList();

    // Active operators
    final operatorsList = data['active_operators'];
    if (operatorsList is List) {
      final operators = operatorsList
          .whereType<Map>()
          .map((m) {
            final om = Map<String, dynamic>.from(m);
            return ActiveOperator(
              name: om['name']?.toString() ?? '',
              role: om['role']?.toString() ?? '',
            );
          })
          .toList();
      ref.read(activeOperatorsProvider.notifier).state = operators;
    }

    debugPrint('$_tag   Discounts: ${discountsRaw.length} loaded');
    debugPrint('$_tag   Active operators: ${operatorsList is List ? '${operatorsList.length}' : '0'}');
    debugPrint('$_tag ── Initial sync complete ──');

    // Mark connected
    final restaurantName = (restaurant is Map)
        ? restaurant['restaurant_name']?.toString() ?? restaurant['name']?.toString() ?? 'POS'
        : 'POS';
    ref.read(connectionProvider.notifier).state =
        ConnectionStatus(online: true, label: 'Connected · $restaurantName');
  }

  // ─── Unregister all listeners ─────────────────────────────────────────────

  /// Helper: update tablesProvider from broadcast data that includes a `tables` key.
  void _updateTablesFromBroadcast(WidgetRef ref, Map<String, dynamic> d) {
    final tablesData = d['tables'];
    if (tablesData is List) {
      final currentOperatorId = ref.read(operatorProvider)?.username;
      final tables = tablesData
          .whereType<Map>()
          .map((m) => _parseTable(Map<String, dynamic>.from(m), currentOperatorId, _floorMap))
          .whereType<RestaurantTable>()
          .toList();
      ref.read(tablesProvider.notifier).state = tables;
    }
  }

  void unregisterListeners() {
    _stateSubscription?.cancel();
    _stateSubscription = null;
    for (final event in [
      'table:updated', 'order:created', 'order:updated', 'order:cancelled',
      'kot:sent', 'bill:generated', 'bill:paid', 'discount:applied',
      'flags:updated', 'menu:updated', 'force:disconnect',
      'operator:online', 'operator:offline',
    ]) {
      _socket.off(event);
    }
  }

  // ─── Parsers ──────────────────────────────────────────────────────────────

  /// Builds a [HistoryOrder] from a raw order map (used in both the
  /// `order:created` socket listener and `applyInitialSync`).
  HistoryOrder _parseHistoryOrder(Map<String, dynamic> o) {
    final serverUuid = o['id']?.toString() ?? '';
    return HistoryOrder(
      id: o['kot_number'] as String? ?? o['order_number'] as String? ?? serverUuid,
      orderId: serverUuid,
      tableId: o['table_id'] as String? ?? '',
      time: _formatTime(o['created_at'] as String?),
      itemCount: (o['item_count'] as int?) ?? 0,
      total: (o['total'] as num?)?.toDouble() ?? 0,
      status: _parseOrderStatus(o['status'] as String?),
      lines: const [],
      notes: o['notes'] as String?,
    );
  }

  RestaurantTable? _parseTable(
    Map<String, dynamic> m,
    String? currentOperatorId, [
    Map<String, String> floorMap = const {},
  ]) {
    final serverUuid = m['id']?.toString() ?? m['table_id']?.toString();
    final displayName = m['name']?.toString() ?? serverUuid;
    if (serverUuid == null) return null;

    final seats = int.tryParse('${m['capacity'] ?? m['seats'] ?? 4}') ?? 4;

    // Resolve floor: floor_name (direct) > floor_id lookup > floor > fallback.
    final floorId = m['floor_id']?.toString();
    final floor = m['floor_name']?.toString() ??
        (floorId != null ? floorMap[floorId] : null) ??
        m['floor']?.toString() ??
        'Ground';

    final stateRaw = m['status']?.toString() ?? m['state']?.toString() ?? 'free';
    final createdBy = m['created_by']?.toString() ??
        m['operator_id']?.toString() ??
        m['active_order_created_by']?.toString();
    final tableState = _parseTableState(stateRaw, createdBy, currentOperatorId);

    return RestaurantTable(
      id: displayName!,
      serverId: serverUuid,
      seats: seats,
      floor: floor,
      state: tableState,
      waiterName: m['waiter_name']?.toString() ?? m['operator_name']?.toString(),
      coverCount: int.tryParse('${m['cover_count'] ?? m['covers'] ?? ''}'),
      bill: double.tryParse('${m['bill'] ?? m['order_total'] ?? m['total'] ?? ''}'),
      note: m['note']?.toString() ??
          m['reservation_customer']?.toString() ??
          m['reservation_note']?.toString(),
    );
  }

  /// Maps server status string to client [TableState].
  /// Server sends: 'free', 'occupied', 'reserved', 'cleaning'.
  /// 'mine' vs 'other' is derived from the active order's `created_by`.
  TableState _parseTableState(String raw, String? createdBy, String? currentOperatorId) {
    switch (raw.toLowerCase()) {
      case 'dirty':
      case 'cleaning':
        return TableState.dirty;
      case 'reserved':
        return TableState.reserved;
      case 'occupied':
        if (createdBy != null && currentOperatorId != null && createdBy == currentOperatorId) {
          return TableState.mine;
        }
        return TableState.other;
      default:
        return TableState.free;
    }
  }

  String _formatTime(String? isoDate) {
    if (isoDate == null) return '';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  OrderStatus _parseOrderStatus(String? status) {
    switch (status) {
      case 'cancelled':
        return OrderStatus.cancelled;
      case 'modified':
        return OrderStatus.modified;
      default:
        return OrderStatus.sent;
    }
  }

  List<MenuItem> _parseMenuItems(Map<String, dynamic> data) {
    final items = <MenuItem>[];

    // Support both { items: [...] } and { categories: [{ items: [...] }] }
    final rawItems = data['items'];
    final rawCategories = data['categories'];

    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is! Map) continue;
        final item = _parseMenuItem(Map<String, dynamic>.from(entry));
        if (item != null) items.add(item);
      }
    } else if (rawCategories is List) {
      for (final cat in rawCategories) {
        if (cat is! Map) continue;
        final catMap = Map<String, dynamic>.from(cat);
        final catItems = catMap['items'];
        if (catItems is! List) continue;
        for (final entry in catItems) {
          if (entry is! Map) continue;
          final item = _parseMenuItem(Map<String, dynamic>.from(entry));
          if (item != null) items.add(item);
        }
      }
    }

    return items;
  }

  MenuItem? _parseMenuItem(Map<String, dynamic> m) {
    final id = m['id']?.toString() ?? m['item_id']?.toString();
    final name = m['name']?.toString();
    if (id == null || name == null) return null;

    final section = m['section']?.toString() ??
        m['category']?.toString() ??
        m['category_name']?.toString() ??
        'Other';
    final kitchenSection = m['kitchen_section']?.toString() ??
        m['kitchen']?.toString() ??
        section.toLowerCase();
    final price = double.tryParse('${m['price'] ?? 0}') ?? 0.0;

    final vegRaw = m['is_veg'] ?? m['veg'];
    bool isVeg = false;
    if (vegRaw is bool) {
      isVeg = vegRaw;
    } else if (vegRaw is int) {
      isVeg = vegRaw == 1;
    } else if (vegRaw is String) {
      isVeg = vegRaw == '1' || vegRaw == 'true';
    }

    final availRaw = m['available'] ?? m['is_available'] ?? true;
    bool available = true;
    if (availRaw is bool) {
      available = availRaw;
    } else if (availRaw is int) {
      available = availRaw == 1;
    } else if (availRaw is String) {
      available = availRaw == '1' || availRaw == 'true';
    }

    return MenuItem(
      id: id,
      name: name,
      section: section,
      kitchenSection: kitchenSection,
      price: price,
      isVeg: isVeg,
      available: available,
      note: m['note']?.toString(),
    );
  }
}
