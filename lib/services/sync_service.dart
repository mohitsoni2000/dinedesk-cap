import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import 'socket_service.dart';

class SyncService {
  final SocketService _socket;

  SyncService(this._socket);

  // ─── Listener registration ───────────────────────────────────────────────

  void registerListeners(WidgetRef ref) {
    _socket.on('table:updated', (data) {
      final map = Map<String, dynamic>.from(data as Map);
      final updated = _parseTable(map);
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
      ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Disconnected by server');
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
    final tablesList = data['tables'];
    if (tablesList is List) {
      final tables = tablesList
          .whereType<Map>()
          .map((m) => _parseTable(Map<String, dynamic>.from(m)))
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
    }

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
    _socket.off('table:updated');
    _socket.off('order:created');
    _socket.off('order:updated');
    _socket.off('order:cancelled');
    _socket.off('flags:updated');
    _socket.off('menu:updated');
    _socket.off('force:disconnect');
  }

  // ─── Parsers ──────────────────────────────────────────────────────────────

  RestaurantTable? _parseTable(Map<String, dynamic> m) {
    final id = m['id']?.toString() ?? m['table_id']?.toString();
    if (id == null) return null;

    final seats = int.tryParse('${m['seats'] ?? m['capacity'] ?? 4}') ?? 4;
    final floor = m['floor']?.toString().toUpperCase() ?? 'GROUND';

    final stateRaw = m['state']?.toString() ?? m['status']?.toString() ?? 'free';
    final tableState = _parseTableState(stateRaw);

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

  TableState _parseTableState(String raw) {
    switch (raw.toLowerCase()) {
      case 'mine':
        return TableState.mine;
      case 'other':
        return TableState.other;
      case 'dirty':
        return TableState.dirty;
      case 'reserved':
        return TableState.reserved;
      case 'occupied':
        // If served by the current operator, mark as 'mine'; otherwise 'other'.
        // Without operator context here, default to 'other'.
        return TableState.other;
      default:
        return TableState.free;
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
