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
import 'kot_queue_service.dart';
import 'log.dart';
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
      // An occupied table with nobody attached belongs to somebody else
      // until the desk says otherwise. The old code fell through to `mine`
      // when the operator list was empty, so waiters saw other people's
      // tables as their own.
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
      logD(_tag, '  Isolate parse unavailable ($e) — parsing inline');
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
    _applyPendingFastAdd();
  }

  SyncService(this._socket, this._ref);

  /// Every broadcast this service subscribes to.
  ///
  /// `registerListeners` and `unregisterListeners` both walk this one list.
  /// They used to keep separate hand-maintained lists and the unregister side
  /// was missing five events — `room:updated`, `offer:applied`,
  /// `menu:access:updated`, `error:validation` and `error:permission`. Since
  /// both auth and reconnect do `unregister(); register();` on the same
  /// socket, those five accumulated a handler per pass, and one
  /// `menu:access:updated` broadcast then triggered N full resyncs across
  /// every paired device.
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
    // Re-entrancy guard: a second call without an intervening unregister used
    // to leak the previous state subscription and double every handler.
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
        // Mid-shift the pairing can lapse under the operator's feet — the
        // token reaches its expiry, or an admin revokes the device. socket.io
        // then retries every 2s forever and this banner said "Reconnecting…"
        // indefinitely, which reads as a Wi-Fi problem nobody can find.
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

    // A KOT the desk refused must never be invisible.
    //
    // The toast that used to be the whole of this is still raised, because it
    // is the thing that catches the eye in the moment. But it is no longer
    // the *record*: `rejectedKotsProvider` owns that, it is restored from the
    // durable dead-letter list on launch, and it drives a banner that stays
    // up until the operator acknowledges it. A three-second toast was the
    // only notice for a round the kitchen never received — miss it and the
    // failure was gone.
    //
    // Reading the provider here also constructs the notifier, so the restore
    // happens even if no banner has been built yet.
    _ref.read(rejectedKotsProvider);
    _kotRejectionSubscription =
        _ref.read(kotQueueProvider).rejections.listen((rejected) {
      showAppToast('A KOT could not be sent: ${rejected.reason}');
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
        if (order != null) {
          _replaceActiveOrder(order);
          if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
        }
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
    });

    _socket.on('bill:paid', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final id = env.orderId;
      // An order can carry more than one bill (liquor/beverages billed
      // separately), and a single bill can itself be paid in partial
      // installments — BILL_PAID fires after every payment, not just the
      // one that finally settles the order. Only treat the order as
      // settled when the server says every bill is paid/credit; otherwise
      // just let the amounts refresh via the normal order/table sync.
      final orderSettled = env.orderSettled;
      if (id != null && orderSettled) {
        _removeActiveOrder(id);

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
          (t) => !(t.orderId == ticket.orderId && t.kotNumber == ticket.kotNumber),
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
        if (order != null) {
          _replaceActiveOrder(order);
          if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
        }
      }
    });

    _socket.on('offer:applied', (data) {
      final env = BroadcastEnvelope(asMap(data));
      final orderMap = env.orderMap;
      if (orderMap != null) {
        final order = _parseOrder(orderMap);
        if (order != null) {
          _replaceActiveOrder(order);
          if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
        }
      }
    });

    _socket.on('flags:updated', (data) {
      final envelope = asMap(data);
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
      if (!unchanged) unawaited(_requestResync());
    });

    // Fires when an admin edits a menu-access group's contents (not just
    // whether an operator is assigned one) — without this, crew's menu only
    // ever refreshed on the next flags:updated or manual resync, leaving it
    // showing items the operator can no longer sell (or missing newly
    // granted ones) until then.
    _socket.on('menu:access:updated', (_) {
      unawaited(_requestResync());
    });

    // Fire-and-forget emits (e.g. quick-settle's print:bill loop) have no
    // onAck — a server-side rejection previously vanished into these two
    // events with nothing listening. Surface it instead of failing silently.
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
        // Parsing is off-thread now, so two pushes in quick succession can
        // finish out of order. Only the newest one may land.
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
        if (order != null) {
          _replaceActiveOrder(order);
          if (order.itemCount > 0) _upsertHistory(_serverOrderToHistory(order));
        }
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

    _socket.on('force:disconnect', (_) {
      unregisterListeners();
      _ref.read(forceDisconnectedProvider.notifier).state = true;
      _ref.read(isAuthenticatedProvider.notifier).state = false;
      _ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Disconnected by admin');
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

  /// Best-effort table label for a phone-facing alert — falls back to the
  /// raw order id if the order/table can't be found locally (e.g. it was
  /// already cleared from activeOrdersProvider by the time the failure
  /// notification arrives).
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

  Future<void> applyInitialSync(Map<String, dynamic> data) async {
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
    // _floorMap is a LinkedHashMap built by iterating floorsList in the
    // order the server sent it (ORDER BY display_order ASC) — its values
    // are already in the right order, just never exposed to the UI before.
    _ref.read(floorNamesProvider.notifier).state = _floorMap.values.toList();
    logD(_tag, '  Floors: ${_floorMap.length} → ${_floorMap.values.toList()}');

    await _loadTimerCache();
    final tablesList = data['tables'];
    if (tablesList is List) {
      if (tablesList.isNotEmpty && tablesList.first is Map) {
        final sample = Map<String, dynamic>.from(tablesList.first);
        logD(_tag, '  Table[0] keys: ${sample.keys.toList()}');
        logD(_tag, '  Table[0] name=${sample['name']}, '
            'order_total=${sample['order_total']}, status=${sample['status']}');
      }

      final tables = parseEach(
        mapList(tablesList),
        ServerTable.fromMap,
        'ServerTable',
      ).map(_serverTableToLocal).toList();
      _ref.read(tablesProvider.notifier).state = tables;

      for (final t in tables.take(3)) {
        logD(_tag, '  Parsed → ${t.id} (${t.serverId}), '
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

    final menuRaw = data['menu'];
    if (menuRaw is Map) {
      if (_sectionUnchanged('menu', menuRaw)) {
        logD(_tag, '  Menu: unchanged — skipping re-parse');
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
            logD(_tag, '  Menu items: ${parsed.items.length}');
          }
        } catch (e, st) {
          // Never let a menu problem abort the rest of the sync — fast-add,
          // active orders and the connected status all still need to apply.
          logD(_tag, '  Menu parse failed: $e $st');
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

  /// Re-publishes an order the client already holds (e.g. the Tables screen
  /// re-opening a running table). Takes a parsed [ServerOrder] rather than
  /// round-tripping a raw map back through the parser.
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
            id: optionalStringAny(om, <String>['id', 'username']) ?? '',
          );
        }
        // The server only reports success here if our session is still
        // pinVerified — restore the transport's verified state (unblocks
        // KOT sending after any reconnect) and the app-level auth flag
        // (unblocks a silent resume right after a cold start).
        _socket.markVerified();
        _ref.read(isAuthenticatedProvider.notifier).state = true;
        unawaited(_ref.read(kotQueueProvider).flush(_socket));
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
    // Don't let a debounced table-timer write get dropped on the way out.
    if (_timerFlush?.isActive ?? false) {
      _timerFlush!.cancel();
      unawaited(_flushTimerCache());
    }
    for (final event in broadcastEvents) {
      _socket.off(event);
    }
  }

  /// Called when the provider is torn down.
  void dispose() {
    unregisterListeners();
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
    final currentOperatorId = _ref.read(operatorProvider)?.id;
    final tableState =
        mapTableStatus(st.status, currentOperatorId, st.operatorIds);

    DateTime? occupiedSince;
    if (tableState == TableState.mine) {
      final existing = _ref
          .read(tablesProvider)
          .where((t) => t.serverId == st.id)
          .firstOrNull;
      // The desk's timestamp wins. Falling back to this phone's clock meant
      // two devices showed two different "occupied for" durations on the
      // same table.
      occupiedSince = st.occupiedSince ??
          existing?.occupiedSince ??
          _tableTimerCache[st.id] ??
          DateTime.now();
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
      // A bill exists only when an order does. Tying it to `activeOrderId`
      // rather than to "is the number greater than zero" keeps both truths:
      // a free table shows nothing, and a fully comped table still shows the
      // real amount it is running — which is zero.
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

    // Amounts deliberately not logged — this ran on every broadcast and put
    // every order total into device logs.
    logD(_tag, '  Order $displayId: items=${so.itemCount}, status=${so.status}');

    return HistoryOrder(
      id: displayId,
      orderId: so.id,
      tableId: tableDisplay,
      time: _formatTime(so.createdAt),
      // The desk's business date, never a calendar date derived here. When
      // the desk hasn't sent one the field stays empty rather than guessing:
      // an empty date filters to nothing, which is visibly wrong, whereas a
      // wrong date silently disagrees with the day-end report.
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
      // Unit price only. The old fallback to `totalPrice` meant a
      // legitimately free line (comp, package component) rendered as
      // "total x qty" — the amount multiplied by the quantity twice.
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
    } catch (_) {

    }
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

  /// Parses one order off a broadcast, or null if it fails validation.
  /// A single malformed order must not take down a whole sync.
  ServerOrder? _parseOrder(Map<String, dynamic>? map) {
    if (map == null) return null;
    try {
      return ServerOrder.fromMap(map);
    } on WireFormatException catch (e) {
      logE(_tag, 'dropped a malformed order', e);
      return null;
    }
  }

  /// History is capped. It used to grow without bound across a shift — every
  /// broadcast prepended an entry and nothing ever trimmed — while each
  /// upsert did an O(n) scan of the whole list.
  static const int _maxHistoryEntries = 400;

  void _setHistory(List<HistoryOrder> entries) {
    _ref.read(historyProvider.notifier).state = entries.length >
            _maxHistoryEntries
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
    final tables = [..._ref.read(tablesProvider)];
    final idx = tables.indexWhere((t) => t.serverId == order.tableId);
    if (idx < 0) return;
    final current = tables[idx];
    // Zero is a real amount. The old guards ("total > 0 ? total : current")
    // treated it as "no data", so voiding every line or discounting to zero
    // left the table tile displaying its previous total indefinitely.
    tables[idx] = current.copyWith(
      state: current.state == TableState.free ? TableState.mine : current.state,
      activeOrderId: order.id,
      activeBillCount: markBilled
          ? (current.activeBillCount > 0 ? current.activeBillCount : 1)
          : current.activeBillCount,
      orderItemCount: order.itemCount,
      bill: order.total,
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
    final parsed = parseEach(tableMaps, ServerTable.fromMap, 'ServerTable');
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

  /// Fast-add tiles are resolved against the parsed catalogue, never
  /// re-parsed from raw maps — see [resolveFastAddItems].
  void _applyFastAddData(Map<String, dynamic> data) {
    final catalogue = _ref.read(menuProvider);
    if (catalogue.isEmpty) {
      // Menu hasn't landed yet. Stash and apply once it has, rather than
      // publishing tiles we cannot price.
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
