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

        // R1 fix: on reconnect, re-join broadcast rooms and get fresh state.
        // Only trigger when already authenticated (i.e., not the initial connect).
        if (state == SocketState.connected &&
            _ref.read(isAuthenticatedProvider)) {
          _requestResync();
        }
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
        final parsed = ServerOrder.fromMap(orderMap);
        applyOrderAck({'order': orderMap}, includeHistory: true);
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
        // D2/H2 fix: also update historyProvider so totals/items stay in sync.
        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
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
                id: h.id,
                orderId: h.orderId,
                tableId: h.tableId,
                time: h.time,
                date: h.date,
                itemCount: h.itemCount,
                total: h.total,
                status: OrderStatus.cancelled,
                lines: h.lines,
                notes: h.notes,
              )
            else
              h,
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
      if (orderMap != null) {
        applyOrderAck({'order': orderMap},
            includeHistory: true, markTableBilled: true);
      }
    });

    _socket.on('bill:paid', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final id = env.orderId;
      if (id != null) {
        _ref.read(activeOrdersProvider.notifier).state = _ref
            .read(activeOrdersProvider)
            .where((o) => o['id']?.toString() != id)
            .toList();
        // Mark history entry as paid so UI doesn't show "Generate Bill" again.
        _ref.read(historyProvider.notifier).state = [
          for (final h in _ref.read(historyProvider))
            if (h.orderId == id)
              HistoryOrder(
                id: h.id,
                orderId: h.orderId,
                tableId: h.tableId,
                time: h.time,
                date: h.date,
                itemCount: h.itemCount,
                total: h.total,
                status: OrderStatus.paid,
                lines: h.lines,
                notes: h.notes,
              )
            else
              h,
        ];
        // Increment tablesServed stat for this operator session.
        final stats = _ref.read(operatorStatsProvider);
        _ref.read(operatorStatsProvider.notifier).state = OperatorStats(
          ordersToday: stats.ordersToday,
          tablesServed: stats.tablesServed + 1,
          itemsSold: stats.itemsSold,
        );
      }
      _applyTablesFromEnvelope(env);
    });

    _socket.on('discount:applied', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);
        // D2/H2 fix: discount changes the total — update history so the
        // order detail screen shows the discounted amount immediately.
        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
      }
    });

    _socket.on('flags:updated', (data) {
      final envelope = _toMap(data);
      final flagsRaw = envelope['flags'];
      final flagsMap =
          (flagsRaw is Map) ? Map<String, dynamic>.from(flagsRaw) : envelope;
      _ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(flagsMap);
    });

    _socket.on('menu:updated', (data) {
      final map = _toMap(data);
      _ref.read(menuProvider.notifier).state = _parseMenuItems(map);
      _ref.read(rawMenuDataProvider.notifier).state = map;
    });

    _socket.on('fast-add:updated', (data) {
      final map = _toMap(data);
      _applyFastAddData(map);
    });

    // Table shift — server broadcasts full updated table list.
    _socket.on('table:shifted', (data) {
      _applyTablesFromEnvelope(BroadcastEnvelope(_toMap(data)));
    });

    // Table merge — server broadcasts updated tables + merged order.
    _socket.on('table:merged', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);
        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
      }
      _applyTablesFromEnvelope(env);
    });

    // Table link groups updated (after link/unlink).
    _socket.on('table:links:updated', (data) {
      final map = _toMap(data);
      final groupsRaw = map['groups'];
      final newGroups = <String, List<String>>{};
      if (groupsRaw is Map) {
        for (final entry in groupsRaw.entries) {
          final key = entry.key.toString();
          final val = entry.value;
          if (val is List) {
            newGroups[key] = val.map((e) => e.toString()).toList();
          }
        }
      }
      _ref.read(linkGroupsProvider.notifier).state = newGroups;
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
      _ref.read(forceDisconnectedProvider.notifier).state = true;
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
      final info = ServerRestaurantInfo.fromMap(
          Map<String, dynamic>.from(restaurantRaw));
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
    debugPrint(
        '$_tag   Floors: ${_floorMap.length} → ${_floorMap.values.toList()}');

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

    // Fast-add items (pinned + auto trending).
    final fastAddRaw = data['fast_add'];
    if (fastAddRaw is Map) {
      _applyFastAddData(Map<String, dynamic>.from(fastAddRaw));
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
          if (so.itemCount > 0) {
            historyEntries.add(_serverOrderToHistory(so));
          }
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

  void applyOrderAck(
    Map<String, dynamic> response, {
    bool includeHistory = false,
    bool markTableBilled = false,
  }) {
    final orderRaw = response['order'];
    if (orderRaw is! Map) return;
    final orderMap = Map<String, dynamic>.from(orderRaw);
    final order = ServerOrder.fromMap(orderMap);
    if (order.id.isEmpty) return;

    _replaceActiveOrder(orderMap);
    _updateTableForOrder(order, markBilled: markTableBilled);

    if (includeHistory && order.itemCount > 0) {
      _upsertHistory(_serverOrderToHistory(order));
    }
  }

  // ─── Reconnect re-sync ───────────────────────────────────────────────────

  /// R1 fix: after socket reconnect, re-join broadcast rooms and refresh all
  /// state via `operator:resync`. Falls back to forcing re-login if the server
  /// session has expired (PIN timeout).
  void _requestResync() {
    _socket.emitAck('operator:resync', {}).then((res) {
      if (res['kind'] == 'success') {
        final syncRaw = res['sync'];
        if (syncRaw is Map) {
          applyInitialSync(Map<String, dynamic>.from(syncRaw));
        }
      } else {
        // Server session expired — force the user to re-verify PIN.
        _ref.read(isAuthenticatedProvider.notifier).state = false;
      }
    }).catchError((_) {
      // Network error during resync — do nothing; next reconnect will retry.
    });
  }

  // ─── Unregister ───────────────────────────────────────────────────────────

  void unregisterListeners() {
    _stateSubscription?.cancel();
    _stateSubscription = null;
    for (final event in [
      'table:updated',
      'order:created',
      'order:updated',
      'order:cancelled',
      'kot:sent',
      'bill:generated',
      'bill:paid',
      'discount:applied',
      'flags:updated',
      'menu:updated',
      'force:disconnect',
      'operator:online',
      'operator:offline',
      'fast-add:updated',
      'table:shifted',
      'table:merged',
      'table:links:updated',
    ]) {
      _socket.off(event);
    }
  }

  // ─── Converters (ServerModel → local provider model) ──────────────────────

  RestaurantTable _serverTableToLocal(ServerTable st) {
    final floorName = _floorMap[st.floorId] ?? st.floorId;
    final currentOperatorId = _ref.read(operatorProvider)?.username;
    final tableState =
        _mapTableStatus(st.status, currentOperatorId, st.operatorId);

    return RestaurantTable(
      id: st.name,
      serverId: st.id,
      seats: st.capacity,
      floor: floorName,
      state: tableState,
      waiterName: st.waiterName,
      bill: st.orderTotal > 0 ? st.orderTotal : null,
      note: st.reservationCustomer,
      activeOrderId: st.activeOrderId,
      activeBillCount: st.activeBillCount,
      orderItemCount: st.orderItemCount,
      oldestKotMinutes: st.oldestKotMinutes,
      kotCount: st.kotCount,
    );
  }

  HistoryOrder _serverOrderToHistory(ServerOrder so) {
    // Resolve table display name.
    final tables = _ref.read(tablesProvider);
    String tableDisplay = so.tableId;
    for (final t in tables) {
      if (t.serverId == so.tableId) {
        tableDisplay = t.id;
        break;
      }
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
      date: _formatDate(so.createdAt),
      itemCount: so.itemCount,
      total: so.total,
      status: _mapOrderStatus(so.status),
      lines: so.items.map(_serverItemToLine).toList(),
      notes: so.notes,
    );
  }

  HistoryOrderLine _serverItemToLine(ServerOrderItem item) {
    return HistoryOrderLine(
      orderItemId: item.id,
      itemId: item.itemId,
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
    final current = _ref.read(activeOrdersProvider);
    var replaced = false;
    final next = [
      for (final o in current)
        if (o['id']?.toString() == orderId) ...[
          orderMap,
        ] else ...[
          o,
        ],
    ];
    replaced = current.any((o) => o['id']?.toString() == orderId);
    _ref.read(activeOrdersProvider.notifier).state = [
      if (!replaced) orderMap,
      ...next,
    ];
  }

  void _upsertHistory(HistoryOrder entry) {
    final current = _ref.read(historyProvider);
    final existingIndex = current.indexWhere((h) => h.orderId == entry.orderId);
    if (existingIndex < 0) {
      _ref.read(historyProvider.notifier).state = [entry, ...current];
      return;
    }
    final next = [...current];
    next[existingIndex] = entry;
    _ref.read(historyProvider.notifier).state = next;
  }

  void _updateTableForOrder(ServerOrder order, {bool markBilled = false}) {
    if (order.tableId.isEmpty) return;
    final tables = [..._ref.read(tablesProvider)];
    final idx = tables.indexWhere((t) => t.serverId == order.tableId);
    if (idx < 0) return;
    final current = tables[idx];
    tables[idx] = current.copyWith(
      state: current.state == TableState.free ? TableState.mine : current.state,
      activeOrderId: order.id,
      activeBillCount: markBilled
          ? (current.activeBillCount > 0 ? current.activeBillCount : 1)
          : current.activeBillCount,
      orderItemCount:
          order.itemCount > 0 ? order.itemCount : current.orderItemCount,
      bill: order.total > 0 ? order.total : current.bill,
    );
    _ref.read(tablesProvider.notifier).state = tables;
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

  TableState _mapTableStatus(
      String status, String? currentOperatorId, String? tableOperatorId) {
    switch (status.toLowerCase()) {
      case 'dirty':
      case 'cleaning':
        return TableState.dirty;
      case 'reserved':
        return TableState.reserved;
      case 'occupied':
        // Distinguish between tables owned by this operator vs others.
        if (currentOperatorId != null &&
            tableOperatorId != null &&
            tableOperatorId.isNotEmpty &&
            tableOperatorId != currentOperatorId) {
          return TableState.other;
        }
        return TableState.mine;
      default:
        return TableState.free;
    }
  }

  OrderStatus _mapOrderStatus(String status) {
    switch (status) {
      case 'cancelled':
      case 'voided':
        return OrderStatus.cancelled;
      case 'modified':
        return OrderStatus.modified;
      case 'paid':
      case 'closed':
        return OrderStatus.paid;
      default:
        return OrderStatus.sent;
    }
  }

  String _formatTime(String isoDate) {
    if (isoDate.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  String _formatDate(String isoDate) {
    if (isoDate.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      return '${dt.year}-'
          '${dt.month.toString().padLeft(2, '0')}-'
          '${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  // ─── Menu parsing ─────────────────────────────────────────────────────────

  List<MenuItem> _parseMenuItems(Map<String, dynamic> data) {
    final items = <MenuItem>[];
    final rawItems = data['items'];
    final rawCategories = data['categories'];
    final optionGroupsByItem = _parseOptionGroupsByItem(data);
    final categoryById = _categoryMap(rawCategories);

    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map) {
          final m = Map<String, dynamic>.from(entry);
          final categoryId = m['category_id']?.toString();
          if (categoryId != null && categoryById.containsKey(categoryId)) {
            final category = categoryById[categoryId]!;
            m['category_name'] = category.name;
            m['category_type'] ??= category.type;
          }
          final si = ServerMenuItem.fromMap(m);
          items.add(_serverMenuItemToLocal(
            si.copyWith(optionGroups: optionGroupsByItem[si.id] ?? const []),
          ));
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
                items.add(_serverMenuItemToLocal(
                  si.copyWith(
                      optionGroups: optionGroupsByItem[si.id] ?? const []),
                ));
              }
            }
          }
        }
      }
    }
    return items;
  }

  Map<String, ({String name, String type})> _categoryMap(
      dynamic rawCategories) {
    final map = <String, ({String name, String type})>{};
    if (rawCategories is! List) return map;
    for (final raw in rawCategories) {
      if (raw is! Map) continue;
      final category = Map<String, dynamic>.from(raw);
      final id = category['id']?.toString();
      if (id == null || id.isEmpty) continue;
      map[id] = (
        name: category['name']?.toString() ?? 'Other',
        type: category['type']?.toString() ?? 'food',
      );
    }
    return map;
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
      optionGroups: si.optionGroups
          .map((g) => MenuOptionGroup(
                id: g.id,
                itemId: g.itemId,
                name: g.name,
                isRequired: g.isRequired,
                minSelect: g.minSelect,
                maxSelect: g.maxSelect,
                options: g.options
                    .map((o) => MenuOption(
                          id: o.id,
                          groupId: o.groupId,
                          name: o.name,
                          priceModifier: o.priceModifier,
                        ))
                    .toList(),
              ))
          .toList(),
      variations: si.variations
          .map((v) => MenuItemVariation(
                id: v.id,
                name: v.name,
                price: v.price,
              ))
          .toList(),
    );
  }

  Map<String, List<ServerMenuOptionGroup>> _parseOptionGroupsByItem(
    Map<String, dynamic> data,
  ) {
    final rawGroups = data['item_option_groups'] ?? data['option_groups'];
    final rawOptions = data['item_options'] ?? data['options'];
    final optionsByGroup = <String, List<ServerMenuOption>>{};

    if (rawOptions is List) {
      for (final raw in rawOptions) {
        if (raw is! Map) continue;
        final option = ServerMenuOption.fromMap(Map<String, dynamic>.from(raw));
        if (option.groupId.isEmpty) continue;
        optionsByGroup.putIfAbsent(option.groupId, () => []).add(option);
      }
    }

    final groupsByItem = <String, List<ServerMenuOptionGroup>>{};
    if (rawGroups is List) {
      for (final raw in rawGroups) {
        if (raw is! Map) continue;
        final group = ServerMenuOptionGroup.fromMap(
          Map<String, dynamic>.from(raw),
        );
        if (group.itemId.isEmpty) continue;
        groupsByItem.putIfAbsent(group.itemId, () => []).add(
              group.copyWith(options: optionsByGroup[group.id] ?? const []),
            );
      }
    }
    return groupsByItem;
  }

  // ─── Fast-add parsing ──────────────────────────────────────────────────────

  void _applyFastAddData(Map<String, dynamic> data) {
    final pinned = data['pinned'];
    final auto = data['auto'];
    if (pinned is List) {
      _ref.read(fastAddPinnedProvider.notifier).state = pinned
          .whereType<Map>()
          .map((m) => _serverMenuItemToLocal(
              ServerMenuItem.fromMap(Map<String, dynamic>.from(m))))
          .toList();
    }
    if (auto is List) {
      _ref.read(fastAddAutoProvider.notifier).state = auto
          .whereType<Map>()
          .map((m) => _serverMenuItemToLocal(
              ServerMenuItem.fromMap(Map<String, dynamic>.from(m))))
          .toList();
    }
  }

  // ─── Utility ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> _toMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}
