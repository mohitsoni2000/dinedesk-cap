import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import '../models/server_models.dart';
import '../motion/feedback_kind.dart';
import '../motion/feedback_service.dart';
import 'kot_queue_service.dart';
import 'platform_surfaces.dart';
import 'socket_service.dart';

const _tag = '[Sync]';

/// [tableOperatorIds] must be index-parallel with the table's operator-name
/// list wherever this is called from -- both should come from the same
/// source list (e.g. ServerTable.operatorIds/operatorNames, which are
/// guaranteed parallel by construction in ServerTable.fromMap).
TableState mapTableStatus(
    String status, String? currentOperatorId, List<String> tableOperatorIds) {
  switch (status.toLowerCase()) {
    case 'dirty':
    case 'cleaning':
      return TableState.dirty;
    case 'reserved':
      return TableState.reserved;
    case 'occupied':
      if (currentOperatorId != null &&
          tableOperatorIds.isNotEmpty &&
          !tableOperatorIds.contains(currentOperatorId)) {
        return TableState.other;
      }
      return TableState.mine;
    default:
      return TableState.free;
  }
}

class SyncService {
  final SocketService _socket;
  final Ref _ref;
  StreamSubscription<SocketState>? _stateSubscription;
  Map<String, String> _floorMap = {};
  Map<String, DateTime> _tableTimerCache = {};

  SyncService(this._socket, this._ref);

  void registerListeners() {
    debugPrint('$_tag Registering real-time listeners');

    _stateSubscription = _socket.stateStream.listen((state) {
      if (state == SocketState.connected || state == SocketState.verified) {
        final restaurant = _ref.read(restaurantProvider);
        _ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: true,
          label: 'Connected · ${restaurant?.name ?? "Restaurant"}',
        );

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

        applyOrderAck({'order': orderMap}, includeHistory: true);
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('order:updated', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);

        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('order:cancelled', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final id = env.orderId;
      if (id != null) {
        _ref.read(activeOrdersProvider.notifier).state = _ref
            .read(activeOrdersProvider)
            .where((o) => o['id']?.toString() != id)
            .toList();

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
                createdBy: h.createdBy,
              )
            else
              h,
        ];
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('kot:sent', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);
        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) {
          final kotType = env.kotMap?['kot_type']?.toString();
          var entry = _serverOrderToHistory(order);
          if (kotType == 'modified') {
            entry = HistoryOrder(
              id: entry.id,
              orderId: entry.orderId,
              tableId: entry.tableId,
              time: entry.time,
              date: entry.date,
              itemCount: entry.itemCount,
              total: entry.total,
              status: OrderStatus.modified,
              lines: entry.lines,
              notes: entry.notes,
              createdBy: entry.createdBy,
            );
          }
          _upsertHistory(entry);
        }
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
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
                createdBy: h.createdBy,
              )
            else
              h,
        ];

        _ref.read(readyOrdersProvider.notifier).state =
            _ref.read(readyOrdersProvider).where((t) => t.orderId != id).toList();

        _ref.read(liveActivityProvider).end(id);
      }
      _ref.read(widgetSyncProvider).schedule(_ref);
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('order:ready', (data) {

      if (!_ref.read(flagsProvider).readyToServe) return;
      final m = _toMap(data);
      final orderId = m['order_id']?.toString();
      if (orderId == null) return;
      final tableName = (m['table_name']?.toString().isNotEmpty ?? false)
          ? m['table_name'].toString()
          : (m['order_type']?.toString() == 'takeaway' ? 'Takeaway' : 'Order');
      final rawItems = m['items'];
      final labels = <String>[];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is Map) {
            final qty = it['quantity'] ?? 1;
            final name = it['item_name']?.toString() ?? 'Item';
            labels.add('$qty× $name');
          }
        }
      }
      final ticket = ReadyTicket(
        orderId: orderId,
        tableId: m['table_id']?.toString(),
        tableName: tableName,
        kotNumber: m['kot_number']?.toString() ?? '',
        itemLabels: labels,
      );

      final current = _ref.read(readyOrdersProvider);
      _ref.read(readyOrdersProvider.notifier).state = [
        ticket,
        ...current.where(
          (t) => !(t.orderId == ticket.orderId && t.kotNumber == ticket.kotNumber),
        ),
      ];
      _ref.read(feedbackServiceProvider).fire(const FeedbackReadyChime());
      _ref.read(readyAlertsProvider).notifyReady(tableName, labels);
      _ref.read(liveActivityProvider).markReady(orderId, tableName);
      _ref.read(widgetSyncProvider).schedule(_ref);
    });

    _socket.on('discount:applied', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);

        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
      }
    });

    _socket.on('offer:applied', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);

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
      // Per-staff permissions: floor/menu access may have changed with the
      // flags — pull a fresh, freshly-filtered sync right away.
      _requestResync();
    });

    _socket.on('menu:updated', (data) async {
      final map = _toMap(data);
      _ref.read(menuLoadingProvider.notifier).state = true;
      try {
        _ref.read(menuProvider.notifier).state = _parseMenuItems(map);
        _ref.read(rawMenuDataProvider.notifier).state = map;
      } catch (e, st) {
        debugPrint('$_tag menu:updated parse error: $e $st');
      } finally {
        _ref.read(menuLoadingProvider.notifier).state = false;
      }
    });

    _socket.on('fast-add:updated', (data) {
      final map = _toMap(data);
      _applyFastAddData(map);
    });

    _socket.on('table:shifted', (data) {
      _applyTablesFromEnvelope(BroadcastEnvelope(_toMap(data)));
    });

    _socket.on('table:merged', (data) {
      final env = BroadcastEnvelope(_toMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        _replaceActiveOrder(orderMap);
        final order = ServerOrder.fromMap(orderMap);
        if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

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

    _socket.on('table:presence:updated', (data) {
      final map = _toMap(data);
      final raw = map['presences'];
      final next = <String, String>{};
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final tableId = item['table_id']?.toString() ?? '';
            final name = item['operator_name']?.toString() ?? '';
            if (tableId.isNotEmpty && name.isNotEmpty) {
              next[tableId] = name;
            }
          }
        }
      }
      _ref.read(tablePresencesProvider.notifier).state = next;
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

  Future<void> applyInitialSync(Map<String, dynamic> data) async {
    debugPrint('$_tag ── Applying initial sync ──');
    debugPrint('$_tag   Keys: ${data.keys.toList()}');

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

    final flagsRaw = data['feature_flags'] ?? data['flags'];
    if (flagsRaw is Map) {
      _ref.read(flagsProvider.notifier).state =
          FeatureFlags.fromMap(Map<String, dynamic>.from(flagsRaw));
      debugPrint('$_tag   Flags: loaded');
    }

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

    await _loadTimerCache();
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

    final roomsList = data['rooms'];
    if (roomsList is List) {
      final rooms = <RestaurantRoom>[];
      for (final raw in roomsList) {
        if (raw is Map) {
          final sr = ServerRoom.fromMap(Map<String, dynamic>.from(raw));
          rooms.add(_serverRoomToLocal(sr));
        }
      }
      _ref.read(roomsProvider.notifier).state = rooms;
      debugPrint('$_tag   Rooms: ${rooms.length} loaded');
    }

    final offersList = data['offers'];
    if (offersList is List) {
      final offers = <Offer>[];
      for (final raw in offersList) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        offers.add(Offer(
          id: m['id']?.toString() ?? '',
          name: m['name']?.toString() ?? 'Offer',
          ruleType: m['rule_type']?.toString() ?? '',
          couponCode: m['coupon_code']?.toString(),
          autoApply: _toIntOr(m['auto_apply'], 0) == 1,
        ));
      }
      _ref.read(offersProvider.notifier).state = offers;
      debugPrint('$_tag   Offers: ${offers.length} loaded');
    }

    final menuRaw = data['menu'];
    if (menuRaw is Map) {
      final menuMap = Map<String, dynamic>.from(menuRaw);
      _ref.read(menuLoadingProvider.notifier).state = true;
      _ref.read(menuProvider.notifier).state = _parseMenuItems(menuMap);
      _ref.read(rawMenuDataProvider.notifier).state = menuMap;
      _ref.read(menuLoadingProvider.notifier).state = false;
      debugPrint('$_tag   Menu items: ${_ref.read(menuProvider).length}');
    }

    final fastAddRaw = data['fast_add'];
    if (fastAddRaw is Map) {
      _applyFastAddData(Map<String, dynamic>.from(fastAddRaw));
    }

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

      final freshIds = historyEntries.map((h) => h.orderId).toSet();
      final settledEntries = _ref
          .read(historyProvider)
          .where((h) => !freshIds.contains(h.orderId))
          .toList();
      _ref.read(historyProvider.notifier).state = [...historyEntries, ...settledEntries];
      debugPrint('$_tag   Active orders: ${rawOrders.length}');
    }

    final discountsRaw = data['discounts'];
    if (discountsRaw is List) {
      final discounts = <Map<String, dynamic>>[];
      for (final d in discountsRaw) {
        if (d is Map) discounts.add(Map<String, dynamic>.from(d));
      }
      _ref.read(discountsProvider.notifier).state = discounts;
      debugPrint('$_tag   Discounts: ${discounts.length}');
    }

    final name = _ref.read(restaurantProvider)?.name ?? 'POS';
    _ref.read(connectionProvider.notifier).state =
        ConnectionStatus(online: true, label: 'Connected · $name');

    _ref.read(widgetSyncProvider).schedule(_ref);

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

  void applyTableAck(Map<String, dynamic> response) {
    final raw = response['table'];
    if (raw is! Map) return;
    final st = ServerTable.fromMap(Map<String, dynamic>.from(raw));
    final updated = _serverTableToLocal(st);
    final tables = [..._ref.read(tablesProvider)];
    final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
    if (idx == -1) return;
    tables[idx] = updated;
    _ref.read(tablesProvider.notifier).state = tables;
  }

  /// Public entry point for a user-triggered resync (e.g. the Tables screen
  /// refresh button). Internal auto-resync triggers call [_requestResync]
  /// directly and don't need the returned future.
  Future<void> requestResync() => _requestResync();

  Future<void> _requestResync() {
    _ref.read(connectionProvider.notifier).state = const ConnectionStatus(
      online: true,
      label: 'Syncing…',
    );

    return _socket.emitAck('operator:resync', {}).then((res) async {
      if (res['kind'] == 'success') {
        final syncRaw = res['sync'];
        if (syncRaw is Map) {
          await applyInitialSync(Map<String, dynamic>.from(syncRaw));
        }
        _ref.read(kotQueueProvider).flush(_socket);
      } else {
        _ref.read(isAuthenticatedProvider.notifier).state = false;
      }
    }).catchError((_) {
      debugPrint('$_tag Resync failed — data may be stale');
      final restaurant = _ref.read(restaurantProvider);
      _ref.read(connectionProvider.notifier).state = ConnectionStatus(
        online: true,
        label:
            'Connected · ${restaurant?.name ?? "Restaurant"} — sync failed, tap to retry',
      );
    });
  }

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
      'table:presence:updated',
      'order:ready',
    ]) {
      _socket.off(event);
    }
  }

  static const _timerKeyPrefix = 'table_timer_';

  Future<void> _stampTableTimer(String serverId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        '$_timerKeyPrefix$serverId', DateTime.now().toIso8601String());
  }

  Future<void> _clearTableTimer(String serverId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_timerKeyPrefix$serverId');
  }

  Future<void> _loadTimerCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_timerKeyPrefix));
      _tableTimerCache = {};
      for (final key in keys) {
        final val = prefs.getString(key);
        if (val != null) {
          final dt = DateTime.tryParse(val);
          if (dt != null) {
            _tableTimerCache[key.substring(_timerKeyPrefix.length)] = dt;
          }
        }
      }
    } catch (_) {
      _tableTimerCache = {};
    }
  }

  RestaurantTable _serverTableToLocal(ServerTable st) {
    final floorName = _floorMap[st.floorId] ?? st.floorId;
    final currentOperatorId = _ref.read(operatorProvider)?.username;
    final tableState =
        mapTableStatus(st.status, currentOperatorId, st.operatorIds);

    DateTime? occupiedSince;
    if (tableState == TableState.mine) {
      final existing = _ref
          .read(tablesProvider)
          .where((t) => t.serverId == st.id)
          .firstOrNull;
      occupiedSince =
          existing?.occupiedSince ?? _tableTimerCache[st.id] ?? DateTime.now();
      unawaited(_stampTableTimer(st.id));
    } else {
      unawaited(_clearTableTimer(st.id));
      _tableTimerCache.remove(st.id);
    }

    return RestaurantTable(
      id: st.name,
      serverId: st.id,
      seats: st.capacity,
      floor: floorName,
      state: tableState,
      joinedOperatorIds: st.operatorIds,
      joinedOperatorNames: st.operatorNames,
      bill: st.orderTotal > 0 ? st.orderTotal : null,
      note: st.reservationCustomer,
      activeOrderId: st.activeOrderId,
      activeBillCount: st.activeBillCount,
      orderItemCount: st.orderItemCount,
      oldestKotMinutes: st.oldestKotMinutes,
      kotCount: st.kotCount,
      occupiedSince: occupiedSince,
    );
  }

  RestaurantRoom _serverRoomToLocal(ServerRoom sr) {
    return RestaurantRoom(
      id: sr.name,
      serverId: sr.id,
      capacity: sr.capacity,
      state: sr.status.toLowerCase() == 'occupied'
          ? RoomState.occupied
          : RoomState.free,
      guestName: sr.guestName,
      activeOrderId: sr.activeOrderId,
      activeBillCount: sr.activeBillCount,
      orderItemCount: sr.orderItemCount,
      bill: sr.orderTotal > 0 ? sr.orderTotal : null,
    );
  }

  void _applyRoomsFromEnvelope(BroadcastEnvelope env) {
    final roomMaps = env.roomsList;
    if (roomMaps.isEmpty) return;
    final rooms = roomMaps.map((m) {
      final sr = ServerRoom.fromMap(m);
      return _serverRoomToLocal(sr);
    }).toList();
    _ref.read(roomsProvider.notifier).state = rooms;
  }

  HistoryOrder _serverOrderToHistory(ServerOrder so) {

    String tableDisplay = so.isRoom ? so.roomId : so.tableId;
    if (so.isRoom) {
      for (final r in _ref.read(roomsProvider)) {
        if (r.serverId == so.roomId) {
          tableDisplay = r.id;
          break;
        }
      }
    } else {
      for (final t in _ref.read(tablesProvider)) {
        if (t.serverId == so.tableId) {
          tableDisplay = t.id;
          break;
        }
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
      createdBy: so.createdBy,
    );
  }

  HistoryOrderLine _serverItemToLine(ServerOrderItem item) {

    final mods = <String>[
      if (item.variationName != null && item.variationName!.trim().isNotEmpty)
        item.variationName!.trim(),
      ..._parseSelectedOptionNames(item.selectedOptions),
    ];
    return HistoryOrderLine(
      orderItemId: item.id,
      itemId: item.itemId,
      name: item.itemName,
      qty: item.quantity,
      price: item.unitPrice > 0 ? item.unitPrice : item.totalPrice,
      kitchenSection: item.itemType,
      mods: mods,
      variationId: item.variationId,
      variationName: item.variationName,
    );
  }

  List<String> _parseSelectedOptionNames(String raw) {
    if (raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => (m['option_name'] ?? '').toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (_) {

    }
    return const [];
  }

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

  List<MenuItem> _parseMenuItems(Map<String, dynamic> data) {
    final items = <MenuItem>[];
    final rawItems = data['items'];
    final rawCategories = data['categories'];
    final optionGroupsByItem = _parseOptionGroupsByItem(data);
    final variationsByItem = _parseVariationsByItem(data);
    final addonGroupsByItem = _parseAddonGroupsByItem(data);
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
            si.copyWith(
              optionGroups: optionGroupsByItem[si.id] ?? const [],
              variations: variationsByItem[si.id] ?? const [],
              addonGroups: addonGroupsByItem[si.id] ?? const [],
            ),
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
                    optionGroups: optionGroupsByItem[si.id] ?? const [],
                    variations: variationsByItem[si.id] ?? const [],
                    addonGroups: addonGroupsByItem[si.id] ?? const [],
                  ),
                ));
              }
            }
          }
        }
      }
    }
    return items;
  }

  Map<String, List<ServerAddonGroup>> _parseAddonGroupsByItem(
    Map<String, dynamic> data,
  ) {
    final rawGroupDefs = data['addon_groups'];
    final rawLinks = data['item_addon_groups'];
    final rawChoices = data['addon_group_choices'];

    final choicesByGroup = <String, List<ServerAddonChoice>>{};
    if (rawChoices is List) {
      for (final raw in rawChoices) {
        if (raw is! Map) continue;
        final c = ServerAddonChoice.fromMap(Map<String, dynamic>.from(raw));
        if (c.groupId.isEmpty) continue;
        choicesByGroup.putIfAbsent(c.groupId, () => []).add(c);
      }
    }

    final groupDefById = <String, ({String name, String selectionType})>{};
    if (rawGroupDefs is List) {
      for (final raw in rawGroupDefs) {
        if (raw is! Map) continue;
        final g = Map<String, dynamic>.from(raw);
        final id = g['id']?.toString();
        if (id == null || id.isEmpty) continue;
        groupDefById[id] = (
          name: g['name']?.toString() ?? 'Add-ons',
          selectionType: g['selection_type']?.toString() ?? 'S',
        );
      }
    }

    final byItem = <String, List<ServerAddonGroup>>{};
    if (rawLinks is List) {
      for (final raw in rawLinks) {
        if (raw is! Map) continue;
        final link = Map<String, dynamic>.from(raw);
        final itemId = link['item_id']?.toString();
        final groupId = link['group_id']?.toString();
        if (itemId == null || itemId.isEmpty) continue;
        if (groupId == null || groupId.isEmpty) continue;
        final def = groupDefById[groupId];
        if (def == null) continue;
        byItem.putIfAbsent(itemId, () => []).add(ServerAddonGroup(
              id: groupId,
              itemId: itemId,
              name: def.name,
              selectionType: def.selectionType,
              minSelect: _toIntOr(link['min_select'], 0),
              maxSelect: _toIntOr(link['max_select'], 1),
              choices: choicesByGroup[groupId] ?? const [],
            ));
      }
    }
    return byItem;
  }

  int _toIntOr(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  Map<String, List<ServerItemVariation>> _parseVariationsByItem(
    Map<String, dynamic> data,
  ) {
    final rawVariations = data['item_variations'] ?? data['variations'];
    final byItem = <String, List<ServerItemVariation>>{};
    if (rawVariations is List) {
      for (final raw in rawVariations) {
        if (raw is! Map) continue;
        final v = ServerItemVariation.fromMap(Map<String, dynamic>.from(raw));
        if (v.itemId.isEmpty) continue;
        byItem.putIfAbsent(v.itemId, () => []).add(v);
      }
    }
    return byItem;
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

  double _effectivePrice(ServerMenuItem si) {
    if (si.basePrice > 0) return si.basePrice;
    final prices =
        si.variations.map((v) => v.price).where((p) => p > 0).toList();
    if (prices.isEmpty) return si.basePrice;
    return prices.reduce((a, b) => a < b ? a : b);
  }

  MenuItem _serverMenuItemToLocal(ServerMenuItem si) {
    return MenuItem(
      id: si.id,
      name: si.name,
      section: si.categoryName,
      kitchenSection: si.categoryType,
      price: _effectivePrice(si),
      isVeg: si.isVeg,
      available: si.isAvailable,
      note: si.note,
      measureUnit: si.measureUnit,
      addonGroups: si.addonGroups
          .map((g) => AddonGroup(
                id: g.id,
                itemId: g.itemId,
                name: g.name,
                selectionType: g.selectionType,
                minSelect: g.minSelect,
                maxSelect: g.maxSelect,
                choices: g.choices
                    .map((c) => AddonChoice(
                          id: c.id,
                          groupId: c.groupId,
                          name: c.name,
                          price: c.price,
                        ))
                    .toList(),
              ))
          .toList(),
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

  static Map<String, dynamic> _toMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}
