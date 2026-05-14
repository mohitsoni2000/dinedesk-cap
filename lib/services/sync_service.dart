import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import '../models/server_models.dart';
import 'socket_service.dart';

const _tag = '[Sync]';

class SyncService {
  final SocketService _socket;
  final Ref _ref;
  StreamSubscription<SocketState>? _stateSubscription;
  Map<String, String> _floorMap = {};

  SyncService(this._socket, this._ref);

  // ─── Listener registration ───────────────────────────────────────────────

  void registerListeners() {
    debugPrint('$_tag Registering real-time listeners');

    _stateSubscription = _socket.stateStream.listen((state) {
      if (state == SocketState.connected || state == SocketState.verified) {
        final restaurant = _ref.read(restaurantProvider);
        _ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: true,
          label: 'Connected · ${restaurant?.name ?? "Restaurant"}',
        );
      } else if (state == SocketState.disconnected) {
        _ref.read(connectionProvider.notifier).state = const ConnectionStatus(
          online: false,
          label: 'Reconnecting...',
        );
      }
    });

    _socket.on('table:updated', (data) {
      final map = _toMap(data);
      final st = ServerTable.fromMap(map);
      final updated = _serverTableToLocal(st);
      final tables = [..._ref.read(tablesProvider)];
      final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
      if (idx >= 0) {
        tables[idx] = updated;
      } else {
        tables.add(updated);
      }
      _ref.read(tablesProvider.notifier).state = tables;
    });

    _socket.on('order:created', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _ref.read(activeOrdersProvider.notifier).state = [
          ..._ref.read(activeOrdersProvider),
          orderMap,
        ];
        final parsed = ServerOrder.fromMap(orderMap);
        _ref.read(historyProvider.notifier).state = [
          _serverOrderToHistory(parsed),
          ..._ref.read(historyProvider),
        ];
        final stats = _ref.read(operatorStatsProvider);
        _ref.read(operatorStatsProvider.notifier).state = OperatorStats(
          ordersToday: stats.ordersToday + 1,
          tablesServed: stats.tablesServed,
          itemsSold: stats.itemsSold + parsed.itemCount,
        );
      }
      _applyTablesFromEnvelope(env);
    });

    _socket.on('order:updated', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);
      }
      _applyTablesFromEnvelope(env);
    });

    _socket.on('order:cancelled', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final id = env.orderId;
      if (id != null) {
        _ref.read(activeOrdersProvider.notifier).state = _ref
            .read(activeOrdersProvider)
            .where((o) => o['id']?.toString() != id)
            .toList();
        // Update history status to cancelled.
        _ref.read(historyProvider.notifier).state = [
          for (final h in _ref.read(historyProvider))
            if (h.orderId == id)
              HistoryOrder(
                id: h.id, orderId: h.orderId, tableId: h.tableId,
                time: h.time, itemCount: h.itemCount, total: h.total,
                status: OrderStatus.cancelled, lines: h.lines, notes: h.notes,
              )
            else h,
        ];
      }
      _applyTablesFromEnvelope(env);
    });

    _socket.on('kot:sent', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) _replaceActiveOrder(orderMap);
      _applyTablesFromEnvelope(env);
    });

    _socket.on('bill:generated', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) _replaceActiveOrder(orderMap);
    });

    _socket.on('bill:paid', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final id = env.orderId;
      if (id != null) {
        _ref.read(activeOrdersProvider.notifier).state = _ref
            .read(activeOrdersProvider)
            .where((o) => o['id']?.toString() != id)
            .toList();
      }
      _applyTablesFromEnvelope(env);
    });

    _socket.on('discount:applied', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) _replaceActiveOrder(orderMap);
    });

    _socket.on('flags:updated', (data) {
      final envelope = _toMap(data);
      final flagsRaw = envelope['flags'];
      final flagsMap = (flagsRaw is Map)
          ? Map<String, dynamic>.from(flagsRaw)
          : envelope;
      _ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(flagsMap);
    });

    _socket.on('menu:updated', (data) {
      final map = _toMap(data);
      _ref.read(menuProvider.notifier).state = _parseMenuItems(map);
      _ref.read(rawMenuDataProvider.notifier).state = map;
    });

    _socket.on('operator:online', (data) {
      final op = ServerOperatorPresence.fromMap(_toMap(data));
      if (op.operatorName.isEmpty) return;
      final current = _ref.read(activeOperatorsProvider);
      if (current.any((o) => o.name == op.operatorName)) return;
      _ref.read(activeOperatorsProvider.notifier).state = [
        ...current,
        ActiveOperator(name: op.operatorName, role: op.role),
      ];
    });

    _socket.on('operator:offline', (data) {
      final op = ServerOperatorPresence.fromMap(_toMap(data));
      _ref.read(activeOperatorsProvider.notifier).state = _ref
          .read(activeOperatorsProvider)
          .where((o) => o.name != op.operatorName)
          .toList();
    });

    _socket.on('force:disconnect', (_) {
      unregisterListeners();
      _ref.read(isAuthenticatedProvider.notifier).state = false;
      _ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Disconnected by admin');
      _socket.disconnect();
    });
  }

  // ─── Initial sync ─────────────────────────────────────────────────────────

  void applyInitialSync(Map<String, dynamic> data) {
    debugPrint('$_tag ── Applying initial sync ──');
    debugPrint('$_tag   Keys: ${data.keys.toList()}');

    // Restaurant info.
    final restaurantRaw = data['restaurant_info'] ?? data['restaurant'];
    if (restaurantRaw is Map) {
      final info = ServerRestaurantInfo.fromMap(Map<String, dynamic>.from(restaurantRaw));
      _ref.read(restaurantProvider.notifier).state = RestaurantInfo(
        name: info.name,
        address: info.address,
        adminDeviceLabel: '',
        adminIp: '',
      );
      debugPrint('$_tag   Restaurant: ${info.name}');
    }

    // Feature flags.
    final flagsRaw = data['feature_flags'] ?? data['flags'];
    if (flagsRaw is Map) {
      _ref.read(flagsProvider.notifier).state =
          FeatureFlags.fromMap(Map<String, dynamic>.from(flagsRaw));
      debugPrint('$_tag   Flags: loaded');
    }

    // Floors → build lookup map.
    final floorsList = data['floors'];
    _floorMap = {};
    if (floorsList is List) {
      for (final raw in floorsList) {
        if (raw is Map) {
          final f = ServerFloor.fromMap(Map<String, dynamic>.from(raw));
          if (f.id.isNotEmpty) _floorMap[f.id] = f.name;
        }
      }
    }
    debugPrint('$_tag   Floors: ${_floorMap.length} → ${_floorMap.values.toList()}');

    // Tables.
    final tablesList = data['tables'];
    if (tablesList is List) {
      if (tablesList.isNotEmpty && tablesList.first is Map) {
        final sample = Map<String, dynamic>.from(tablesList.first);
        debugPrint('$_tag   Table[0] keys: ${sample.keys.toList()}');
        debugPrint('$_tag   Table[0] name=${sample['name']}, '
            'order_total=${sample['order_total']}, status=${sample['status']}');
      }

      final tables = <RestaurantTable>[];
      for (final raw in tablesList) {
        if (raw is Map) {
          final st = ServerTable.fromMap(Map<String, dynamic>.from(raw));
          tables.add(_serverTableToLocal(st));
        }
      }
      _ref.read(tablesProvider.notifier).state = tables;

      for (final t in tables.take(3)) {
        debugPrint('$_tag   Parsed → ${t.id} (${t.serverId}), '
            'floor=${t.floor}, bill=${t.bill}, state=${t.state}');
      }
      debugPrint('$_tag   Tables: ${tables.length} loaded');
    }

    // Menu.
    final menuRaw = data['menu'];
    if (menuRaw is Map) {
      final menuMap = Map<String, dynamic>.from(menuRaw);
      _ref.read(menuProvider.notifier).state = _parseMenuItems(menuMap);
      _ref.read(rawMenuDataProvider.notifier).state = menuMap;
      debugPrint('$_tag   Menu items: ${_ref.read(menuProvider).length}');
    }

    // Active orders → also populate history.
    final ordersList = data['active_orders'] ?? data['orders'];
    if (ordersList is List) {
      final rawOrders = <Map<String, dynamic>>[];
      final historyEntries = <HistoryOrder>[];
      for (final raw in ordersList) {
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw);
          rawOrders.add(m);
          final so = ServerOrder.fromMap(m);
          historyEntries.add(_serverOrderToHistory(so));
        }
      }
      _ref.read(activeOrdersProvider.notifier).state = rawOrders;
      _ref.read(historyProvider.notifier).state = historyEntries;
      debugPrint('$_tag   Active orders: ${rawOrders.length}');
    }

    // Discounts.
    final discountsRaw = data['discounts'];
    if (discountsRaw is List) {
      final discounts = <Map<String, dynamic>>[];
      for (final d in discountsRaw) {
        if (d is Map) discounts.add(Map<String, dynamic>.from(d));
      }
      _ref.read(discountsProvider.notifier).state = discounts;
      debugPrint('$_tag   Discounts: ${discounts.length}');
    }

    // Connection status.
    final name = _ref.read(restaurantProvider)?.name ?? 'POS';
    _ref.read(connectionProvider.notifier).state =
        ConnectionStatus(online: true, label: 'Connected · $name');

    debugPrint('$_tag ── Initial sync complete ──');
  }

  // ─── Unregister ───────────────────────────────────────────────────────────

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

  // ─── Converters (ServerModel → local provider model) ──────────────────────

  RestaurantTable _serverTableToLocal(ServerTable st) {
    final floorName = _floorMap[st.floorId] ?? st.floorId;
    final currentOperatorId = _ref.read(operatorProvider)?.username;
    final tableState = _mapTableStatus(st.status, currentOperatorId);

    return RestaurantTable(
      id: st.name,
      serverId: st.id,
      seats: st.capacity,
      floor: floorName,
      state: tableState,
      bill: st.orderTotal > 0 ? st.orderTotal : null,
      note: st.reservationCustomer,
    );
  }

  HistoryOrder _serverOrderToHistory(ServerOrder so) {
    // Resolve table display name.
    final tables = _ref.read(tablesProvider);
    String tableDisplay = so.tableId;
    for (final t in tables) {
      if (t.serverId == so.tableId) { tableDisplay = t.id; break; }
    }

    String displayId = so.id;
    if (so.kotNumber != null && so.kotNumber!.isNotEmpty) {
      displayId = so.kotNumber!;
    } else if (so.orderNumber.isNotEmpty) {
      displayId = so.orderNumber;
    }

    debugPrint('$_tag   Order $displayId: total=${so.total}, '
        'items=${so.itemCount}, status=${so.status}');

    return HistoryOrder(
      id: displayId,
      orderId: so.id,
      tableId: tableDisplay,
      time: _formatTime(so.createdAt),
      itemCount: so.itemCount,
      total: so.total,
      status: _mapOrderStatus(so.status),
      lines: so.items.map(_serverItemToLine).toList(),
      notes: so.notes,
    );
  }

  HistoryOrderLine _serverItemToLine(ServerOrderItem item) {
    return HistoryOrderLine(
      name: item.itemName,
      qty: item.quantity,
      price: item.unitPrice > 0 ? item.unitPrice : item.totalPrice,
      kitchenSection: item.itemType,
      mods: item.selectedOptions.isNotEmpty ? [item.selectedOptions] : const [],
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  void _replaceActiveOrder(Map<String, dynamic> orderMap) {
    final orderId = orderMap['id']?.toString();
    if (orderId == null) return;
    _ref.read(activeOrdersProvider.notifier).state = [
      for (final o in _ref.read(activeOrdersProvider))
        if (o['id']?.toString() == orderId) orderMap else o,
    ];
  }

  void _applyTablesFromEnvelope(BroadcastEnvelope env) {
    final tableMaps = env.tablesList;
    if (tableMaps.isEmpty) return;
    final tables = tableMaps.map((m) {
      final st = ServerTable.fromMap(m);
      return _serverTableToLocal(st);
    }).toList();
    _ref.read(tablesProvider.notifier).state = tables;
  }

  TableState _mapTableStatus(String status, String? currentOperatorId) {
    switch (status.toLowerCase()) {
      case 'dirty':
      case 'cleaning':
        return TableState.dirty;
      case 'reserved':
        return TableState.reserved;
      case 'occupied':
        return TableState.other;
      default:
        return TableState.free;
    }
  }

  OrderStatus _mapOrderStatus(String status) {
    switch (status) {
      case 'cancelled':
        return OrderStatus.cancelled;
      case 'modified':
        return OrderStatus.modified;
      default:
        return OrderStatus.sent;
    }
  }

  String _formatTime(String isoDate) {
    if (isoDate.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  // ─── Menu parsing ─────────────────────────────────────────────────────────

  List<MenuItem> _parseMenuItems(Map<String, dynamic> data) {
    final items = <MenuItem>[];
    final rawItems = data['items'];
    final rawCategories = data['categories'];

    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map) {
          final si = ServerMenuItem.fromMap(Map<String, dynamic>.from(entry));
          items.add(_serverMenuItemToLocal(si));
        }
      }
    } else if (rawCategories is List) {
      for (final cat in rawCategories) {
        if (cat is Map) {
          final catMap = Map<String, dynamic>.from(cat);
          final catName = catMap['name']?.toString() ?? 'Other';
          final catType = catMap['type']?.toString() ?? 'food';
          final catItems = catMap['items'];
          if (catItems is List) {
            for (final entry in catItems) {
              if (entry is Map) {
                final m = Map<String, dynamic>.from(entry);
                m['category_name'] = catName;
                m['category_type'] = catType;
                final si = ServerMenuItem.fromMap(m);
                items.add(_serverMenuItemToLocal(si));
              }
            }
          }
        }
      }
    }
    return items;
  }

  MenuItem _serverMenuItemToLocal(ServerMenuItem si) {
    return MenuItem(
      id: si.id,
      name: si.name,
      section: si.categoryName,
      kitchenSection: si.categoryType,
      price: si.basePrice,
      isVeg: si.isVeg,
      available: si.isAvailable,
      note: si.note,
    );
  }

  // ─── Utility ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> _toMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}
