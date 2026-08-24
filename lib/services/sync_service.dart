import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/money.dart';
import '../data/providers.dart';
import '../data/rejected_kots.dart';
import '../models/feature_flags.dart';
import '../models/server_models.dart';
import '../models/wire.dart';
import '../motion/feedback_kind.dart';
import '../motion/feedback_service.dart';
import 'app_messenger.dart';
import 'floor_cache.dart';
import 'kot_queue_service.dart';
import 'log.dart';
import 'menu_parser.dart';
import 'offline_order_queue_service.dart';
import 'platform_surfaces.dart';
import 'socket_service.dart';
import 'trace.dart';

const _tag = '[Sync]';

TableState mapTableStatus(
    String status, String? currentOperatorId, List<String> tableOperatorIds) {
  switch (status.toLowerCase()) {
    case 'dirty':
    case 'cleaning':
      return TableState.dirty;
    case 'reserved':
      return TableState.reserved;
    case 'occupied':
      if (currentOperatorId == null || tableOperatorIds.isEmpty) {
        return TableState.other;
      }
      return tableOperatorIds.contains(currentOperatorId)
          ? TableState.mine
          : TableState.other;
    default:
      return TableState.free;
  }
}

class SyncService {
  final SocketService _socket;
  final Ref _ref;
  StreamSubscription<SocketState>? _stateSubscription;
  StreamSubscription<RejectedKot>? _kotRejectionSubscription;
  StreamSubscription<RejectedOrderSubmission>? _orderRejectionSubscription;
  Map<String, String> _floorMap = {};
  Map<String, DateTime> _tableTimerCache = {};
  Map<String, dynamic>? _lastFlagsMap;

  List<RestaurantTable>? _pendingTables;
  Timer? _tablesFlushTimer;

  List<RestaurantTable> get _currentTables =>
      _pendingTables ?? _ref.read(tablesProvider);

  void _setTables(List<RestaurantTable> tables) {
    _pendingTables = tables;
    _tablesFlushTimer ??= Timer(const Duration(milliseconds: 16), () {
      _tablesFlushTimer = null;
      final pending = _pendingTables;
      _pendingTables = null;
      if (pending != null) {
        _ref.read(tablesProvider.notifier).state = pending;
      }
    });
  }

  bool _liveSyncApplied = false;

  String? _lastMenuVersion;

  int _menuParseSeq = 0;

  Future<MenuParseResult> _parseMenuOffThread(Map<String, dynamic> raw) async {
    try {
      return await compute(parseMenu, raw);
    } catch (e) {
      logD(_tag, '  Isolate parse unavailable ($e) — parsing inline');
      return parseMenu(raw);
    }
  }

  void _applyParsedMenu(MenuParseResult parsed, Map<String, dynamic> raw,
      {String? version}) {
    _ref.read(menuCategoriesProvider.notifier).state = parsed.categories;
    _ref.read(menuProvider.notifier).state = parsed.items;
    _ref.read(rawMenuDataProvider.notifier).state = raw;
    _lastMenuVersion = version;
    _applyPendingFastAdd();
  }

  SyncService(this._socket, this._ref);

  static const List<String> broadcastEvents = <String>[
    'table:updated',
    'room:updated',
    'order:created',
    'order:updated',
    'order:cancelled',
    'kot:sent',
    'bill:generated',
    'bill:paid',
    'order:ready',
    'discount:applied',
    'offer:applied',
    'flags:updated',
    'menu:access:updated',
    'menu:updated',
    'fast-add:updated',
    'table:shifted',
    'table:merged',
    'table:links:updated',
    'table:presence:updated',
    'operator:online',
    'operator:offline',
    'force:disconnect',
    'kot:print:failed',
    'error:validation',
    'error:permission',
  ];

  bool _listenersRegistered = false;

  void registerListeners() {
    if (_listenersRegistered) unregisterListeners();
    _listenersRegistered = true;
    logD(_tag, 'Registering real-time listeners');

    _stateSubscription = _socket.stateStream.listen((state) {
      if (state == SocketState.connected || state == SocketState.verified) {
        final restaurant = _ref.read(restaurantProvider);
        _ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: true,
          label: 'Connected · ${restaurant?.name ?? "Restaurant"}',
        );

        if (state == SocketState.connected &&
            _ref.read(isAuthenticatedProvider)) {
          unawaited(_requestResync());
        }
      } else if (state == SocketState.disconnected) {
        final rejected =
            _socket.lastConnectFailure == ConnectFailure.authRejected;
        _ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: false,
          label: rejected
              ? 'Pairing expired — ask the admin for a new QR'
              : 'Reconnecting...',
        );
      }
    });

    _ref.read(rejectedKotsProvider);
    _kotRejectionSubscription =
        _ref.read(kotQueueProvider).rejections.listen((rejected) {
      showAppToast('A KOT could not be sent: ${rejected.reason}');
    });

    _orderRejectionSubscription =
        _ref.read(offlineOrderQueueProvider).rejections.listen((rejected) {
      showAppToast('An order could not be sent: ${rejected.reason}');
    });

    _socket.on('table:updated', (data) {
      final map = asMap(data);
      final ServerTable st;
      try {
        st = ServerTable.fromMap(map);
      } on WireFormatException catch (e) {
        logE(_tag, 'dropped a malformed table', e);
        return;
      }
      final tables = [..._currentTables];

      if (!st.isActive) {
        tables.removeWhere((t) => t.serverId == st.id);
        _setTables(tables);
        return;
      }
      final updated = _serverTableToLocal(st);
      final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
      if (idx >= 0) {
        tables[idx] = updated;
      } else {
        tables.add(updated);
      }
      _setTables(tables);
    });

    _socket.on('room:updated', (data) {
      final map = asMap(data);
      final ServerRoom sr;
      try {
        sr = ServerRoom.fromMap(map);
      } on WireFormatException catch (e) {
        logE(_tag, 'dropped a malformed room', e);
        return;
      }
      final updated = _serverRoomToLocal(sr);
      final rooms = [..._ref.read(roomsProvider)];
      final idx = rooms.indexWhere((r) => r.serverId == updated.serverId);
      if (idx >= 0) {
        rooms[idx] = updated;
      } else {
        rooms.add(updated);
      }
      _ref.read(roomsProvider.notifier).state = rooms;
    });

    _socket.on('order:created', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        applyOrderAck({'order': orderMap}, includeHistory: true);
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('order:updated', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        final order = _parseOrder(orderMap);
        if (order != null) adoptOrder(order);
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('order:cancelled', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final id = env.orderId;
      if (id != null) {
        _removeActiveOrder(id);

        _ref.read(historyProvider.notifier).state = [
          for (final h in _ref.read(historyProvider))
            if (h.orderId == id)
              h.copyWith(status: OrderStatus.cancelled)
            else
              h,
        ];
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('kot:sent', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        final order = _parseOrder(orderMap);
        if (order != null) {
          _replaceActiveOrder(order);
          _updateTableForOrder(order);
          if (order.itemCount > 0) {
            final kotType = env.kotMap?['kot_type']?.toString();
            var entry = _serverOrderToHistory(order);
            if (kotType == 'modified') {
              entry = entry.copyWith(status: OrderStatus.modified);
            }
            _upsertHistory(entry);
          }
        }
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('bill:generated', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        applyOrderAck({'order': orderMap},
            includeHistory: true, markTableBilled: true);
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('bill:paid', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final id = env.orderId;

      final orderSettled = env.orderSettled;
      if (id != null && orderSettled) {
        _removeActiveOrder(id);

        _ref.read(historyProvider.notifier).state = [
          for (final h in _ref.read(historyProvider))
            if (h.orderId == id) h.copyWith(status: OrderStatus.paid) else h,
        ];

        _ref.read(readyOrdersProvider.notifier).state = _ref
            .read(readyOrdersProvider)
            .where((t) => t.orderId != id)
            .toList();

        _ref.read(liveActivityProvider).end(id);
      }
      _ref.read(widgetSyncProvider).schedule(_ref);
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('order:ready', (data) {
      if (!_ref.read(flagsProvider).readyToServe) return;
      final m = asMap(data);
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
          (t) =>
              !(t.orderId == ticket.orderId && t.kotNumber == ticket.kotNumber),
        ),
      ];
      _ref.read(feedbackServiceProvider).fire(const FeedbackReadyChime());
      _ref.read(readyAlertsProvider).notifyReady(tableName, labels);
      _ref.read(liveActivityProvider).markReady(orderId, tableName);
      _ref.read(widgetSyncProvider).schedule(_ref);
    });

    _socket.on('discount:applied', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        final order = _parseOrder(orderMap);
        if (order != null) adoptOrder(order);
      }
    });

    _socket.on('offer:applied', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        final order = _parseOrder(orderMap);
        if (order != null) adoptOrder(order);
      }
    });

    _socket.on('flags:updated', (data) {
      final envelope = asMap(data);
      final flagsRaw = envelope['flags'];
      final flagsMap =
          (flagsRaw is Map) ? Map<String, dynamic>.from(flagsRaw) : envelope;
      _ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(flagsMap);

      const flagsEquality = DeepCollectionEquality();
      final unchanged = _lastFlagsMap != null &&
          flagsEquality.equals(_lastFlagsMap, flagsMap);
      _lastFlagsMap = flagsMap;
      if (!unchanged) unawaited(_requestResync());
    });

    _socket.on('menu:access:updated', (_) {
      unawaited(_requestMenuOnlyResync());
    });

    _socket.on('error:validation', (data) {
      final message = asMap(data)['message']?.toString();
      if (message != null && message.isNotEmpty) showAppToast(message);
    });
    _socket.on('error:permission', (data) {
      final message = asMap(data)['message']?.toString();
      if (message != null && message.isNotEmpty) showAppToast(message);
    });

    _socket.on('menu:updated', (data) async {
      final map = asMap(data);
      final seq = ++_menuParseSeq;
      _ref.read(menuLoadingProvider.notifier).state = true;
      try {
        final parsed = await _parseMenuOffThread(map);

        if (seq != _menuParseSeq) return;
        _applyParsedMenu(parsed, map);
      } catch (e, st) {
        logD(_tag, 'menu:updated parse error: $e $st');
      } finally {
        if (seq == _menuParseSeq) {
          _ref.read(menuLoadingProvider.notifier).state = false;
        }
      }
    });

    _socket.on('fast-add:updated', (data) {
      final map = asMap(data);
      _applyFastAddData(map);
    });

    _socket.on('table:shifted', (data) {
      _applyTablesFromEnvelope(BroadcastEnvelope(asMap(data)));
    });

    _socket.on('table:merged', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        final order = _parseOrder(orderMap);
        if (order != null) adoptOrder(order);
      }
      _applyTablesFromEnvelope(env);
      _applyRoomsFromEnvelope(env);
    });

    _socket.on('table:links:updated', (data) {
      final map = asMap(data);
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
      final map = asMap(data);
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
      final op = ServerOperatorPresence.fromMap(asMap(data));
      if (op.operatorName.isEmpty) return;
      final current = _ref.read(activeOperatorsProvider);
      if (current.any((o) => o.name == op.operatorName)) return;
      _ref.read(activeOperatorsProvider.notifier).state = [
        ...current,
        ActiveOperator(name: op.operatorName, role: op.role),
      ];
    });

    _socket.on('operator:offline', (data) {
      final op = ServerOperatorPresence.fromMap(asMap(data));
      _ref.read(activeOperatorsProvider.notifier).state = _ref
          .read(activeOperatorsProvider)
          .where((o) => o.name != op.operatorName)
          .toList();
    });

    _socket.on('force:disconnect', (data) {
      final reason = asMap(data)['reason']?.toString();
      if (reason == 'duplicate_login') {
        logD(_tag,
            'Ignoring force:disconnect (duplicate_login) — socket.io will reconnect');
        return;
      }
      unregisterListeners();
      _ref.read(forceDisconnectedProvider.notifier).state = true;
      _ref.read(isAuthenticatedProvider.notifier).state = false;
      _ref.read(connectionProvider.notifier).state = ConnectionStatus(
        online: false,
        label: reason == 'token_revoked'
            ? 'Disconnected by admin'
            : 'Pairing expired — scan a new QR from the admin desktop',
      );
      _socket.disconnect();
    });

    _socket.on('kot:print:failed', (data) {
      final map = asMap(data);
      final orderId = map['order_id']?.toString();
      final kotNumber = map['kot_number']?.toString();
      showKotPrintFailedAlert(
        tableOrOrderLabel: _tableLabelForOrder(orderId),
        kotNumber: kotNumber,
      );
    });
  }

  String _tableLabelForOrder(String? orderId) {
    if (orderId == null) return 'an order';
    final order = _ref
        .read(activeOrdersProvider)
        .where((o) => o.id == orderId)
        .firstOrNull;
    final tableId = order?.tableId;
    if (tableId == null || tableId.isEmpty) return 'order $orderId';
    final table = _ref
        .read(tablesProvider)
        .where((t) => t.serverId == tableId)
        .firstOrNull;
    return table != null ? 'Table ${table.id}' : 'order $orderId';
  }

  Future<void> hydrateFromFloorCache() async {
    if (_liveSyncApplied) return;
    final cached = await FloorCache.load();
    if (cached == null) return;
    if (_liveSyncApplied) return;

    _ref.read(floorNamesProvider.notifier).state = cached.floorNames;
    _ref.read(tablesProvider.notifier).state = cached.tables;
    _ref.read(roomsProvider.notifier).state = cached.rooms;
    _ref.read(isFloorDataStaleProvider.notifier).state = true;
    logD(
        _tag,
        '  Floor cache: hydrated ${cached.tables.length} tables, '
        '${cached.rooms.length} rooms (stale, awaiting live sync)');
  }

  Future<void> applyInitialSync(Map<String, dynamic> data) async {
    _liveSyncApplied = true;
    logD(_tag, '── Applying initial sync ──');
    logD(_tag, '  Keys: ${data.keys.toList()}');

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
      logD(_tag, '  Restaurant: ${info.name}');
    }

    final flagsRaw = data['feature_flags'] ?? data['flags'];
    if (flagsRaw is Map) {
      _ref.read(flagsProvider.notifier).state =
          FeatureFlags.fromMap(Map<String, dynamic>.from(flagsRaw));
      logD(_tag, '  Flags: loaded');
    }

    final floorsList = data['floors'];
    _floorMap = {};
    if (floorsList is List) {
      for (final f in parseEach(
        mapList(floorsList),
        ServerFloor.fromMap,
        'ServerFloor',
      )) {
        _floorMap[f.id] = f.name;
      }
    }

    _ref.read(floorNamesProvider.notifier).state = _floorMap.values.toList();
    logD(_tag, '  Floors: ${_floorMap.length} → ${_floorMap.values.toList()}');

    await _loadTimerCache();
    Trace.mark('timer_cache_loaded');
    final tablesList = data['tables'];
    if (tablesList is List) {
      if (tablesList.isNotEmpty && tablesList.first is Map) {
        final sample = Map<String, dynamic>.from(tablesList.first);
        logD(_tag, '  Table[0] keys: ${sample.keys.toList()}');
        logD(
            _tag,
            '  Table[0] name=${sample['name']}, '
            'order_total=${sample['order_total']}, status=${sample['status']}');
      }

      final tables = parseEach(
        mapList(tablesList),
        ServerTable.fromMap,
        'ServerTable',
      ).map(_serverTableToLocal).toList();
      _ref.read(tablesProvider.notifier).state = tables;

      for (final t in tables.take(3)) {
        logD(
            _tag,
            '  Parsed → ${t.id} (${t.serverId}), '
            'floor=${t.floor}, bill=${t.bill}, state=${t.state}');
      }
      logD(_tag, '  Tables: ${tables.length} loaded');
    }

    final roomsList = data['rooms'];
    if (roomsList is List) {
      final rooms = parseEach(
        mapList(roomsList),
        ServerRoom.fromMap,
        'ServerRoom',
      ).map(_serverRoomToLocal).toList();
      _ref.read(roomsProvider.notifier).state = rooms;
      logD(_tag, '  Rooms: ${rooms.length} loaded');
    }

    _ref.read(isFloorDataStaleProvider.notifier).state = false;
    unawaited(FloorCache.save(FloorCacheSnapshot(
      floorNames: _floorMap.values.toList(),
      tables: _ref.read(tablesProvider),
      rooms: _ref.read(roomsProvider),
    )));

    Trace.mark('floor_table_room_applied');

    final offersList = data['offers'];
    if (offersList is List) {
      final offers = <Offer>[];
      for (final raw in offersList) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final offerId = optionalString(m, 'id');
        if (offerId == null) continue;
        offers.add(Offer(
          id: offerId,
          name: stringOr(m, 'name', 'Offer'),
          ruleType: stringOr(m, 'rule_type', ''),
          couponCode: optionalString(m, 'coupon_code'),
          autoApply: boolOr(m, 'auto_apply', false),
        ));
      }
      _ref.read(offersProvider.notifier).state = offers;
      logD(_tag, '  Offers: ${offers.length} loaded');
    }

    final serverMenuVersion = data['menu_version'] as String?;
    final menuRaw = data['menu'];

    final menuVersionMatches =
        serverMenuVersion != null && serverMenuVersion == _lastMenuVersion;
    Trace.mark('menu_gate_done');
    if (menuVersionMatches) {
      logD(
          _tag, '  Menu: unchanged (menu_version matches) — skipping re-parse');
      Trace.mark('menu_parsed');
    } else if (menuRaw is Map) {
      final menuMap = Map<String, dynamic>.from(menuRaw);
      final seq = ++_menuParseSeq;
      _ref.read(menuLoadingProvider.notifier).state = true;
      try {
        final parsed = await _parseMenuOffThread(menuMap);
        if (seq == _menuParseSeq) {
          _applyParsedMenu(parsed, menuMap, version: serverMenuVersion);
          logD(_tag, '  Menu items: ${parsed.items.length}');
        }
      } catch (e, st) {
        logD(_tag, '  Menu parse failed: $e $st');
      } finally {
        if (seq == _menuParseSeq) {
          _ref.read(menuLoadingProvider.notifier).state = false;
        }
        Trace.mark('menu_parsed');
      }
    } else {
      Trace.mark('menu_parsed');
    }

    final fastAddRaw = data['fast_add'];
    if (fastAddRaw is Map) {
      _applyFastAddData(Map<String, dynamic>.from(fastAddRaw));
    }

    final ordersList = data['active_orders'] ?? data['orders'];
    if (ordersList is List) {
      final orders = parseEach(
        mapList(ordersList),
        ServerOrder.fromMap,
        'ServerOrder',
      );
      final historyEntries = <HistoryOrder>[
        for (final so in orders)
          if (so.itemCount > 0) _serverOrderToHistory(so),
      ];
      _ref.read(activeOrdersProvider.notifier).state = orders;

      final freshIds = historyEntries.map((h) => h.orderId).toSet();
      final settledEntries = _ref
          .read(historyProvider)
          .where((h) => !freshIds.contains(h.orderId))
          .toList();
      _setHistory(<HistoryOrder>[...historyEntries, ...settledEntries]);
      logD(_tag, '  Active orders: ${orders.length}');
    }

    final discountsRaw = data['discounts'];
    if (discountsRaw is List) {
      final discounts = <Map<String, dynamic>>[];
      for (final d in discountsRaw) {
        if (d is Map) discounts.add(Map<String, dynamic>.from(d));
      }
      _ref.read(discountsProvider.notifier).state = discounts;
      logD(_tag, '  Discounts: ${discounts.length}');
    }

    final name = _ref.read(restaurantProvider)?.name ?? 'POS';
    _ref.read(connectionProvider.notifier).state =
        ConnectionStatus(online: true, label: 'Connected · $name');

    _ref.read(widgetSyncProvider).schedule(_ref);

    logD(_tag, '── Initial sync complete ──');
  }

  void applyOrderAck(
    Map<String, dynamic> response, {
    bool includeHistory = false,
    bool markTableBilled = false,
  }) {
    final order = _parseOrder(optionalMap(response, 'order'));
    if (order == null) return;

    _replaceActiveOrder(order);
    _updateTableForOrder(order, markBilled: markTableBilled);

    if (includeHistory && order.itemCount > 0) {
      _upsertHistory(_serverOrderToHistory(order));
    }
  }

  void adoptOrder(ServerOrder order) {
    _replaceActiveOrder(order);
    _updateTableForOrder(order);
    if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
  }

  void applyTableAck(Map<String, dynamic> response) {
    final raw = optionalMap(response, 'table');
    if (raw == null) return;
    final ServerTable st;
    try {
      st = ServerTable.fromMap(raw);
    } on WireFormatException catch (e) {
      logE(_tag, 'dropped a malformed table ack', e);
      return;
    }
    final updated = _serverTableToLocal(st);
    final tables = [..._currentTables];
    final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
    if (idx == -1) return;
    tables[idx] = updated;
    _setTables(tables);
  }

  Future<bool> requestResync() => _requestResync();

  Future<bool> _requestMenuOnlyResync() =>
      _requestResync(sections: const ['menu']);

  Future<bool> _requestResync({List<String>? sections}) {
    _ref.read(connectionProvider.notifier).state = const ConnectionStatus(
      online: true,
      label: 'Syncing…',
    );

    Trace.mark('resync_emitted');

    final resyncPayload = <String, dynamic>{
      if (_lastMenuVersion != null) 'menu_version': _lastMenuVersion,
      if (sections != null) 'sections': sections,
    };
    return _socket.emitAck('operator:resync', resyncPayload).then((res) async {
      Trace.mark('resync_acked');
      if (res['kind'] == 'success') {
        final syncRaw = res['sync'];
        if (syncRaw is Map) {
          await applyInitialSync(Map<String, dynamic>.from(syncRaw));
        }
        final opData = res['operator'];
        if (opData is Map) {
          final om = Map<String, dynamic>.from(opData);
          _ref.read(operatorProvider.notifier).state = Operator(
            name: om['name']?.toString() ?? 'Operator',
            role: om['role']?.toString() ?? 'Waiter',
            shift: om['shift']?.toString() ?? 'Day',
            id: optionalStringAny(om, <String>['id', 'username']) ?? '',
            employeeId: om['employeeId']?.toString(),
          );
        }

        _socket.markVerified();
        _ref.read(isAuthenticatedProvider.notifier).state = true;
        unawaited(_ref.read(offlineOrderQueueProvider).flush(_socket).then(
            (_) => _ref.read(kotQueueProvider).flush(_socket)));
        return true;
      } else if (res['code'] == 'reauth_required') {
        if (await promptPinReverify()) {
          return await _requestResync();
        }
        return false;
      } else {
        return false;
      }
    }).catchError((_) {
      logD(_tag, 'Resync failed — data may be stale');
      final restaurant = _ref.read(restaurantProvider);
      _ref.read(connectionProvider.notifier).state = ConnectionStatus(
        online: true,
        label:
            'Connected · ${restaurant?.name ?? "Restaurant"} — sync failed, tap to retry',
      );
      return false;
    });
  }

  void unregisterListeners() {
    _listenersRegistered = false;
    _stateSubscription?.cancel();
    _stateSubscription = null;
    _kotRejectionSubscription?.cancel();
    _kotRejectionSubscription = null;
    _orderRejectionSubscription?.cancel();
    _orderRejectionSubscription = null;

    if (_timerFlush?.isActive ?? false) {
      _timerFlush!.cancel();
      unawaited(_flushTimerCache());
    }
    for (final event in broadcastEvents) {
      _socket.off(event);
    }
  }

  void dispose() {
    unregisterListeners();
    _tablesFlushTimer?.cancel();
  }

  static const _timerKeyPrefix = 'table_timer_';

  static const _timerBlobKey = 'table_timers_v2';

  Timer? _timerFlush;

  void _scheduleTimerFlush() {
    _timerFlush?.cancel();
    _timerFlush = Timer(
      const Duration(seconds: 2),
      () => unawaited(_flushTimerCache()),
    );
  }

  Future<void> _flushTimerCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _timerBlobKey,
        jsonEncode(
          _tableTimerCache.map((k, v) => MapEntry(k, v.toIso8601String())),
        ),
      );
    } catch (_) {}
  }

  Future<void> _loadTimerCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _tableTimerCache = {};

      final blob = prefs.getString(_timerBlobKey);
      if (blob != null) {
        final decoded = jsonDecode(blob);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final dt = DateTime.tryParse(v.toString());
            if (dt != null) _tableTimerCache[k.toString()] = dt;
          });
        }
        return;
      }

      final legacy =
          prefs.getKeys().where((k) => k.startsWith(_timerKeyPrefix)).toList();
      for (final key in legacy) {
        final dt = DateTime.tryParse(prefs.getString(key) ?? '');
        if (dt != null) {
          _tableTimerCache[key.substring(_timerKeyPrefix.length)] = dt;
        }
      }
      if (legacy.isNotEmpty) {
        await _flushTimerCache();

        await Future.wait(legacy.map(prefs.remove));
      }
    } catch (_) {
      _tableTimerCache = {};
    }
  }

  RestaurantTable _serverTableToLocal(ServerTable st) {
    final floorName = _floorMap[st.floorId] ?? st.floorId;
    final currentOperatorId = _ref.read(operatorProvider)?.id;
    final tableState =
        mapTableStatus(st.status, currentOperatorId, st.operatorIds);

    DateTime? occupiedSince;
    if (tableState == TableState.mine) {
      final existing = _ref
          .read(tablesProvider)
          .where((t) => t.serverId == st.id)
          .firstOrNull;

      occupiedSince = st.occupiedSince ??
          existing?.occupiedSince ??
          _tableTimerCache[st.id] ??
          DateTime.now();

      if (_tableTimerCache[st.id] != occupiedSince) {
        _tableTimerCache[st.id] = occupiedSince;
        _scheduleTimerFlush();
      }
    } else if (_tableTimerCache.remove(st.id) != null) {
      _scheduleTimerFlush();
    }

    return RestaurantTable(
      id: st.name,
      serverId: st.id,
      seats: st.capacity,
      floor: floorName,
      state: tableState,
      joinedOperatorIds: st.operatorIds,
      joinedOperatorNames: st.operatorNames,
      bill: st.activeOrderId == null ? null : (st.orderTotal ?? Money.zero),
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
      bill: sr.activeOrderId == null ? null : (sr.orderTotal ?? Money.zero),
    );
  }

  void _applyRoomsFromEnvelope(BroadcastEnvelope env) {
    final roomMaps = env.roomsList;
    if (roomMaps.isEmpty) return;
    final rooms = parseEach(roomMaps, ServerRoom.fromMap, 'ServerRoom')
        .map(_serverRoomToLocal)
        .toList();
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

    logD(
        _tag, '  Order $displayId: items=${so.itemCount}, status=${so.status}');

    return HistoryOrder(
      id: displayId,
      orderId: so.id,
      tableId: tableDisplay,
      time: _formatTime(so.createdAt),
      date: so.businessDate ?? '',
      itemCount: so.itemCount,
      total: so.total,
      status: _mapOrderStatus(so.status),
      lines: so.items.map(_serverItemToLine).toList(),
      notes: so.notes,
      createdBy: so.createdBy,
      customerId: so.customerId,
      customerName: so.customerName,
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
      price: item.unitPrice,
      kitchenSection: item.itemType,
      mods: mods,
      variationId: item.variationId,
      variationName: item.variationName,
      kotNumber: item.kotNumber,
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
    } catch (_) {}
    return const [];
  }

  void _replaceActiveOrder(ServerOrder order) {
    final current = _ref.read(activeOrdersProvider);
    final index = current.indexWhere((o) => o.id == order.id);
    if (index < 0) {
      _ref.read(activeOrdersProvider.notifier).state = <ServerOrder>[
        order,
        ...current,
      ];
      return;
    }
    final next = <ServerOrder>[...current];
    next[index] = order;
    _ref.read(activeOrdersProvider.notifier).state = next;
  }

  void _removeActiveOrder(String orderId) {
    _ref.read(activeOrdersProvider.notifier).state = _ref
        .read(activeOrdersProvider)
        .where((o) => o.id != orderId)
        .toList(growable: false);
  }

  ServerOrder? _parseOrder(Map<String, dynamic>? map) {
    if (map == null) return null;
    try {
      return ServerOrder.fromMap(map);
    } on WireFormatException catch (e) {
      logE(_tag, 'dropped a malformed order', e);
      return null;
    }
  }

  static const int _maxHistoryEntries = 400;

  void _setHistory(List<HistoryOrder> entries) {
    _ref.read(historyProvider.notifier).state =
        entries.length > _maxHistoryEntries
            ? entries.sublist(0, _maxHistoryEntries)
            : entries;
  }

  void _upsertHistory(HistoryOrder entry) {
    final current = _ref.read(historyProvider);
    final existingIndex = current.indexWhere((h) => h.orderId == entry.orderId);
    if (existingIndex < 0) {
      _setHistory(<HistoryOrder>[entry, ...current]);
      return;
    }
    final next = <HistoryOrder>[...current];
    next[existingIndex] = entry;
    _setHistory(next);
  }

  void _updateTableForOrder(ServerOrder order, {bool markBilled = false}) {
    if (order.tableId.isEmpty) return;
    final tables = [..._currentTables];
    final idx = tables.indexWhere((t) => t.serverId == order.tableId);
    if (idx < 0) return;
    final current = tables[idx];

    tables[idx] = current.copyWith(
      state: current.state == TableState.free ? TableState.mine : current.state,
      activeOrderId: order.id,
      activeBillCount: markBilled
          ? (current.activeBillCount > 0 ? current.activeBillCount : 1)
          : current.activeBillCount,
      orderItemCount: order.itemCount,
      bill: order.total,
    );
    _setTables(tables);
  }

  void _applyTablesFromEnvelope(BroadcastEnvelope env) {
    final tableMaps = env.tablesList;
    if (tableMaps.isEmpty) return;
    final parsed = parseEach(tableMaps, ServerTable.fromMap, 'ServerTable');
    final tables = [..._currentTables];
    for (final st in parsed) {
      if (!st.isActive) {
        tables.removeWhere((t) => t.serverId == st.id);
        continue;
      }
      final updated = _serverTableToLocal(st);
      final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
      if (idx >= 0) {
        tables[idx] = updated;
      } else {
        tables.add(updated);
      }
    }
    _setTables(tables);
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
      case 'credit':
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

  void _applyFastAddData(Map<String, dynamic> data) {
    final catalogue = _ref.read(menuProvider);
    if (catalogue.isEmpty) {
      _pendingFastAdd = data;
      return;
    }
    _pendingFastAdd = null;
    _ref.read(fastAddPinnedProvider.notifier).state =
        resolveFastAddItems(mapList(data['pinned']), catalogue);
    _ref.read(fastAddAutoProvider.notifier).state =
        resolveFastAddItems(mapList(data['auto']), catalogue);
  }

  Map<String, dynamic>? _pendingFastAdd;

  void _applyPendingFastAdd() {
    final pending = _pendingFastAdd;
    if (pending != null) _applyFastAddData(pending);
  }
}
