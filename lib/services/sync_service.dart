import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import '../models/server_models.dart';
import '../motion/feedback_kind.dart';
import '../motion/feedback_service.dart';
import 'app_messenger.dart';
import 'kot_queue_service.dart';
import 'menu_parser.dart';
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
  Map<String, dynamic>? _lastFlagsMap;

  /// Raw payload each section was last parsed from. A resync triggered by an
  /// unrelated change (a permissions tweak, say) re-ships the whole snapshot,
  /// so comparing first lets us skip re-parsing what didn't move.
  ///
  /// Only the menu is tracked, on purpose. It's the expensive parse — nested
  /// option, variation and addon groups across the whole catalogue — while
  /// tables/rooms/offers/discounts are flat field mappings. Those are also
  /// mutated by their own socket events between syncs, which would leave a
  /// payload cache able to disagree with provider state; not worth the risk
  /// for parses that are already cheap.
  final Map<String, Object?> _lastSectionRaw = {};

  static const _sectionEquality = DeepCollectionEquality();

  /// True when this section's payload matches what it was last parsed from.
  ///
  /// Pure on purpose — the cache is only written once a parse has actually
  /// been committed, so an abandoned parse can't leave it claiming a menu
  /// that was never applied.
  bool _sectionUnchanged(String key, Object? raw) =>
      _lastSectionRaw.containsKey(key) &&
      _sectionEquality.equals(_lastSectionRaw[key], raw);

  /// Guards against an older off-thread menu parse landing after a newer one.
  int _menuParseSeq = 0;

  /// Parses on a background isolate, falling back to this one if it can't be
  /// spawned. Low-RAM devices — the ones this whole change targets — are also
  /// the likeliest to refuse an isolate, and a slow menu beats no menu.
  Future<MenuParseResult> _parseMenuOffThread(Map<String, dynamic> raw) async {
    try {
      return await compute(parseMenu, raw);
    } catch (e) {
      debugPrint('$_tag   Isolate parse unavailable ($e) — parsing inline');
      return parseMenu(raw);
    }
  }

  /// Commits a parse result. [raw] is recorded as the payload the menu was
  /// built from, so [_sectionChanged] can never compare against a stale one.
  void _applyParsedMenu(MenuParseResult parsed, Map<String, dynamic> raw) {
    _ref.read(menuCategoriesProvider.notifier).state = parsed.categories;
    _ref.read(menuProvider.notifier).state = parsed.items;
    _ref.read(rawMenuDataProvider.notifier).state = raw;
    _lastSectionRaw['menu'] = raw;
  }

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
      final tables = [..._ref.read(tablesProvider)];
      // A deactivated table (e.g. a temp table from a table-rename split, freed
      // once its order settles) drops out of every future full-list push — the
      // server only tells us about it going away via this single-table event,
      // so it must be removed here rather than upserted like an active table.
      if (!st.isActive) {
        tables.removeWhere((t) => t.serverId == st.id);
        _ref.read(tablesProvider.notifier).state = tables;
        return;
      }
      final updated = _serverTableToLocal(st);
      final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
      if (idx >= 0) {
        tables[idx] = updated;
      } else {
        tables.add(updated);
      }
      _ref.read(tablesProvider.notifier).state = tables;
    });

    _socket.on('room:updated', (data) {
      final map = _toMap(data);
      final sr = ServerRoom.fromMap(map);
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
              h.copyWith(status: OrderStatus.cancelled)
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
            entry = entry.copyWith(status: OrderStatus.modified);
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
      // An order can carry more than one bill (liquor/beverages billed
      // separately), and a single bill can itself be paid in partial
      // installments — BILL_PAID fires after every payment, not just the
      // one that finally settles the order. Only treat the order as
      // settled when the server says every bill is paid/credit; otherwise
      // just let the amounts refresh via the normal order/table sync.
      final orderSettled = env.raw['order_settled'] == true;
      if (id != null && orderSettled) {
        _ref.read(activeOrdersProvider.notifier).state = _ref
            .read(activeOrdersProvider)
            .where((o) => o['id']?.toString() != id)
            .toList();

        _ref.read(historyProvider.notifier).state = [
          for (final h in _ref.read(historyProvider))
            if (h.orderId == id)
              h.copyWith(status: OrderStatus.paid)
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
      // flags — pull a fresh, freshly-filtered sync right away. But at 15+
      // online devices, an unconditional resync here means every admin
      // permissions tweak re-ships the full menu+orders snapshot to every
      // device — skip it when this push didn't actually change anything
      // (e.g. a redundant re-broadcast).
      const flagsEquality = DeepCollectionEquality();
      final unchanged = _lastFlagsMap != null &&
          flagsEquality.equals(_lastFlagsMap, flagsMap);
      _lastFlagsMap = flagsMap;
      if (!unchanged) _requestResync();
    });

    // Fires when an admin edits a menu-access group's contents (not just
    // whether an operator is assigned one) — without this, crew's menu only
    // ever refreshed on the next flags:updated or manual resync, leaving it
    // showing items the operator can no longer sell (or missing newly
    // granted ones) until then.
    _socket.on('menu:access:updated', (_) {
      _requestResync();
    });

    // Fire-and-forget emits (e.g. quick-settle's print:bill loop) have no
    // onAck — a server-side rejection previously vanished into these two
    // events with nothing listening. Surface it instead of failing silently.
    _socket.on('error:validation', (data) {
      final message = _toMap(data)['message']?.toString();
      if (message != null && message.isNotEmpty) showAppToast(message);
    });
    _socket.on('error:permission', (data) {
      final message = _toMap(data)['message']?.toString();
      if (message != null && message.isNotEmpty) showAppToast(message);
    });

    _socket.on('menu:updated', (data) async {
      final map = _toMap(data);
      final seq = ++_menuParseSeq;
      _ref.read(menuLoadingProvider.notifier).state = true;
      try {
        final parsed = await _parseMenuOffThread(map);
        // Parsing is off-thread now, so two pushes in quick succession can
        // finish out of order. Only the newest one may land.
        if (seq != _menuParseSeq) return;
        _applyParsedMenu(parsed, map);
      } catch (e, st) {
        debugPrint('$_tag menu:updated parse error: $e $st');
      } finally {
        if (seq == _menuParseSeq) {
          _ref.read(menuLoadingProvider.notifier).state = false;
        }
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

    _socket.on('kot:print:failed', (data) {
      final map = _toMap(data);
      final orderId = map['order_id']?.toString();
      final kotNumber = map['kot_number']?.toString();
      showKotPrintFailedAlert(
        tableOrOrderLabel: _tableLabelForOrder(orderId),
        kotNumber: kotNumber,
      );
    });
  }

  /// Best-effort table label for a phone-facing alert — falls back to the
  /// raw order id if the order/table can't be found locally (e.g. it was
  /// already cleared from activeOrdersProvider by the time the failure
  /// notification arrives).
  String _tableLabelForOrder(String? orderId) {
    if (orderId == null) return 'an order';
    final order = _ref
        .read(activeOrdersProvider)
        .where((o) => o['id']?.toString() == orderId)
        .firstOrNull;
    final tableId = order?['table_id']?.toString();
    if (tableId == null) return 'order $orderId';
    final table = _ref
        .read(tablesProvider)
        .where((t) => t.serverId == tableId)
        .firstOrNull;
    return table != null ? 'Table ${table.id}' : 'order $orderId';
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
    // _floorMap is a LinkedHashMap built by iterating floorsList in the
    // order the server sent it (ORDER BY display_order ASC) — its values
    // are already in the right order, just never exposed to the UI before.
    _ref.read(floorNamesProvider.notifier).state = _floorMap.values.toList();
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
          autoApply: toIntOr(m['auto_apply'], 0) == 1,
        ));
      }
      _ref.read(offersProvider.notifier).state = offers;
      debugPrint('$_tag   Offers: ${offers.length} loaded');
    }

    final menuRaw = data['menu'];
    if (menuRaw is Map) {
      if (_sectionUnchanged('menu', menuRaw)) {
        debugPrint('$_tag   Menu: unchanged — skipping re-parse');
      } else {
        final menuMap = Map<String, dynamic>.from(menuRaw);
        final seq = ++_menuParseSeq;
        _ref.read(menuLoadingProvider.notifier).state = true;
        try {
          // Off the UI thread: this is the heaviest work in a sync, and it
          // lands right as the operator is waiting on the tables screen.
          final parsed = await _parseMenuOffThread(menuMap);
          if (seq == _menuParseSeq) {
            _applyParsedMenu(parsed, menuMap);
            debugPrint('$_tag   Menu items: ${parsed.items.length}');
          }
        } catch (e, st) {
          // Never let a menu problem abort the rest of the sync — fast-add,
          // active orders and the connected status all still need to apply.
          debugPrint('$_tag   Menu parse failed: $e $st');
        } finally {
          if (seq == _menuParseSeq) {
            _ref.read(menuLoadingProvider.notifier).state = false;
          }
        }
      }
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
  /// refresh button) and for silently resuming a still-valid session right
  /// after connecting (e.g. app relaunch within the server's PIN grace
  /// window) — see [ConnectingScreen]. Returns true if the operator is now
  /// fully synced and authenticated, false if PIN re-entry is required.
  Future<bool> requestResync() => _requestResync();

  Future<bool> _requestResync() {
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
        final opData = res['operator'];
        if (opData is Map) {
          final om = Map<String, dynamic>.from(opData);
          _ref.read(operatorProvider.notifier).state = Operator(
            name: om['name']?.toString() ?? 'Operator',
            role: om['role']?.toString() ?? 'Waiter',
            shift: om['shift']?.toString() ?? 'Day',
            username: om['id']?.toString() ?? om['username']?.toString() ?? '',
          );
        }
        // The server only reports success here if our session is still
        // pinVerified — restore the transport's verified state (unblocks
        // KOT sending after any reconnect) and the app-level auth flag
        // (unblocks a silent resume right after a cold start).
        _socket.markVerified();
        _ref.read(isAuthenticatedProvider.notifier).state = true;
        _ref.read(kotQueueProvider).flush(_socket);
        return true;
      } else if (res['code'] == 'reauth_required') {
        // The desktop's PIN-verified flag has genuinely lapsed (grace window
        // expired, or its process restarted mid-session) — ask for the PIN
        // in place rather than clearing isAuthenticatedProvider, which would
        // bounce the operator to the full login screen from wherever they
        // are. Every other rejection here (a mid-flight disconnect, a
        // dropped packet) falls through to the transient-failure branch
        // below and never touches auth state at all — the next automatic
        // reconnect just retries.
        if (await promptPinReverify()) {
          return await _requestResync();
        }
        return false;
      } else {
        return false;
      }
    }).catchError((_) {
      debugPrint('$_tag Resync failed — data may be stale');
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
    _stateSubscription?.cancel();
    _stateSubscription = null;
    // Don't let a debounced table-timer write get dropped on the way out.
    if (_timerFlush?.isActive ?? false) {
      _timerFlush!.cancel();
      unawaited(_flushTimerCache());
    }
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
      'kot:print:failed',
    ]) {
      _socket.off(event);
    }
  }

  /// Legacy per-table keys. Read once at startup for migration, then removed.
  static const _timerKeyPrefix = 'table_timer_';

  /// All table timers in one key. The per-table scheme meant a full sync of N
  /// tables fired up to N separate `getInstance()` + write round trips.
  static const _timerBlobKey = 'table_timers_v2';

  Timer? _timerFlush;

  /// Coalesces a burst of table events into a single write, the same way
  /// [WidgetSyncService.schedule] does.
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
    } catch (_) {
      // A dropped timer only costs a table its "occupied for" readout.
    }
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

      // One-time migration off the per-table keys, so tables already occupied
      // at upgrade time keep their running clock.
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
        for (final key in legacy) {
          await prefs.remove(key);
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
      // Stage in memory and let the debounced flush persist it. Storing the
      // actual start time rather than "now" also means the clock survives an
      // app restart instead of restarting on the next table event.
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

  // Upserts by id rather than replacing the whole list — a floor-restricted
  // operator's initial sync is filtered to their allowed floors, but some
  // broadcasts (table shift/merge) still carry every table system-wide.
  // Wholesale-replacing on those would overwrite the filtered set with the
  // unrestricted universe within seconds of any table activity.
  void _applyTablesFromEnvelope(BroadcastEnvelope env) {
    final tableMaps = env.tablesList;
    if (tableMaps.isEmpty) return;
    final parsed = tableMaps.map((m) => ServerTable.fromMap(m)).toList();
    final tables = [..._ref.read(tablesProvider)];
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

  void _applyFastAddData(Map<String, dynamic> data) {
    final pinned = data['pinned'];
    final auto = data['auto'];
    if (pinned is List) {
      _ref.read(fastAddPinnedProvider.notifier).state = pinned
          .whereType<Map>()
          .map((m) => serverMenuItemToLocal(
              ServerMenuItem.fromMap(Map<String, dynamic>.from(m))))
          .toList();
    }
    if (auto is List) {
      _ref.read(fastAddAutoProvider.notifier).state = auto
          .whereType<Map>()
          .map((m) => serverMenuItemToLocal(
              ServerMenuItem.fromMap(Map<String, dynamic>.from(m))))
          .toList();
    }
  }

  static Map<String, dynamic> _toMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}
