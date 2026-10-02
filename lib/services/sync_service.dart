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
import '../models/kot_print_config.dart';
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
import 'offline_session.dart';
import 'offline_snapshot.dart';
import 'platform_surfaces.dart';
import 'session_service.dart';
import 'socket_service.dart';
import 'trace.dart';

const _tag = '[Sync]';

RoomState mapRoomStatus(String status) {
  switch (status.trim().toLowerCase()) {
    case 'occupied':
      return RoomState.occupied;
    case 'dirty':
      return RoomState.dirty;
    case 'cleaning':
      return RoomState.cleaning;
    case 'clean':
      return RoomState.inspect;
    case 'blocked':
      return RoomState.blocked;
    default:
      return RoomState.free;
  }
}

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

  /// Whether a live desk sync has landed in this process (cold-start offline
  /// hydration only applies before that).
  bool get liveSyncApplied => _liveSyncApplied;

  String? _lastMenuVersion;

  /// The version of the menu currently applied, or null when none is (cold
  /// start, or before the first sync lands). Sent with `operator:resync` and
  /// `operator:verify` so the desk can leave the menu out of its reply.
  String? get cachedMenuVersion => _lastMenuVersion;

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

  SyncService(this._socket, this._ref) {
    // The active orders are what moves most while a shift runs; persist them
    // (debounced) so a cold start with the desk unreachable still shows the
    // tables' running orders.
    _ordersSub = _ref.listen<List<ServerOrder>>(
        activeOrdersProvider, (_, __) => _scheduleOrdersSave());
  }

  ProviderSubscription<List<ServerOrder>>? _ordersSub;

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
    'print_config:updated',
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

        // No resync here. ConnectionBootstrap is the single owner of the
        // post-connect resync (it also knows whether the session was
        // recovered, in which case none is needed). This listener used to fire
        // its own on `connected` while the bootstrap fired one too — two full
        // initial-sync payloads down a link that had just proven weak.
      } else if (state == SocketState.disconnected) {
        // Only a refusal that has repeated is a dead pairing; a single one is
        // treated as a blip (see ConnectionBootstrap._onConnectFailure).
        final rejected = _socket.lastConnectFailure ==
                ConnectFailure.authRejected &&
            _socket.authRejectionStreak >= 2;
        _ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: false,
          label: rejected
              ? 'Pairing expired — ask the admin for a new QR'
              : 'Reconnecting...',
        );
      }
    });

    _ref.read(rejectedKotsProvider);
    // The outbox queues pause and ask for the PIN through us when the desk
    // answers `reauth_required` (see KotQueueService.onReauthRequired).
    _ref.read(kotQueueProvider).onReauthRequired = handleReauthRequired;
    _ref.read(offlineOrderQueueProvider).onReauthRequired =
        handleReauthRequired;
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
      _snapFlags = Map<String, dynamic>.from(flagsMap);
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
        // Keep the version we hold unless the broadcast brings its own. This
        // used to pass none, which nulled `_lastMenuVersion` and made the next
        // resync/verify re-download the whole menu for nothing. A stale
        // version is safe to keep: if the desk's menu really moved on, its
        // version differs from ours and it sends the menu anyway.
        final broadcastVersion = map['menu_version'];
        _applyParsedMenu(parsed, map,
            version:
                broadcastVersion is String ? broadcastVersion : _lastMenuVersion);
        unawaited(saveSnapshot());
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
      _snapFastAdd = Map<String, dynamic>.from(map);
      _applyFastAddData(map);
    });

    // The desk's printers / print groups changed: the direct-print routing the
    // phone holds must follow, or an emergency KOT would go to a stale printer.
    _socket.on('print_config:updated', (data) {
      _applyKotPrintConfig(asMap(data)['kot_print_config']);
      unawaited(saveSnapshot());
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
      unawaited(_handleForceDisconnect(reason));
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

  /// Latched by a revoking `force:disconnect` (token revoked or pairing
  /// expired): until a *new* verified session exists ([completeResume]) nothing
  /// may write the offline session. Without it the supervisor's disconnect-edge
  /// `touchOfflineSession(force: true)` (its `_wasVerified` was still true)
  /// re-created, a moment after we cleared it, the very session that lets a
  /// revoked phone resume offline at the next boot.
  bool _sessionRevoked = false;

  /// Test seam for the `force:disconnect` broadcast handler.
  @visibleForTesting
  Future<void> debugForceDisconnect(String? reason) =>
      _handleForceDisconnect(reason);

  Future<void> _handleForceDisconnect(String? reason) async {
    unregisterListeners();
    // Flags first, synchronously: every session write is gated on them, and
    // `disconnect()` below is what makes the supervisor try to write one.
    _sessionRevoked = true;
    _lastSessionWrite = null;
    _ref.read(offlineResumedProvider.notifier).state = false;
    _ref.read(forceDisconnectedProvider.notifier).state = true;
    _ref.read(isAuthenticatedProvider.notifier).state = false;
    // The cached identity must not outlive the revocation either.
    _ref.read(operatorProvider.notifier).state = null;
    _ref.read(connectionProvider.notifier).state = ConnectionStatus(
      online: false,
      label: reason == 'token_revoked'
          ? 'Disconnected by admin'
          : 'Pairing expired — scan a new QR from the admin desktop',
    );
    _socket.disconnect();
    // After the disconnect, and awaited: a write that the teardown itself
    // provoked has already been refused by the latch, so this clear is final.
    try {
      await SessionService().clearOfflineSession();
    } catch (e) {
      logD(_tag, 'offline session clear failed: $e');
    }
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
    // Live data from the desk replaces whatever the cold-start snapshot showed.
    _ref.read(offlineResumedProvider.notifier).state = false;
    logD(_tag, '── Applying initial sync ──');
    logD(_tag, '  Keys: ${data.keys.toList()}');

    final restaurantRaw = data['restaurant_info'] ?? data['restaurant'];
    if (restaurantRaw is Map) {
      _snapRestaurant = Map<String, dynamic>.from(restaurantRaw);
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
      _snapFlags = Map<String, dynamic>.from(flagsRaw);
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
    final slotFloors = <String, String>{};
    final tablesList = data['tables'];
    if (tablesList is List) {
      if (tablesList.isNotEmpty && tablesList.first is Map) {
        final sample = Map<String, dynamic>.from(tablesList.first as Map);
        logD(_tag, '  Table[0] keys: ${sample.keys.toList()}');
        logD(
            _tag,
            '  Table[0] name=${sample['name']}, '
            'order_total=${sample['order_total']}, status=${sample['status']}');
      }

      final parsedTables = parseEach(
        mapList(tablesList),
        ServerTable.fromMap,
        'ServerTable',
      );
      for (final st in parsedTables) {
        if (st.floorId.isNotEmpty) slotFloors[st.id] = st.floorId;
      }
      final tables = parsedTables.map(_serverTableToLocal).toList();
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
      final parsedRooms = parseEach(
        mapList(roomsList),
        ServerRoom.fromMap,
        'ServerRoom',
      );
      for (final sr in parsedRooms) {
        final floorId = sr.floorId;
        if (floorId != null && floorId.isNotEmpty) slotFloors[sr.id] = floorId;
      }
      final rooms = parsedRooms.map(_serverRoomToLocal).toList();
      _ref.read(roomsProvider.notifier).state = rooms;
      logD(_tag, '  Rooms: ${rooms.length} loaded');
    }
    if (slotFloors.isNotEmpty) {
      _ref.read(slotFloorIdsProvider.notifier).state = <String, String>{
        ..._ref.read(slotFloorIdsProvider),
        ...slotFloors,
      };
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
      _snapOffers = <Map<String, dynamic>>[
        for (final raw in offersList)
          if (raw is Map) Map<String, dynamic>.from(raw),
      ];
      final offers = _parseOffers(offersList);
      _ref.read(offersProvider.notifier).state = offers;
      logD(_tag, '  Offers: ${offers.length} loaded');
    }

    // `menu` is legitimately absent whenever we sent our `menu_version` with
    // operator:resync or operator:verify and the desk found it current — the
    // cached menu is kept as-is, never cleared. The same holds if it is
    // absent for any other reason: an empty menu screen mid-shift is far
    // worse than a briefly stale one, and `menu:updated` still triggers a
    // menu-only resync when the desk's menu really changes.
    final rawMenuVersion = data['menu_version'];
    final serverMenuVersion = rawMenuVersion is String ? rawMenuVersion : null;
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
      logD(
          _tag,
          '  Menu: not in payload — keeping cached menu '
          '(${_lastMenuVersion ?? 'none'})');
      Trace.mark('menu_parsed');
    }

    final fastAddRaw = data['fast_add'];
    if (fastAddRaw is Map) {
      _snapFastAdd = Map<String, dynamic>.from(fastAddRaw);
      _applyFastAddData(Map<String, dynamic>.from(fastAddRaw));
    }

    // Direct-print routing. Present-but-null is the desk saying "no network
    // printer / print groups off" (clear it); a reply without the key at all
    // (a menu-only resync) leaves what we hold alone.
    if (data.containsKey('kot_print_config')) {
      _applyKotPrintConfig(data['kot_print_config']);
    }
    // The desk's PIN grace. A FULL sync without it is an older desk: grace 0,
    // which fails closed (no offline resume). A partial reply says nothing.
    final policyRaw = data['session_policy'];
    if (policyRaw is Map) {
      _snapPolicy = Map<String, dynamic>.from(policyRaw);
      _pinGraceMinutes = intOr(_snapPolicy!, 'pin_grace_minutes', 0);
    } else if (data.containsKey('tables')) {
      _snapPolicy = null;
      _pinGraceMinutes = 0;
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

    // The desk-confirmed state is now the freshest copy there is; make it the
    // one a cold start finds. Not awaited: a slow disk must not hold up the
    // sync that is unblocking the operator's PIN screen.
    unawaited(saveSnapshot());

    logD(_tag, '── Initial sync complete ──');
  }

  List<Offer> _parseOffers(List<dynamic> offersList) {
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
    return offers;
  }

  void _applyKotPrintConfig(Object? raw) {
    final config = KotPrintConfig.tryParse(raw);
    _snapKotConfig =
        (config != null && raw is Map) ? Map<String, dynamic>.from(raw) : null;
    _ref.read(kotPrintConfigProvider.notifier).state = config;
    logD(
        _tag,
        config == null
            ? '  KOT print config: none (direct printing unavailable)'
            : '  KOT print config: ${config.groups.length} groups');
  }

  // ------------------------------------------------------- cold-start offline

  Map<String, dynamic>? _snapRestaurant;
  Map<String, dynamic>? _snapFlags;
  Map<String, dynamic>? _snapFastAdd;
  List<Map<String, dynamic>>? _snapOffers;
  Map<String, dynamic>? _snapKotConfig;
  Map<String, dynamic>? _snapPolicy;
  int _pinGraceMinutes = 0;
  Timer? _ordersSaveTimer;

  /// Overrides the desk id read from the live pairing (tests).
  @visibleForTesting
  String? deskInstanceIdOverride;

  /// The paired desk's id, or null when unknown (no pairing yet, a demo
  /// pairing, a pairing from before desk ids): a snapshot is only ever written
  /// for a desk it can later be matched to.
  String? get _deskInstanceId {
    if (deskInstanceIdOverride != null) return deskInstanceIdOverride;
    final pairing = _ref.read(connectionBootstrapProvider.notifier).currentPairing;
    if (pairing == null || pairing.token == 'demo-token') return null;
    return pairing.deskInstanceId;
  }

  void _scheduleOrdersSave() {
    if (!_liveSyncApplied || _deskInstanceId == null) return;
    _ordersSaveTimer?.cancel();
    _ordersSaveTimer =
        Timer(const Duration(seconds: 3), () => unawaited(saveSnapshot()));
  }

  /// Writes the current desk-sourced state to disk. The menu part is only
  /// re-encoded when the menu itself changed (see [OfflineSnapshotStore]).
  /// A no-op until a live sync has landed — saving hydrated data back would
  /// only re-stamp stale data as fresh.
  Future<void> saveSnapshot() async {
    _ordersSaveTimer?.cancel();
    _ordersSaveTimer = null;
    final deskId = _deskInstanceId;
    if (!_liveSyncApplied || deskId == null) return;
    try {
      final rawMenu = _ref.read(rawMenuDataProvider);
      await _ref.read(offlineSnapshotStoreProvider).save(OfflineSnapshot(
            savedAt: DateTime.now(),
            deskInstanceId: deskId,
            restaurantInfo: _snapRestaurant,
            featureFlags: _snapFlags,
            menu: rawMenu.isEmpty ? null : rawMenu,
            menuVersion: _lastMenuVersion,
            fastAdd: _snapFastAdd,
            offers: _snapOffers ?? const <Map<String, dynamic>>[],
            activeOrders: <Map<String, dynamic>>[
              for (final o in _ref.read(activeOrdersProvider))
                if (o.raw != null) o.raw!,
            ],
            linkGroups: _ref.read(linkGroupsProvider),
            kotPrintConfig: _snapKotConfig,
            sessionPolicy: _snapPolicy ??
                <String, dynamic>{'pin_grace_minutes': _pinGraceMinutes},
            slotFloorIds: _ref.read(slotFloorIdsProvider),
          ));
    } catch (e) {
      logD(_tag, 'snapshot save failed: $e');
    }
  }

  /// Cold start with the desk unreachable: puts the last desk-confirmed data
  /// on screen. Sets providers DIRECTLY — it must not go through
  /// [applyInitialSync], which would treat the snapshot as a live sync (reset
  /// the floor names the [FloorCache] already restored because the snapshot
  /// carries no `floors`, and mark the data fresh). The data stays flagged stale
  /// and the connection is never set online. Returns false when there is no
  /// usable snapshot for this desk.
  Future<bool> hydrateFromSnapshot({String? deskInstanceId}) async {
    if (_liveSyncApplied) return false;
    final snapshot = await _ref
        .read(offlineSnapshotStoreProvider)
        .load(deskInstanceId: deskInstanceId ?? _deskInstanceId);
    if (snapshot == null || _liveSyncApplied) return false;

    final restaurant = snapshot.restaurantInfo;
    if (restaurant != null) {
      _snapRestaurant = restaurant;
      try {
        final info = ServerRestaurantInfo.fromMap(restaurant);
        _ref.read(restaurantProvider.notifier).state = RestaurantInfo(
          name: info.name,
          address: info.address,
          adminDeviceLabel: '',
          adminIp: '',
        );
      } on WireFormatException catch (e) {
        logE(_tag, 'snapshot restaurant unreadable', e);
      }
    }
    final flags = snapshot.featureFlags;
    if (flags != null) {
      _snapFlags = flags;
      _lastFlagsMap = flags;
      _ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(flags);
    }

    final menu = snapshot.menu;
    if (menu != null) {
      final seq = ++_menuParseSeq;
      final parsed = await _parseMenuOffThread(menu);
      if (seq == _menuParseSeq && !_liveSyncApplied) {
        _applyParsedMenu(parsed, menu, version: snapshot.menuVersion);
      }
    }
    final fastAdd = snapshot.fastAdd;
    if (fastAdd != null) {
      _snapFastAdd = fastAdd;
      _applyFastAddData(fastAdd);
    }
    _snapOffers = snapshot.offers;
    _ref.read(offersProvider.notifier).state = _parseOffers(snapshot.offers);

    final orders = parseEach(
      snapshot.activeOrders,
      ServerOrder.fromMap,
      'ServerOrder',
    );
    _ref.read(activeOrdersProvider.notifier).state = orders;
    _setHistory(<HistoryOrder>[
      for (final so in orders)
        if (so.itemCount > 0) _serverOrderToHistory(so),
    ]);

    _ref.read(linkGroupsProvider.notifier).state = snapshot.linkGroups;
    _snapPolicy = snapshot.sessionPolicy;
    _pinGraceMinutes = snapshot.pinGraceMinutes;
    _applyKotPrintConfig(snapshot.kotPrintConfig);
    if (snapshot.slotFloorIds.isNotEmpty) {
      _ref.read(slotFloorIdsProvider.notifier).state = snapshot.slotFloorIds;
    }
    _ref.read(isFloorDataStaleProvider.notifier).state = true;
    logD(
        _tag,
        '  Snapshot: hydrated ${orders.length} orders, menu '
        '${snapshot.menuVersion ?? 'none'} (stale, awaiting live sync)');
    return true;
  }

  DateTime? _lastSessionWrite;

  /// How often a heartbeat may rewrite the offline session's `lastSeenAt`.
  static const Duration _sessionWriteEvery = Duration(seconds: 60);

  /// Records "the desk confirmed this operator just now" for cold-start
  /// offline. [force] skips the once-a-minute throttle (a session just became
  /// verified, or the link just dropped). Never from an offline-resumed
  /// session: that would extend the window with no desk evidence at all.
  Future<void> persistOfflineSession({bool force = false}) async {
    if (_ref.read(offlineResumedProvider)) return;
    // Only a live, authenticated, un-revoked session is evidence the desk
    // vouches for this operator. A signed-out or revoked phone must never
    // re-create what its sign-out / revocation just cleared.
    if (_sessionRevoked ||
        _ref.read(forceDisconnectedProvider) ||
        !_ref.read(isAuthenticatedProvider)) {
      return;
    }
    final operator = _ref.read(operatorProvider);
    if (operator == null || operator.id.isEmpty) return;
    final pairing =
        _ref.read(connectionBootstrapProvider.notifier).currentPairing;
    if (pairing != null && pairing.token == 'demo-token') return;
    final now = DateTime.now();
    final last = _lastSessionWrite;
    if (!force && last != null && now.difference(last) < _sessionWriteEvery) {
      return;
    }
    _lastSessionWrite = now;
    try {
      await SessionService().saveOfflineSession(OfflineSession(
        operatorId: operator.id,
        name: operator.name,
        role: operator.role,
        shift: operator.shift,
        employeeId: operator.employeeId,
        deskInstanceId: pairing?.deskInstanceId ?? _deskInstanceId,
        lastSeenAt: now,
        pinGraceMinutes: _pinGraceMinutes,
      ));
    } catch (e) {
      logD(_tag, 'offline session write failed: $e');
    }
  }

  /// Fire-and-forget [persistOfflineSession] for the heartbeat and the
  /// disconnect edge.
  void touchOfflineSession({bool force = false}) =>
      unawaited(persistOfflineSession(force: force));

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

  /// `operator:verify` for [pin], carrying [cachedMenuVersion] so a desk that
  /// supports it can skip re-sending an unchanged menu. The reply goes through
  /// [applyInitialSync] like a resync's does, which tolerates the absent menu.
  Future<Map<String, dynamic>> verifyPin(String pin) =>
      _socket.verifyPin(pin, menuVersion: _lastMenuVersion);

  Future<bool> requestResync() => _requestResync();

  Future<bool> _requestMenuOnlyResync() =>
      _requestResync(sections: const ['menu']);

  /// The menu-only resync `menu:access:updated` triggers (tests).
  @visibleForTesting
  Future<bool> debugRequestMenuOnlyResync() => _requestMenuOnlyResync();

  Future<bool>? _resyncInFlight;
  bool _resyncInFlightIsFull = false;

  /// True when the last resync failed because the transport didn't answer (a
  /// timeout or a drop), as opposed to the desk answering "no". The bootstrap
  /// uses it to tell "weak link, try again" from "needs a PIN".
  bool lastResyncWasTransportFailure = false;

  /// Marks a session as resumed without a resync: verified socket,
  /// authenticated app, outbox kicked. Used for a session the desk recovered
  /// (every missed broadcast was replayed, nothing to re-download) and as the
  /// tail of a successful resync.
  void completeResume() {
    _socket.markVerified();
    _ref.read(isAuthenticatedProvider.notifier).state = true;
    // Verified by the desk: no longer running on the cold-start snapshot, and
    // this is the moment the offline session's clock restarts.
    _ref.read(offlineResumedProvider.notifier).state = false;
    // A verified session is the one thing that lifts the revocation latch.
    _sessionRevoked = false;
    touchOfflineSession(force: true);
    unawaited(_ref.read(outboxDrainProvider).kick());
  }

  Future<bool>? _reauthInFlight;

  /// Hook for the outbox queues: an ack came back `reauth_required`, so the
  /// desk wants the operator's PIN again before it accepts anything. The queues
  /// pause (keeping every item) and call this; true means the PIN was entered
  /// and they may resume. Single-flight, so a burst of refused sends raises one
  /// prompt, not one per item.
  Future<bool> handleReauthRequired() => _reauthInFlight ??=
      promptPinReverify().then((entered) {
        // The desk wants the PIN and the operator declined. Two cases, one
        // answer — back to the PIN screen (queued orders stay queued):
        //  - a cold-start offline session was only ever a loan against the
        //    grace window;
        //  - a LIVE session that outlasted the desk's PIN grace. Left
        //    authenticated, it sat on a socket that is connected but never
        //    verified: the router ignores `NeedsAuth` for an authenticated app,
        //    no banner shows, every desk action says "Needs the desk" and the
        //    outbox never drains, with no way back short of a restart.
        //    `isAuthenticated = false` hands the router the way out; the PIN
        //    screen verifies on the already-connected socket.
        if (!entered) {
          if (_ref.read(offlineResumedProvider)) {
            _ref.read(offlineResumedProvider.notifier).state = false;
          }
          _ref.read(isAuthenticatedProvider.notifier).state = false;
        }
        return entered;
      }).whenComplete(() => _reauthInFlight = null);

  /// Single-flight. Several things ask for a resync (the bootstrap on connect,
  /// `flags:updated`, `menu:access:updated`, the app resuming), often within the
  /// same second; each used to ship its own multi-hundred-KB reply down a link
  /// that was likely weak. Now:
  ///
  /// - a full request while a full one runs shares its future;
  /// - a menu-only request while any one runs shares it (a full sync carries
  ///   the menu anyway; a menu-only one is already what was asked);
  /// - a full request while a menu-only one runs waits for it, then runs its
  ///   own: the menu-only reply cannot satisfy it.
  Future<bool> _requestResync({List<String>? sections}) {
    final menuOnly = sections != null;
    final running = _resyncInFlight;
    if (running != null) {
      if (_resyncInFlightIsFull || menuOnly) return running;
      return running.then((_) => _requestResync(sections: sections));
    }
    _resyncInFlightIsFull = !menuOnly;
    late final Future<bool> tracked;
    tracked = _doResync(sections: sections).whenComplete(() {
      if (identical(_resyncInFlight, tracked)) _resyncInFlight = null;
    });
    _resyncInFlight = tracked;
    return tracked;
  }

  Future<bool> _doResync({List<String>? sections}) {
    _ref.read(connectionProvider.notifier).state = const ConnectionStatus(
      online: true,
      label: 'Syncing…',
    );

    Trace.mark('resync_emitted');

    final resyncPayload = <String, dynamic>{
      if (_lastMenuVersion != null) 'menu_version': _lastMenuVersion,
      if (sections != null) 'sections': sections,
    };
    return _socket
        .emitAck('operator:resync', resyncPayload,
            timeout: SocketService.syncBundledAckTimeout)
        .then((res) async {
      Trace.mark('resync_acked');
      lastResyncWasTransportFailure =
          res['kind'] == 'error' && isTransportFailure(res);
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

        completeResume();
        return true;
      } else if (res['code'] == 'reauth_required') {
        if (await handleReauthRequired()) {
          // Directly, not via _requestResync: this IS the in-flight resync, and
          // asking to share it would wait on itself forever.
          return await _doResync(sections: sections);
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

  /// The operator signed out / the device was unpaired: stop acting on the old
  /// session. Cancels the pending snapshot save and stops the orders listener
  /// from scheduling more (`_liveSyncApplied` gates it), so the snapshot the
  /// unpair just cleared is not re-created from the old session's state.
  void onSignedOut() {
    unregisterListeners();
    _ordersSaveTimer?.cancel();
    _ordersSaveTimer = null;
    _liveSyncApplied = false;
    _lastSessionWrite = null;
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
    _ordersSaveTimer?.cancel();
    _ordersSub?.close();
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
      state: mapRoomStatus(sr.status),
      guestName: sr.guestName,
      activeOrderId: sr.activeOrderId,
      activeBillCount: sr.activeBillCount,
      orderItemCount: sr.orderItemCount,
      bill: sr.activeOrderId == null ? null : (sr.orderTotal ?? Money.zero),
      arrivalHold: sr.arrivalHold,
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
            .whereType<Map<dynamic, dynamic>>()
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
      // Deliberately NOT `bill: order.total`. ServerOrder.total (wire field
      // `total`) is the order's own subtotal; RestaurantTable.bill must hold
      // ServerTable.orderTotal (wire field `order_total`), the desk's final
      // billable figure after GST/service charge. They are not the same
      // number — setting bill from order.total here once showed a lower,
      // wrong total on the Tables screen for every table already carrying
      // charges, the moment a broadcast without its own table snapshot
      // (e.g. kot:sent) ran after a correct table:updated. `bill` stays
      // whatever it already was; only table:updated / _applyTablesFromEnvelope
      // / a resync — all sourced from ServerTable — are allowed to change it.
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
