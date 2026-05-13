import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import 'socket_service.dart';

class SyncService {
  final SocketService _socket;
  StreamSubscription<SocketState>? _stateSubscription;

  SyncService(this._socket);

  // ─── Listener registration ───────────────────────────────────────────────

  void registerListeners(WidgetRef ref) {
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
      final updated = _parseTable(map, currentOperatorId);
      if (updated == null) return;
      final tables = [...ref.read(tablesProvider)];
      final idx = tables.indexWhere((t) => t.id == updated.id);
      if (idx >= 0) {
        tables[idx] = updated;
      } else {
        tables.add(updated);
      }
      ref.read(tablesProvider.notifier).state = tables;
    });

    _socket.on('order:created', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final orders = [...ref.read(activeOrdersProvider), map];
      ref.read(activeOrdersProvider.notifier).state = orders;

      // Also add to history
      final historyOrder = HistoryOrder(
        id: map['kot_number'] as String? ?? map['order_number'] as String? ?? map['id'] as String? ?? '',
        tableId: map['table_id'] as String? ?? '',
        time: _formatTime(map['created_at'] as String?),
        itemCount: (map['item_count'] as int?) ?? 0,
        total: (map['total'] as num?)?.toDouble() ?? 0,
        status: _parseOrderStatus(map['status'] as String?),
        lines: const [],
        notes: map['notes'] as String?,
      );
      ref.read(historyProvider.notifier).state = [
        historyOrder,
        ...ref.read(historyProvider),
      ];

      // Update operator stats on new order.
      final stats = ref.read(operatorStatsProvider);
      ref.read(operatorStatsProvider.notifier).state = OperatorStats(
        ordersToday: stats.ordersToday + 1,
        tablesServed: stats.tablesServed,
        itemsSold: stats.itemsSold + ((map['item_count'] as int?) ?? 0),
      );
    });

    _socket.on('order:updated', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final orderId = map['id']?.toString();
      if (orderId == null) return;
      final orders = [
        for (final o in ref.read(activeOrdersProvider))
          if (o['id']?.toString() == orderId) map else o,
      ];
      ref.read(activeOrdersProvider.notifier).state = orders;
    });

    _socket.on('order:cancelled', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final orderId = map['id']?.toString();
      if (orderId == null) return;
      final orders = ref.read(activeOrdersProvider)
          .where((o) => o['id']?.toString() != orderId)
          .toList();
      ref.read(activeOrdersProvider.notifier).state = orders;
    });

    _socket.on('flags:updated', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(map);
    });

    _socket.on('menu:updated', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final items = _parseMenuItems(map);
      ref.read(menuProvider.notifier).state = items;
      ref.read(rawMenuDataProvider.notifier).state = map;
    });

    _socket.on('force:disconnect', (_) {
      ref.read(isAuthenticatedProvider.notifier).state = false;
      ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Disconnected by admin');
      _socket.disconnect();
    });
  }

  // ─── Initial sync population ─────────────────────────────────────────────

  void applyInitialSync(WidgetRef ref, Map<String, dynamic> data) {
    // Restaurant info
    final restaurant = data['restaurant'];
    if (restaurant is Map) {
      final r = Map<String, dynamic>.from(restaurant);
      ref.read(restaurantProvider.notifier).state = RestaurantInfo(
        name: r['name']?.toString() ?? '',
        address: r['address']?.toString() ?? '',
        adminDeviceLabel: r['device_label']?.toString() ?? '',
        adminIp: r['ip']?.toString() ?? '',
      );
    }

    // Feature flags
    final flags = data['flags'];
    if (flags is Map) {
      ref.read(flagsProvider.notifier).state =
          FeatureFlags.fromMap(Map<String, dynamic>.from(flags));
    }

    // Tables
    final currentOperatorId = ref.read(operatorProvider)?.username;
    final tablesList = data['tables'];
    if (tablesList is List) {
      final tables = tablesList
          .whereType<Map>()
          .map((m) => _parseTable(Map<String, dynamic>.from(m), currentOperatorId))
          .whereType<RestaurantTable>()
          .toList();
      ref.read(tablesProvider.notifier).state = tables;
    }

    // Menu
    final menuData = data['menu'];
    if (menuData is Map) {
      final menuMap = Map<String, dynamic>.from(menuData);
      ref.read(menuProvider.notifier).state = _parseMenuItems(menuMap);
      ref.read(rawMenuDataProvider.notifier).state = menuMap;
    }

    // Active orders
    final ordersList = data['orders'];
    if (ordersList is List) {
      final orders = ordersList
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      ref.read(activeOrdersProvider.notifier).state = orders;

      // Populate history from active orders
      final historyOrders = orders.map((o) {
        return HistoryOrder(
          id: o['kot_number'] as String? ?? o['order_number'] as String? ?? o['id'] as String? ?? '',
          tableId: o['table_id'] as String? ?? '',
          time: _formatTime(o['created_at'] as String?),
          itemCount: (o['item_count'] as int?) ?? 0,
          total: (o['total'] as num?)?.toDouble() ?? 0,
          status: _parseOrderStatus(o['status'] as String?),
          lines: const [],
          notes: o['notes'] as String?,
        );
      }).toList();
      ref.read(historyProvider.notifier).state = historyOrders;
    }

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

    // Mark connected
    final restaurantName = (restaurant is Map)
        ? restaurant['name']?.toString() ?? 'POS'
        : 'POS';
    ref.read(connectionProvider.notifier).state =
        ConnectionStatus(online: true, label: 'Connected · $restaurantName');
  }

  // ─── Unregister all listeners ─────────────────────────────────────────────

  void unregisterListeners() {
    _stateSubscription?.cancel();
    _stateSubscription = null;
    _socket.off('table:updated');
    _socket.off('order:created');
    _socket.off('order:updated');
    _socket.off('order:cancelled');
    _socket.off('flags:updated');
    _socket.off('menu:updated');
    _socket.off('force:disconnect');
  }

  // ─── Parsers ──────────────────────────────────────────────────────────────

  RestaurantTable? _parseTable(Map<String, dynamic> m, String? currentOperatorId) {
    final id = m['id']?.toString() ?? m['table_id']?.toString();
    if (id == null) return null;

    final seats = int.tryParse('${m['seats'] ?? m['capacity'] ?? 4}') ?? 4;
    final floor = m['floor']?.toString().toUpperCase() ?? 'GROUND';

    final stateRaw = m['state']?.toString() ?? m['status']?.toString() ?? 'free';
    final createdBy = m['created_by']?.toString() ?? m['operator_id']?.toString();
    final tableState = _parseTableState(stateRaw, createdBy, currentOperatorId);

    return RestaurantTable(
      id: id,
      seats: seats,
      floor: floor,
      state: tableState,
      waiterName: m['waiter_name']?.toString() ?? m['operator_name']?.toString(),
      coverCount: int.tryParse('${m['cover_count'] ?? m['covers'] ?? ''}'),
      bill: double.tryParse('${m['bill'] ?? m['total'] ?? ''}'),
      note: m['note']?.toString() ?? m['reservation_note']?.toString(),
    );
  }

  TableState _parseTableState(String raw, String? createdBy, String? currentOperatorId) {
    switch (raw.toLowerCase()) {
      case 'mine':
        return TableState.mine;
      case 'other':
        return TableState.other;
      case 'dirty':
      case 'cleaning':
        return TableState.dirty;
      case 'reserved':
        return TableState.reserved;
      case 'occupied':
        // Check if this table's active order belongs to the current operator
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
