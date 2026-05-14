// Riverpod providers for DineDesk Cap (waiter) app.
//
// Indian restaurant POS context — ₹ currency, Indian dishes, kitchen-section
// based KOT routing, veg/non-veg flags. Data is populated via Socket.IO sync
// from the Desktop Electron POS (see sync_service.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/feature_flags.dart';
import '../services/socket_service.dart';
import '../services/sync_service.dart';

// ─────────────── Models ───────────────

enum TableState { mine, other, dirty, reserved, free }

enum OrderStatus { sent, modified, cancelled, paid }

class RestaurantTable {
  static const _absent = Object();

  final String id;        // Display name — "T-04", "F1", etc.
  final String serverId;  // Server UUID — used in all socket emits
  final int seats;
  final String floor;
  final TableState state;
  final String? waiterName;
  final int? coverCount;
  final double? bill;
  final String? note;
  const RestaurantTable({
    required this.id,
    required this.serverId,
    required this.seats,
    required this.floor,
    required this.state,
    this.waiterName,
    this.coverCount,
    this.bill,
    this.note,
  });

  RestaurantTable copyWith({
    String? id,
    String? serverId,
    int? seats,
    String? floor,
    TableState? state,
    Object? waiterName = _absent,
    Object? coverCount = _absent,
    Object? bill = _absent,
    Object? note = _absent,
  }) =>
      RestaurantTable(
        id: id ?? this.id,
        serverId: serverId ?? this.serverId,
        seats: seats ?? this.seats,
        floor: floor ?? this.floor,
        state: state ?? this.state,
        waiterName: waiterName == _absent ? this.waiterName : waiterName as String?,
        coverCount: coverCount == _absent ? this.coverCount : coverCount as int?,
        bill: bill == _absent ? this.bill : bill as double?,
        note: note == _absent ? this.note : note as String?,
      );
}

class MenuItem {
  final String id;
  final String name;
  final String section;          // menu category — "Tandoor", "Chinese", etc.
  final String kitchenSection;   // routing — "tandoor", "curry", "south", "chinese", "beverages"
  final double price;            // in ₹
  final bool isVeg;
  final bool available;
  final String? note;
  const MenuItem({
    required this.id,
    required this.name,
    required this.section,
    required this.kitchenSection,
    required this.price,
    required this.isVeg,
    this.available = true,
    this.note,
  });
}

class Modifier {
  final String id;               // option_id from server
  final String groupId;          // option_group_id from server
  final String label;
  final double extraPrice;       // in ₹, can be 0
  const Modifier({required this.id, this.groupId = '', required this.label, this.extraPrice = 0});
}

/// Structured option selection matching Desktop's `SelectedOptionPayload`.
class SelectedOption {
  final String groupName;        // option group display name
  final String optionName;       // option display name
  final double priceModifier;    // price delta (can be negative)
  const SelectedOption({
    required this.groupName,
    required this.optionName,
    this.priceModifier = 0,
  });

  /// Serialize to match Desktop's `SelectedOptionPayload` exactly.
  Map<String, dynamic> toJson() => {
    'group_name': groupName,
    'option_name': optionName,
    'price_modifier': priceModifier,
  };
}

class CartLine {
  static int _nextUid = 0;

  final int uid;                 // stable identity for Dismissible keys
  final MenuItem item;
  final int qty;
  final List<String> mods;               // display labels for UI
  final List<SelectedOption> selectedOptions;  // structured for server payload
  final double modsExtra;        // total extra cost from selected mods
  final String itemNote;

  CartLine({
    required this.item,
    required this.qty,
    this.mods = const [],
    this.selectedOptions = const [],
    this.modsExtra = 0,
    this.itemNote = '',
  }) : uid = _nextUid++;

  CartLine._clone({
    required this.uid,
    required this.item,
    required this.qty,
    required this.mods,
    required this.selectedOptions,
    required this.modsExtra,
    required this.itemNote,
  });

  double get lineTotal => (item.price + modsExtra) * qty;

  CartLine copyWith({
    int? qty,
    List<String>? mods,
    List<SelectedOption>? selectedOptions,
    double? modsExtra,
    String? itemNote,
  }) =>
      CartLine._clone(
        uid: uid,
        item: item,
        qty: qty ?? this.qty,
        mods: mods ?? this.mods,
        selectedOptions: selectedOptions ?? this.selectedOptions,
        modsExtra: modsExtra ?? this.modsExtra,
        itemNote: itemNote ?? this.itemNote,
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
  final int? secondsRemaining;   // null when online; counts down 120s when reconnecting
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
  final String id;             // Display ID — KOT number e.g. "K-4127"
  final String orderId;        // Server UUID — used in all socket emits
  final String tableId;
  final String time;           // HH:MM
  final int itemCount;
  final double total;          // in ₹
  final OrderStatus status;
  final List<HistoryOrderLine> lines;
  final String? notes;
  const HistoryOrder({
    required this.id,
    required this.orderId,
    required this.tableId,
    required this.time,
    required this.itemCount,
    required this.total,
    required this.status,
    required this.lines,
    this.notes,
  });
}

class HistoryOrderLine {
  final String name;
  final int qty;
  final double price;
  final List<String> mods;
  final String kitchenSection;
  const HistoryOrderLine({
    required this.name,
    required this.qty,
    required this.price,
    this.mods = const [],
    required this.kitchenSection,
  });
}

class ActiveOperator {
  final String name;
  final String role;
  const ActiveOperator({required this.name, required this.role});
}

// ─────────────── Modifier defaults ───────────────
// These are fallback defaults used when the server menu sync hasn't provided
// option groups yet. In production, modifiers come from the server's
// `item_option_groups` / `item_options` per menu item.

const spiceLevels = <Modifier>[
  Modifier(id: 'sp_mild',   label: 'Mild'),
  Modifier(id: 'sp_med',    label: 'Medium'),
  Modifier(id: 'sp_spicy',  label: 'Spicy'),
  Modifier(id: 'sp_extra',  label: 'Extra Spicy'),
];

const addOns = <Modifier>[
  Modifier(id: 'ad_cheese',  label: 'Extra Cheese',          extraPrice: 60),
  Modifier(id: 'ad_butter',  label: 'Extra Butter',          extraPrice: 30),
  Modifier(id: 'ad_onion',   label: 'No Onion'),
  Modifier(id: 'ad_garlic',  label: 'No Garlic'),
  Modifier(id: 'ad_jain',    label: 'Jain (no onion/garlic)'),
  Modifier(id: 'ad_half',    label: 'Half Portion',          extraPrice: -50),
];

// ─────────────── Providers ───────────────

final tablesProvider = StateProvider<List<RestaurantTable>>((_) => []);
final menuProvider   = StateProvider<List<MenuItem>>((_) => []);

final selectedTableIdProvider = StateProvider<String?>((_) => null);

// Order-level note typed in review screen.
final orderNotesProvider = StateProvider<String>((_) => '');

final cartProvider = StateNotifierProvider<CartNotifier, List<CartLine>>(
  (_) => CartNotifier(),
);

class CartNotifier extends StateNotifier<List<CartLine>> {
  CartNotifier() : super(const []);

  void add(MenuItem item) {
    final i = state.indexWhere((l) =>
      l.item.id == item.id && l.mods.isEmpty && l.itemNote.isEmpty);
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
    required double modsExtra,
    required String itemNote,
  }) {
    state = [
      ...state,
      CartLine(
        item: item,
        qty: qty,
        mods: mods,
        selectedOptions: selectedOptions,
        modsExtra: modsExtra,
        itemNote: itemNote,
      ),
    ];
  }

  /// Removes the first cart line matching [itemId] (not all of them).
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

  double get total => state.fold(0.0, (s, l) => s + l.lineTotal);

  // Group lines by kitchen section for the KOT preview.
  Map<String, List<CartLine>> get byKitchen {
    final map = <String, List<CartLine>>{};
    for (final l in state) {
      map.putIfAbsent(l.item.kitchenSection, () => []).add(l);
    }
    return map;
  }
}

final operatorProvider = StateProvider<Operator?>((_) => null);

final operatorStatsProvider = StateProvider<OperatorStats>(
  (_) => const OperatorStats(ordersToday: 0, tablesServed: 0, itemsSold: 0),
);

final restaurantProvider = StateProvider<RestaurantInfo?>((_) => null);

final connectionProvider = StateProvider<ConnectionStatus>(
  (_) => const ConnectionStatus(online: false, label: 'Not connected'),
);

// Active operators (besides "you") for presence indicators.
final activeOperatorsProvider = StateProvider<List<ActiveOperator>>((_) => []);

final historyProvider = StateProvider<List<HistoryOrder>>((_) => []);

// Discount presets synced from admin server.
final discountsProvider = StateProvider<List<Map<String, dynamic>>>((_) => []);

// ─────────────── New real-time providers ───────────────

final flagsProvider = StateProvider<FeatureFlags>((_) => const FeatureFlags());
final rawMenuDataProvider = StateProvider<Map<String, dynamic>>((_) => {});
final activeOrdersProvider = StateProvider<List<Map<String, dynamic>>>((_) => []);
final socketServiceProvider = Provider<SocketService>((_) => SocketService());
final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(ref.read(socketServiceProvider), ref),
);

// ─────────────── Auth ───────────────

final isAuthenticatedProvider = StateProvider<bool>((_) => false);

// ─────────────── KOT numbering ───────────────

int _kotCounter = 0;
String generateKotId() => 'K-${++_kotCounter}';

final lastKotIdProvider = StateProvider<String>((_) => '');
