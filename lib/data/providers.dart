

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/feature_flags.dart';
import '../services/socket_service.dart';
import '../services/sync_service.dart';

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
  /// Must stay index-parallel with [joinedOperatorNames]; populate both
  /// together from the same source list (e.g. ServerTable.operatorIds).
  final List<String> joinedOperatorIds;
  /// Must stay index-parallel with [joinedOperatorIds]; populate both
  /// together from the same source list (e.g. ServerTable.operatorNames).
  final List<String> joinedOperatorNames;
  final int? coverCount;
  final double? bill;
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
        bill: bill == _absent ? this.bill : bill as double?,
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
  final double? bill;
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
        guestName:
            guestName == _absent ? this.guestName : guestName as String?,
        activeOrderId: activeOrderId == _absent
            ? this.activeOrderId
            : activeOrderId as String?,
        activeBillCount: activeBillCount ?? this.activeBillCount,
        orderItemCount: orderItemCount ?? this.orderItemCount,
        bill: bill == _absent ? this.bill : bill as double?,
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
  final double priceModifier;
  const MenuOption({
    required this.id,
    required this.groupId,
    required this.name,
    this.priceModifier = 0,
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
  final double price;
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
  final double price;
  const SelectedAddonChoice({
    required this.choiceId,
    required this.name,
    required this.price,
  });

  Map<String, dynamic> toJson() => {
        'choice_id': choiceId,
        'name': name,
        'price': price,
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

  double get extraPrice => choices.fold(0.0, (s, c) => s + c.price);

  Map<String, dynamic> toJson() => {
        'group_id': groupId,
        'group_name': groupName,
        'choices': choices.map((c) => c.toJson()).toList(),
      };
}

class MenuItemVariation {
  final String id;
  final String name;
  final double price;

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
  final String
      kitchenSection;
  final double price;
  final bool isVeg;
  final bool available;
  final String? note;

  final String? measureUnit;
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
    this.optionGroups = const [],
    this.variations = const [],
    this.addonGroups = const [],
  });

  bool get isWeighed => measureUnit != null && measureUnit!.isNotEmpty;
}

class Modifier {
  final String id;
  final String groupId;
  final String label;
  final double extraPrice;
  const Modifier(
      {required this.id,
      this.groupId = '',
      required this.label,
      this.extraPrice = 0});
}

class SelectedOption {
  final String groupName;
  final String optionName;
  final double priceModifier;
  const SelectedOption({
    required this.groupName,
    required this.optionName,
    this.priceModifier = 0,
  });

  Map<String, dynamic> toJson() => {
        'group_name': groupName,
        'option_name': optionName,
        'price_modifier': priceModifier,
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
  final double modsExtra;
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
    this.modsExtra = 0,
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

  double get addonsExtra =>
      selectedAddons.fold(0.0, (s, g) => s + g.extraPrice);

  double get lineTotal => item.isWeighed
      ? (item.price + modsExtra + addonsExtra) * (weight ?? 0)
      : (item.price + modsExtra + addonsExtra) * qty;

  CartLine copyWith({
    int? qty,
    List<String>? mods,
    List<SelectedOption>? selectedOptions,
    List<SelectedAddonGroup>? selectedAddons,
    double? modsExtra,
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
  final String username;
  const Operator({
    required this.name,
    required this.role,
    required this.shift,
    required this.username,
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
  final int?
      secondsRemaining;
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
  final String id;
  final String orderId;
  final String tableId;
  final String time;
  final String date;
  final int itemCount;
  final double total;
  final OrderStatus status;
  final List<HistoryOrderLine> lines;
  final String? notes;
  final String? createdBy;
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
  });
}

class HistoryOrderLine {
  final String orderItemId;
  final String itemId;
  final String name;
  final int qty;
  final double price;
  final List<String> mods;
  final String kitchenSection;
  final String? variationId;
  final String? variationName;
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
  });
}

class ActiveOperator {
  final String name;
  final String role;
  const ActiveOperator({required this.name, required this.role});
}

const spiceLevels = <Modifier>[
  Modifier(id: 'sp_mild', label: 'Mild'),
  Modifier(id: 'sp_med', label: 'Medium'),
  Modifier(id: 'sp_spicy', label: 'Spicy'),
  Modifier(id: 'sp_extra', label: 'Extra Spicy'),
];

const addOns = <Modifier>[
  Modifier(id: 'ad_cheese', label: 'Extra Cheese', extraPrice: 60),
  Modifier(id: 'ad_butter', label: 'Extra Butter', extraPrice: 30),
  Modifier(id: 'ad_onion', label: 'No Onion'),
  Modifier(id: 'ad_garlic', label: 'No Garlic'),
  Modifier(id: 'ad_jain', label: 'Jain (no onion/garlic)'),
  Modifier(id: 'ad_half', label: 'Half Portion', extraPrice: -50),
];

final tablesProvider = StateProvider<List<RestaurantTable>>((_) => []);
final roomsProvider = StateProvider<List<RestaurantRoom>>((_) => []);
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
  CartNotifier() : super(const []);

  void add(MenuItem item) {

    final i = state.indexWhere((l) =>
        l.item.id == item.id &&
        l.variationId == null &&
        l.mods.isEmpty &&
        l.itemNote.isEmpty);
    if (i >= 0) {
      final next = [...state];
      next[i] = next[i].copyWith(qty: next[i].qty + 1);
      state = next;
    } else {
      state = [...state, CartLine(item: item, qty: 1)];
    }
  }

  void addCustom({
    required MenuItem item,
    required int qty,
    required List<String> mods,
    List<SelectedOption> selectedOptions = const [],
    List<SelectedAddonGroup> selectedAddons = const [],
    required double modsExtra,
    required String itemNote,
    String? variationId,
    String? variationName,
    double? weight,
  }) {
    state = [
      ...state,
      CartLine(
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
      ),
    ];
  }

  void remove(String itemId) {
    final i = state.indexWhere((l) => l.item.id == itemId);
    if (i >= 0) removeAt(i);
  }

  void removeAt(int index) {
    if (index < 0 || index >= state.length) return;
    final next = [...state];
    next.removeAt(index);
    state = next;
  }

  void setQty(String itemId, int qty) {
    if (qty <= 0) return remove(itemId);
    state = [
      for (final l in state)
        if (l.item.id == itemId) l.copyWith(qty: qty) else l,
    ];
  }

  void setQtyAt(int index, int qty) {
    if (index < 0 || index >= state.length) return;
    if (qty <= 0) return removeAt(index);
    final next = [...state];
    next[index] = next[index].copyWith(qty: qty);
    state = next;
  }

  void clear() => state = const [];

  void setSyncStatusAll(SyncStatus status) {
    state = [for (final l in state) l.copyWith(syncStatus: status)];
  }

  void setSyncStatusFailed() {
    state = [
      for (final l in state)
        if (l.syncStatus == SyncStatus.pending)
          l.copyWith(syncStatus: SyncStatus.failed)
        else
          l,
    ];
  }

  void retryFailed() {
    state = [
      for (final l in state)
        if (l.syncStatus == SyncStatus.failed)
          l.copyWith(syncStatus: SyncStatus.pending)
        else
          l,
    ];
  }

  void setNoteAt(int index, String note) {
    if (index < 0 || index >= state.length) return;
    final next = [...state];
    next[index] = next[index].copyWith(itemNote: note);
    state = next;
  }

  double get total => state.fold(0.0, (s, l) => s + l.lineTotal);

  Map<String, List<CartLine>> get byKitchen {
    final map = <String, List<CartLine>>{};
    for (final l in state) {
      map.putIfAbsent(l.item.kitchenSection, () => []).add(l);
    }
    return map;
  }
}

final operatorProvider = StateProvider<Operator?>((_) => null);

final isWaiterProvider = Provider<bool>((ref) {
  final role = ref.watch(operatorProvider)?.role.toLowerCase().trim() ?? '';
  return role == 'waiter';
});

final operatorStatsProvider = Provider<OperatorStats>((ref) {
  final myId = ref.watch(operatorProvider)?.username ?? '';
  final now = DateTime.now();
  final today =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final mine = ref
      .watch(historyProvider)
      .where((h) => h.date == today)
      .where((h) => h.createdBy == null || h.createdBy == myId)
      .where((h) => h.status != OrderStatus.cancelled)
      .toList();

  final tablesServed =
      mine.where((h) => h.status == OrderStatus.paid).map((h) => h.tableId).toSet().length;

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
final activeOrdersProvider =
    StateProvider<List<Map<String, dynamic>>>((_) => []);
final socketServiceProvider = Provider<SocketService>((_) => SocketService());
final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(ref.read(socketServiceProvider), ref),
);

final tablePresencesProvider = StateProvider<Map<String, String>>((_) => {});

final hapticEnabledProvider = StateProvider<bool>((_) => true);

final isAuthenticatedProvider = StateProvider<bool>((_) => false);
final pinVerifiedAtProvider = StateProvider<DateTime?>((_) => null);
final forceDisconnectedProvider = StateProvider<bool>((_) => false);

int _kotCounter = 0;
String generateKotId() => 'K-${++_kotCounter}';

final lastKotIdProvider = StateProvider<String>((_) => '');

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
