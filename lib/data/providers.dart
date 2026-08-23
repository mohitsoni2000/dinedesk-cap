import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/feature_flags.dart';
import '../models/server_models.dart';
import '../services/connection_bootstrap.dart';
import '../services/customer_link_service.dart';
import '../services/socket_service.dart';
import '../services/sync_service.dart';
import 'money.dart';

enum TableState { mine, other, dirty, reserved, free }

enum OrderStatus { sent, modified, cancelled, paid }

enum SyncStatus { synced, pending, failed }

class RestaurantTable {
  static const _absent = Object();

  final String id;
  final String serverId;
  final int seats;
  final String floor;
  final TableState state;

  final List<String> joinedOperatorIds;

  final List<String> joinedOperatorNames;
  final int? coverCount;
  final Money? bill;
  final String? note;
  final String? activeOrderId;
  final int activeBillCount;
  final int orderItemCount;
  final int oldestKotMinutes;
  final int kotCount;
  final DateTime? occupiedSince;
  const RestaurantTable({
    required this.id,
    required this.serverId,
    required this.seats,
    required this.floor,
    required this.state,
    this.joinedOperatorIds = const [],
    this.joinedOperatorNames = const [],
    this.coverCount,
    this.bill,
    this.note,
    this.activeOrderId,
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.oldestKotMinutes = 0,
    this.kotCount = 0,
    this.occupiedSince,
  });

  RestaurantTable copyWith({
    String? id,
    String? serverId,
    int? seats,
    String? floor,
    TableState? state,
    List<String>? joinedOperatorIds,
    List<String>? joinedOperatorNames,
    Object? coverCount = _absent,
    Object? bill = _absent,
    Object? note = _absent,
    Object? activeOrderId = _absent,
    int? activeBillCount,
    int? orderItemCount,
    int? oldestKotMinutes,
    int? kotCount,
    Object? occupiedSince = _absent,
  }) =>
      RestaurantTable(
        id: id ?? this.id,
        serverId: serverId ?? this.serverId,
        seats: seats ?? this.seats,
        floor: floor ?? this.floor,
        state: state ?? this.state,
        joinedOperatorIds: joinedOperatorIds ?? this.joinedOperatorIds,
        joinedOperatorNames: joinedOperatorNames ?? this.joinedOperatorNames,
        coverCount:
            coverCount == _absent ? this.coverCount : coverCount as int?,
        bill: bill == _absent ? this.bill : bill as Money?,
        note: note == _absent ? this.note : note as String?,
        activeOrderId: activeOrderId == _absent
            ? this.activeOrderId
            : activeOrderId as String?,
        activeBillCount: activeBillCount ?? this.activeBillCount,
        orderItemCount: orderItemCount ?? this.orderItemCount,
        oldestKotMinutes: oldestKotMinutes ?? this.oldestKotMinutes,
        kotCount: kotCount ?? this.kotCount,
        occupiedSince: occupiedSince == _absent
            ? this.occupiedSince
            : occupiedSince as DateTime?,
      );
}

enum RoomState { mine, occupied, free }

class RestaurantRoom {
  static const _absent = Object();

  final String id;
  final String serverId;
  final int capacity;
  final RoomState state;
  final String? guestName;
  final String? activeOrderId;
  final int activeBillCount;
  final int orderItemCount;
  final Money? bill;
  const RestaurantRoom({
    required this.id,
    required this.serverId,
    required this.capacity,
    required this.state,
    this.guestName,
    this.activeOrderId,
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.bill,
  });

  RestaurantRoom copyWith({
    String? id,
    String? serverId,
    int? capacity,
    RoomState? state,
    Object? guestName = _absent,
    Object? activeOrderId = _absent,
    int? activeBillCount,
    int? orderItemCount,
    Object? bill = _absent,
  }) =>
      RestaurantRoom(
        id: id ?? this.id,
        serverId: serverId ?? this.serverId,
        capacity: capacity ?? this.capacity,
        state: state ?? this.state,
        guestName: guestName == _absent ? this.guestName : guestName as String?,
        activeOrderId: activeOrderId == _absent
            ? this.activeOrderId
            : activeOrderId as String?,
        activeBillCount: activeBillCount ?? this.activeBillCount,
        orderItemCount: orderItemCount ?? this.orderItemCount,
        bill: bill == _absent ? this.bill : bill as Money?,
      );
}

class Offer {
  final String id;
  final String name;
  final String ruleType;
  final String? couponCode;
  final bool autoApply;
  const Offer({
    required this.id,
    required this.name,
    required this.ruleType,
    this.couponCode,
    this.autoApply = false,
  });
}

class MenuOption {
  final String id;
  final String groupId;
  final String name;
  final Money priceModifier;
  const MenuOption({
    required this.id,
    required this.groupId,
    required this.name,
    this.priceModifier = Money.zero,
  });
}

class MenuOptionGroup {
  final String id;
  final String itemId;
  final String name;
  final bool isRequired;
  final int minSelect;
  final int maxSelect;
  final List<MenuOption> options;
  const MenuOptionGroup({
    required this.id,
    required this.itemId,
    required this.name,
    this.isRequired = false,
    this.minSelect = 0,
    this.maxSelect = 1,
    this.options = const [],
  });
}

class AddonChoice {
  final String id;
  final String groupId;
  final String name;
  final Money price;
  const AddonChoice({
    required this.id,
    required this.groupId,
    required this.name,
    required this.price,
  });
}

class AddonGroup {
  final String id;
  final String itemId;
  final String name;
  final String selectionType;
  final int minSelect;
  final int maxSelect;
  final List<AddonChoice> choices;
  const AddonGroup({
    required this.id,
    required this.itemId,
    required this.name,
    this.selectionType = 'S',
    this.minSelect = 0,
    this.maxSelect = 1,
    this.choices = const [],
  });
}

class SelectedAddonChoice {
  final String choiceId;
  final String name;
  final Money price;
  const SelectedAddonChoice({
    required this.choiceId,
    required this.name,
    required this.price,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'choice_id': choiceId,
        'name': name,
        'price': price.toWire(),
      };
}

class SelectedAddonGroup {
  final String groupId;
  final String groupName;
  final List<SelectedAddonChoice> choices;
  const SelectedAddonGroup({
    required this.groupId,
    required this.groupName,
    required this.choices,
  });

  Money get extraPrice => choices.map((c) => c.price).sumMoney();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'group_id': groupId,
        'group_name': groupName,
        'choices': choices.map((c) => c.toJson()).toList(),
      };
}

class MenuItemVariation {
  final String id;
  final String name;
  final Money price;

  const MenuItemVariation({
    required this.id,
    required this.name,
    required this.price,
  });
}

class MenuItem {
  final String id;
  final String name;
  final String section;
  final String kitchenSection;
  final Money price;
  final bool isVeg;
  final bool available;
  final String? note;

  final String? measureUnit;
  final int sortOrder;
  final List<MenuOptionGroup> optionGroups;
  final List<MenuItemVariation> variations;
  final List<AddonGroup> addonGroups;
  const MenuItem({
    required this.id,
    required this.name,
    required this.section,
    required this.kitchenSection,
    required this.price,
    required this.isVeg,
    this.available = true,
    this.note,
    this.measureUnit,
    this.sortOrder = 0,
    this.optionGroups = const [],
    this.variations = const [],
    this.addonGroups = const [],
  });

  bool get isWeighed => measureUnit != null && measureUnit!.isNotEmpty;
}

class MenuCategory {
  final String name;
  final int sortOrder;
  const MenuCategory({required this.name, required this.sortOrder});
}

final menuCategoriesProvider = StateProvider<List<MenuCategory>>((_) => []);

final floorNamesProvider = StateProvider<List<String>>((_) => []);

class SelectedOption {
  final String groupName;
  final String optionName;
  final Money priceModifier;
  const SelectedOption({
    required this.groupName,
    required this.optionName,
    this.priceModifier = Money.zero,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'group_name': groupName,
        'option_name': optionName,
        'price_modifier': priceModifier.toWire(),
      };
}

class CartLine {
  static int _nextUid = 0;

  final int uid;
  final MenuItem item;
  final int qty;
  final List<String> mods;
  final List<SelectedOption> selectedOptions;
  final List<SelectedAddonGroup> selectedAddons;
  final Money modsExtra;
  final String itemNote;
  final String? variationId;
  final String? variationName;

  final double? weight;
  final SyncStatus syncStatus;

  CartLine({
    required this.item,
    required this.qty,
    this.mods = const [],
    this.selectedOptions = const [],
    this.selectedAddons = const [],
    this.modsExtra = Money.zero,
    this.itemNote = '',
    this.variationId,
    this.variationName,
    this.weight,
    this.syncStatus = SyncStatus.synced,
  }) : uid = _nextUid++;

  CartLine._clone({
    required this.uid,
    required this.item,
    required this.qty,
    required this.mods,
    required this.selectedOptions,
    required this.selectedAddons,
    required this.modsExtra,
    required this.itemNote,
    this.variationId,
    this.variationName,
    this.weight,
    this.syncStatus = SyncStatus.synced,
  });

  Money get addonsExtra => selectedAddons.map((g) => g.extraPrice).sumMoney();

  Money get unitPrice => item.price + modsExtra + addonsExtra;

  Money get lineTotal => item.isWeighed
      ? unitPrice.timesWeight(weight ?? 0)
      : unitPrice.times(qty);

  bool get isPlain =>
      variationId == null &&
      mods.isEmpty &&
      selectedOptions.isEmpty &&
      selectedAddons.isEmpty &&
      itemNote.trim().isEmpty &&
      !item.isWeighed;

  String get configKey {
    if (item.isWeighed) return 'uid:$uid';
    final optionIds = selectedOptions
        .map((o) => '${o.groupName}=${o.optionName}')
        .toList()
      ..sort();
    final addonIds = <String>[
      for (final group in selectedAddons)
        for (final choice in group.choices) choice.choiceId,
    ]..sort();
    final modList = <String>[...mods]..sort();
    return <String>[
      item.id,
      variationId ?? '-',
      modList.join(','),
      optionIds.join(','),
      addonIds.join(','),
      itemNote.trim(),
    ].join('|');
  }

  CartLine copyWith({
    int? qty,
    List<String>? mods,
    List<SelectedOption>? selectedOptions,
    List<SelectedAddonGroup>? selectedAddons,
    Money? modsExtra,
    String? itemNote,
    String? variationId,
    String? variationName,
    double? weight,
    SyncStatus? syncStatus,
  }) =>
      CartLine._clone(
        uid: uid,
        item: item,
        qty: qty ?? this.qty,
        mods: mods ?? this.mods,
        selectedOptions: selectedOptions ?? this.selectedOptions,
        selectedAddons: selectedAddons ?? this.selectedAddons,
        modsExtra: modsExtra ?? this.modsExtra,
        itemNote: itemNote ?? this.itemNote,
        variationId: variationId ?? this.variationId,
        variationName: variationName ?? this.variationName,
        weight: weight ?? this.weight,
        syncStatus: syncStatus ?? this.syncStatus,
      );
}

class Operator {
  final String name;
  final String role;
  final String shift;

  final String id;

  final String? employeeId;

  const Operator({
    required this.name,
    required this.role,
    required this.shift,
    required this.id,
    this.employeeId,
  });
}

class RestaurantInfo {
  final String name;
  final String address;
  final String adminDeviceLabel;
  final String adminIp;
  const RestaurantInfo({
    required this.name,
    required this.address,
    required this.adminDeviceLabel,
    required this.adminIp,
  });
}

class ConnectionStatus {
  final bool online;
  final String label;
  final int? secondsRemaining;
  const ConnectionStatus({
    required this.online,
    required this.label,
    this.secondsRemaining,
  });
}

class OperatorStats {
  final int ordersToday;
  final int tablesServed;
  final int itemsSold;
  const OperatorStats({
    required this.ordersToday,
    required this.tablesServed,
    required this.itemsSold,
  });
}

class HistoryOrder {
  static const _absent = Object();

  final String id;
  final String orderId;
  final String tableId;
  final String time;

  final String date;
  final int itemCount;
  final Money total;
  final OrderStatus status;
  final List<HistoryOrderLine> lines;
  final String? notes;
  final String? createdBy;
  final String? customerId;
  final String? customerName;
  const HistoryOrder({
    required this.id,
    required this.orderId,
    required this.tableId,
    required this.time,
    required this.date,
    required this.itemCount,
    required this.total,
    required this.status,
    required this.lines,
    this.notes,
    this.createdBy,
    this.customerId,
    this.customerName,
  });

  HistoryOrder copyWith({
    OrderStatus? status,
    Object? customerId = _absent,
    Object? customerName = _absent,
  }) =>
      HistoryOrder(
        id: id,
        orderId: orderId,
        tableId: tableId,
        time: time,
        date: date,
        itemCount: itemCount,
        total: total,
        status: status ?? this.status,
        lines: lines,
        notes: notes,
        createdBy: createdBy,
        customerId:
            customerId == _absent ? this.customerId : customerId as String?,
        customerName: customerName == _absent
            ? this.customerName
            : customerName as String?,
      );
}

class HistoryOrderLine {
  final String orderItemId;
  final String itemId;
  final String name;
  final int qty;
  final Money price;
  final List<String> mods;
  final String kitchenSection;
  final String? variationId;
  final String? variationName;

  final String? kotNumber;

  const HistoryOrderLine({
    required this.orderItemId,
    required this.itemId,
    required this.name,
    required this.qty,
    required this.price,
    this.mods = const [],
    required this.kitchenSection,
    this.variationId,
    this.variationName,
    this.kotNumber,
  });
}

class ActiveOperator {
  final String name;
  final String role;
  const ActiveOperator({required this.name, required this.role});
}

final tablesProvider = StateProvider<List<RestaurantTable>>((_) => []);
final roomsProvider = StateProvider<List<RestaurantRoom>>((_) => []);

final isFloorDataStaleProvider = StateProvider<bool>((_) => false);
final offersProvider = StateProvider<List<Offer>>((_) => []);
final menuProvider = StateProvider<List<MenuItem>>((_) => []);
final menuLoadingProvider = StateProvider<bool>((_) => false);

final fastAddPinnedProvider = StateProvider<List<MenuItem>>((_) => []);
final fastAddAutoProvider = StateProvider<List<MenuItem>>((_) => []);

final selectedTableIdProvider = StateProvider<String?>((_) => null);

final orderNotesProvider = StateProvider<String>((_) => '');

final recentItemsProvider =
    StateNotifierProvider<RecentItemsNotifier, List<MenuItem>>(
  (_) => RecentItemsNotifier(),
);

class RecentItemsNotifier extends StateNotifier<List<MenuItem>> {
  static const _maxRecent = 8;
  RecentItemsNotifier() : super(const []);

  void track(MenuItem item) {
    final updated = [item, ...state.where((m) => m.id != item.id)];
    state =
        updated.length > _maxRecent ? updated.sublist(0, _maxRecent) : updated;
  }
}

final cartProvider = StateNotifierProvider<CartNotifier, List<CartLine>>(
  (_) => CartNotifier(),
);

class CartNotifier extends StateNotifier<List<CartLine>> {
  CartNotifier() : super(const <CartLine>[]);

  void addSimple(MenuItem item) {
    assert(
      !item.isWeighed,
      'Weighed items must go through addCustom() with a weight — '
      'route them via ItemDetailSheet.',
    );
    if (item.isWeighed) return;
    _upsert(CartLine(item: item, qty: 1));
  }

  void addCustom({
    required MenuItem item,
    required int qty,
    required List<String> mods,
    required Money modsExtra,
    required String itemNote,
    List<SelectedOption> selectedOptions = const <SelectedOption>[],
    List<SelectedAddonGroup> selectedAddons = const <SelectedAddonGroup>[],
    String? variationId,
    String? variationName,
    double? weight,
  }) {
    if (qty <= 0) return;
    if (item.isWeighed && (weight == null || weight <= 0)) return;
    _upsert(CartLine(
      item: item,
      qty: qty,
      mods: mods,
      selectedOptions: selectedOptions,
      selectedAddons: selectedAddons,
      modsExtra: modsExtra,
      itemNote: itemNote,
      variationId: variationId,
      variationName: variationName,
      weight: weight,
    ));
  }

  void _upsert(CartLine line) {
    final key = line.configKey;
    final index = state.indexWhere((l) => l.configKey == key);
    if (index < 0) {
      state = <CartLine>[...state, line];
      return;
    }
    final next = <CartLine>[...state];
    next[index] = next[index].copyWith(qty: next[index].qty + line.qty);
    state = next;
  }

  int _indexOfUid(int uid) => state.indexWhere((l) => l.uid == uid);

  void removeByUid(int uid) {
    final index = _indexOfUid(uid);
    if (index < 0) return;
    removeAt(index);
  }

  void setQtyByUid(int uid, int qty) {
    final index = _indexOfUid(uid);
    if (index < 0) return;
    setQtyAt(index, qty);
  }

  void incrementByUid(int uid) {
    final index = _indexOfUid(uid);
    if (index < 0) return;
    setQtyAt(index, state[index].qty + 1);
  }

  void decrementByUid(int uid) {
    final index = _indexOfUid(uid);
    if (index < 0) return;
    setQtyAt(index, state[index].qty - 1);
  }

  void decrementPlainLine(String itemId) {
    final index = state.lastIndexWhere((l) => l.isPlain && l.item.id == itemId);
    if (index < 0) return;
    setQtyAt(index, state[index].qty - 1);
  }

  void removeAt(int index) {
    if (index < 0 || index >= state.length) return;
    final next = <CartLine>[...state]..removeAt(index);
    state = next;
  }

  void setQtyAt(int index, int qty) {
    if (index < 0 || index >= state.length) return;
    if (qty <= 0) return removeAt(index);
    final next = <CartLine>[...state];
    next[index] = next[index].copyWith(qty: qty);
    state = next;
  }

  void setNoteAt(int index, String note) {
    if (index < 0 || index >= state.length) return;
    final next = <CartLine>[...state];
    next[index] = next[index].copyWith(itemNote: note);
    state = next;
  }

  void clear() => state = const <CartLine>[];

  void setSyncStatusAll(SyncStatus status) {
    state = <CartLine>[for (final l in state) l.copyWith(syncStatus: status)];
  }

  void setSyncStatusFailed() {
    state = <CartLine>[
      for (final l in state)
        if (l.syncStatus == SyncStatus.pending)
          l.copyWith(syncStatus: SyncStatus.failed)
        else
          l,
    ];
  }

  void retryFailed() {
    state = <CartLine>[
      for (final l in state)
        if (l.syncStatus == SyncStatus.failed)
          l.copyWith(syncStatus: SyncStatus.pending)
        else
          l,
    ];
  }

  Money get total => state.map((l) => l.lineTotal).sumMoney();

  Map<String, int> get plainQtyByItemId {
    final counts = <String, int>{};
    for (final line in state) {
      if (!line.isPlain) continue;
      counts[line.item.id] = (counts[line.item.id] ?? 0) + line.qty;
    }
    return counts;
  }

  Map<String, List<CartLine>> get byKitchen {
    final map = <String, List<CartLine>>{};
    for (final line in state) {
      map.putIfAbsent(line.item.kitchenSection, () => <CartLine>[]).add(line);
    }
    return map;
  }
}

final plainCartQtyProvider = Provider.family<int, String>((ref, itemId) {
  return ref.watch(cartProvider.select((lines) {
    var total = 0;
    for (final line in lines) {
      if (line.isPlain && line.item.id == itemId) total += line.qty;
    }
    return total;
  }));
});

final customerNameByOrderIdProvider = Provider<Map<String, String>>((ref) {
  final history = ref.watch(historyProvider);
  final names = <String, String>{};
  for (final order in history) {
    final name = order.customerName;
    if (name != null && name.isNotEmpty) names[order.orderId] = name;
  }
  return names;
});

final readyTableIdsProvider = Provider<Set<String>>((ref) {
  final ready = ref.watch(readyOrdersProvider);
  return {
    for (final t in ready)
      if (t.tableId != null) t.tableId!,
  };
});

final linkedTableIdsProvider = Provider<Set<String>>((ref) {
  final groups = ref.watch(linkGroupsProvider);
  return {for (final ids in groups.values) ...ids};
});

final operatorProvider = StateProvider<Operator?>((_) => null);

final businessDateProvider = Provider<String?>((ref) {
  final history = ref.watch(historyProvider);
  for (final order in history) {
    if (order.date.isNotEmpty) return order.date;
  }
  return null;
});

final operatorStatsProvider = Provider<OperatorStats>((ref) {
  final operatorId = ref.watch(operatorProvider)?.id;
  final businessDate = ref.watch(businessDateProvider);

  if (operatorId == null || operatorId.isEmpty || businessDate == null) {
    return const OperatorStats(ordersToday: 0, tablesServed: 0, itemsSold: 0);
  }

  final mine = ref
      .watch(historyProvider)
      .where((h) => h.date == businessDate)
      .where((h) => h.createdBy == operatorId)
      .where((h) => h.status != OrderStatus.cancelled)
      .toList();

  final tablesServed = mine
      .where((h) => h.status == OrderStatus.paid)
      .map((h) => h.tableId)
      .toSet()
      .length;

  return OperatorStats(
    ordersToday: mine.length,
    tablesServed: tablesServed,
    itemsSold: mine.fold<int>(0, (sum, h) => sum + h.itemCount),
  );
});

final restaurantProvider = StateProvider<RestaurantInfo?>((_) => null);

final connectionProvider = StateProvider<ConnectionStatus>(
  (_) => const ConnectionStatus(online: false, label: 'Not connected'),
);

final activeOperatorsProvider = StateProvider<List<ActiveOperator>>((_) => []);

final historyProvider = StateProvider<List<HistoryOrder>>((_) => []);

final discountsProvider = StateProvider<List<Map<String, dynamic>>>((_) => []);

final flagsProvider = StateProvider<FeatureFlags>((_) => const FeatureFlags());
final rawMenuDataProvider = StateProvider<Map<String, dynamic>>((_) => {});

final activeOrdersProvider = StateProvider<List<ServerOrder>>((_) => []);
final socketServiceProvider = Provider<SocketService>((ref) {
  final service = SocketService();
  ref.onDispose(service.dispose);
  return service;
});
final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(ref.read(socketServiceProvider), ref);
  ref.onDispose(service.dispose);
  return service;
});
final customerLinkServiceProvider = Provider<CustomerLinkService>(
  (ref) => CustomerLinkService(
      ref.read(socketServiceProvider), ref.read(syncServiceProvider)),
);

final connectionBootstrapProvider =
    StateNotifierProvider<ConnectionBootstrap, BootstrapOutcome>(
        (ref) => ConnectionBootstrap(ref));

final tablePresencesProvider = StateProvider<Map<String, String>>((_) => {});

final hapticEnabledProvider = StateProvider<bool>((_) => true);

final isAuthenticatedProvider = StateProvider<bool>((_) => false);

final hasSavedPairingProvider = StateProvider<bool>((_) => false);
final pinVerifiedAtProvider = StateProvider<DateTime?>((_) => null);
final forceDisconnectedProvider = StateProvider<bool>((_) => false);

final lastKotIdProvider = StateProvider<String?>((_) => null);

final linkGroupsProvider = StateProvider<Map<String, List<String>>>((_) => {});

class ReadyTicket {
  final String orderId;
  final String? tableId;
  final String tableName;
  final String kotNumber;
  final List<String> itemLabels;

  const ReadyTicket({
    required this.orderId,
    required this.tableId,
    required this.tableName,
    required this.kotNumber,
    required this.itemLabels,
  });
}

final readyOrdersProvider = StateProvider<List<ReadyTicket>>((_) => []);
