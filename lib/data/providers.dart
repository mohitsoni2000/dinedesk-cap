// Mock data + Riverpod providers.
//
// Indian restaurant POS context — ₹ currency, Indian dishes, kitchen-section
// based KOT routing, veg/non-veg flags. Replace fixtures with real WS-backed
// repositories when wiring the live admin connection.

import 'package:flutter_riverpod/flutter_riverpod.dart';

// ─────────────── Models ───────────────

enum TableState { mine, other, dirty, reserved, free }

enum OrderStatus { sent, modified, cancelled }

class RestaurantTable {
  static const _absent = Object();

  final String id;        // e.g. "T-04"
  final int seats;        // 2/4/6/8
  final String floor;     // "GROUND", "FIRST", "GARDEN", "TAKEAWAY"
  final TableState state;
  final String? waiterName;
  final int? coverCount;
  final double? bill;
  final String? note;
  const RestaurantTable({
    required this.id,
    required this.seats,
    required this.floor,
    required this.state,
    this.waiterName,
    this.coverCount,
    this.bill,
    this.note,
  });

  /// Sentinel-based [copyWith] — pass explicit `null` to clear nullable fields.
  RestaurantTable copyWith({
    String? id,
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
  final String id;
  final String label;
  final double extraPrice;       // in ₹, can be 0
  const Modifier({required this.id, required this.label, this.extraPrice = 0});
}

class CartLine {
  static int _nextUid = 0;

  final int uid;                 // stable identity for Dismissible keys
  final MenuItem item;
  final int qty;
  final List<String> mods;
  final double modsExtra;        // total extra cost from selected mods
  final String itemNote;

  CartLine({
    required this.item,
    required this.qty,
    this.mods = const [],
    this.modsExtra = 0,
    this.itemNote = '',
  }) : uid = _nextUid++;

  CartLine._clone({
    required this.uid,
    required this.item,
    required this.qty,
    required this.mods,
    required this.modsExtra,
    required this.itemNote,
  });

  double get lineTotal => (item.price + modsExtra) * qty;

  CartLine copyWith({
    int? qty,
    List<String>? mods,
    double? modsExtra,
    String? itemNote,
  }) =>
      CartLine._clone(
        uid: uid,
        item: item,
        qty: qty ?? this.qty,
        mods: mods ?? this.mods,
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
  final String id;             // KOT number, e.g. "K-4127"
  final String tableId;
  final String time;           // HH:MM
  final int itemCount;
  final double total;          // in ₹
  final OrderStatus status;
  final List<HistoryOrderLine> lines;
  final String? notes;
  const HistoryOrder({
    required this.id,
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

// ─────────────── Mock fixtures ───────────────

const _tablesFixture = <RestaurantTable>[
  RestaurantTable(id: 'T-01', seats: 2, floor: 'GROUND',   state: TableState.mine,     waiterName: 'You',     coverCount: 2, bill: 480.00),
  RestaurantTable(id: 'T-02', seats: 4, floor: 'GROUND',   state: TableState.mine,     waiterName: 'You',     coverCount: 4, bill: 1420.00),
  RestaurantTable(id: 'T-03', seats: 4, floor: 'GROUND',   state: TableState.other,    waiterName: 'Priya'),
  RestaurantTable(id: 'T-04', seats: 6, floor: 'GROUND',   state: TableState.dirty),
  RestaurantTable(id: 'T-05', seats: 2, floor: 'FIRST',    state: TableState.free),
  RestaurantTable(id: 'T-06', seats: 4, floor: 'FIRST',    state: TableState.reserved, note: '8:30 Sharma'),
  RestaurantTable(id: 'T-07', seats: 8, floor: 'FIRST',    state: TableState.mine,     waiterName: 'You',     coverCount: 7, bill: 3180.00),
  RestaurantTable(id: 'T-08', seats: 4, floor: 'GARDEN',   state: TableState.free),
  RestaurantTable(id: 'T-09', seats: 2, floor: 'GARDEN',   state: TableState.other,    waiterName: 'Karan'),
  RestaurantTable(id: 'T-10', seats: 4, floor: 'GARDEN',   state: TableState.dirty),
  RestaurantTable(id: 'T-11', seats: 6, floor: 'TAKEAWAY', state: TableState.free),
  RestaurantTable(id: 'T-12', seats: 4, floor: 'TAKEAWAY', state: TableState.reserved, note: '9:00 Khan'),
];

const _menuFixture = <MenuItem>[
  // Tandoor
  MenuItem(id: 'm01', name: 'Paneer Tikka',           section: 'Tandoor',   kitchenSection: 'tandoor',   price: 320, isVeg: true),
  MenuItem(id: 'm02', name: 'Chicken Tikka',          section: 'Tandoor',   kitchenSection: 'tandoor',   price: 380, isVeg: false),
  MenuItem(id: 'm03', name: 'Tandoori Chicken (H)',   section: 'Tandoor',   kitchenSection: 'tandoor',   price: 420, isVeg: false),
  MenuItem(id: 'm04', name: 'Seekh Kebab',            section: 'Tandoor',   kitchenSection: 'tandoor',   price: 360, isVeg: false),
  // Main course
  MenuItem(id: 'm05', name: 'Butter Chicken',         section: 'Main',      kitchenSection: 'curry',     price: 440, isVeg: false),
  MenuItem(id: 'm06', name: 'Paneer Butter Masala',   section: 'Main',      kitchenSection: 'curry',     price: 360, isVeg: true),
  MenuItem(id: 'm07', name: 'Dal Makhani',            section: 'Main',      kitchenSection: 'curry',     price: 280, isVeg: true),
  MenuItem(id: 'm08', name: 'Kadhai Paneer',          section: 'Main',      kitchenSection: 'curry',     price: 340, isVeg: true),
  MenuItem(id: 'm09', name: 'Hyderabadi Biryani',     section: 'Biryani',   kitchenSection: 'curry',     price: 380, isVeg: false),
  MenuItem(id: 'm10', name: 'Veg Biryani',            section: 'Biryani',   kitchenSection: 'curry',     price: 280, isVeg: true, available: false),
  // Breads
  MenuItem(id: 'm11', name: 'Garlic Naan',            section: 'Breads',    kitchenSection: 'tandoor',   price: 80,  isVeg: true),
  MenuItem(id: 'm12', name: 'Butter Naan',            section: 'Breads',    kitchenSection: 'tandoor',   price: 70,  isVeg: true),
  MenuItem(id: 'm13', name: 'Tandoori Roti',          section: 'Breads',    kitchenSection: 'tandoor',   price: 40,  isVeg: true),
  // South
  MenuItem(id: 'm14', name: 'Masala Dosa',            section: 'South',     kitchenSection: 'south',     price: 220, isVeg: true),
  MenuItem(id: 'm15', name: 'Idli Sambar',            section: 'South',     kitchenSection: 'south',     price: 160, isVeg: true),
  // Chinese
  MenuItem(id: 'm16', name: 'Veg Hakka Noodles',      section: 'Chinese',   kitchenSection: 'chinese',   price: 240, isVeg: true),
  MenuItem(id: 'm17', name: 'Chilli Chicken',         section: 'Chinese',   kitchenSection: 'chinese',   price: 320, isVeg: false),
  MenuItem(id: 'm18', name: 'Schezwan Fried Rice',    section: 'Chinese',   kitchenSection: 'chinese',   price: 260, isVeg: true),
  // Beverages
  MenuItem(id: 'm19', name: 'Masala Chai',            section: 'Beverages', kitchenSection: 'beverages', price: 60,  isVeg: true),
  MenuItem(id: 'm20', name: 'Sweet Lassi',            section: 'Beverages', kitchenSection: 'beverages', price: 120, isVeg: true),
  MenuItem(id: 'm21', name: 'Fresh Lime Soda',        section: 'Beverages', kitchenSection: 'beverages', price: 90,  isVeg: true),
  MenuItem(id: 'm22', name: 'Cold Coffee',            section: 'Beverages', kitchenSection: 'beverages', price: 140, isVeg: true),
  // Desserts
  MenuItem(id: 'm23', name: 'Gulab Jamun (2 pc)',     section: 'Desserts',  kitchenSection: 'beverages', price: 100, isVeg: true),
  MenuItem(id: 'm24', name: 'Rasmalai',               section: 'Desserts',  kitchenSection: 'beverages', price: 130, isVeg: true),
];

// Modifiers — grouped: spice level (single-select) + add-ons (multi-select with prices)
const spiceLevels = <Modifier>[
  Modifier(id: 'sp_mild',   label: 'Mild'),
  Modifier(id: 'sp_med',    label: 'Medium'),
  Modifier(id: 'sp_spicy',  label: 'Spicy'),
  Modifier(id: 'sp_extra',  label: 'Extra Spicy'),
];

const addOns = <Modifier>[
  Modifier(id: 'ad_cheese',  label: 'Extra Cheese',     extraPrice: 60),
  Modifier(id: 'ad_butter',  label: 'Extra Butter',     extraPrice: 30),
  Modifier(id: 'ad_onion',   label: 'No Onion'),
  Modifier(id: 'ad_garlic',  label: 'No Garlic'),
  Modifier(id: 'ad_jain',    label: 'Jain (no onion/garlic)'),
  Modifier(id: 'ad_half',    label: 'Half Portion',     extraPrice: -50),
];

const _historyFixture = <HistoryOrder>[
  HistoryOrder(
    id: 'K-4127', tableId: 'T-02', time: '20:42', itemCount: 6, total: 1420.00,
    status: OrderStatus.sent,
    lines: [
      HistoryOrderLine(name: 'Butter Chicken',       qty: 1, price: 440, kitchenSection: 'curry'),
      HistoryOrderLine(name: 'Paneer Butter Masala', qty: 1, price: 360, kitchenSection: 'curry'),
      HistoryOrderLine(name: 'Garlic Naan',          qty: 4, price: 80,  kitchenSection: 'tandoor'),
      HistoryOrderLine(name: 'Sweet Lassi',          qty: 2, price: 120, kitchenSection: 'beverages'),
    ],
    notes: 'Less spicy please',
  ),
  HistoryOrder(
    id: 'K-4126', tableId: 'T-07', time: '20:18', itemCount: 11, total: 3180.00,
    status: OrderStatus.modified,
    lines: [
      HistoryOrderLine(name: 'Hyderabadi Biryani',   qty: 3, price: 380, kitchenSection: 'curry'),
      HistoryOrderLine(name: 'Tandoori Chicken',     qty: 1, price: 420, kitchenSection: 'tandoor', mods: ['Extra Spicy']),
      HistoryOrderLine(name: 'Butter Naan',          qty: 5, price: 70,  kitchenSection: 'tandoor'),
      HistoryOrderLine(name: 'Masala Chai',          qty: 2, price: 60,  kitchenSection: 'beverages'),
    ],
  ),
  HistoryOrder(
    id: 'K-4125', tableId: 'T-01', time: '19:58', itemCount: 3, total: 480.00,
    status: OrderStatus.sent,
    lines: [
      HistoryOrderLine(name: 'Masala Dosa',          qty: 2, price: 220, kitchenSection: 'south'),
      HistoryOrderLine(name: 'Cold Coffee',          qty: 1, price: 140, kitchenSection: 'beverages'),
    ],
  ),
  HistoryOrder(
    id: 'K-4124', tableId: 'T-03', time: '19:32', itemCount: 4, total: 720.00,
    status: OrderStatus.cancelled,
    lines: [
      HistoryOrderLine(name: 'Veg Hakka Noodles',    qty: 2, price: 240, kitchenSection: 'chinese'),
      HistoryOrderLine(name: 'Fresh Lime Soda',      qty: 2, price: 90,  kitchenSection: 'beverages'),
    ],
    notes: 'Customer left before order arrived',
  ),
  HistoryOrder(
    id: 'K-4123', tableId: 'T-09', time: '19:14', itemCount: 5, total: 980.00,
    status: OrderStatus.sent,
    lines: [
      HistoryOrderLine(name: 'Chilli Chicken',       qty: 1, price: 320, kitchenSection: 'chinese'),
      HistoryOrderLine(name: 'Schezwan Fried Rice',  qty: 2, price: 260, kitchenSection: 'chinese'),
      HistoryOrderLine(name: 'Sweet Lassi',          qty: 2, price: 120, kitchenSection: 'beverages'),
    ],
  ),
  HistoryOrder(
    id: 'K-4122', tableId: 'T-04', time: '18:48', itemCount: 7, total: 1640.00,
    status: OrderStatus.sent,
    lines: [
      HistoryOrderLine(name: 'Paneer Tikka',         qty: 1, price: 320, kitchenSection: 'tandoor'),
      HistoryOrderLine(name: 'Dal Makhani',          qty: 1, price: 280, kitchenSection: 'curry'),
      HistoryOrderLine(name: 'Kadhai Paneer',        qty: 1, price: 340, kitchenSection: 'curry'),
      HistoryOrderLine(name: 'Garlic Naan',          qty: 4, price: 80,  kitchenSection: 'tandoor'),
      HistoryOrderLine(name: 'Gulab Jamun (2 pc)',   qty: 2, price: 100, kitchenSection: 'beverages'),
    ],
  ),
];

// ─────────────── Providers ───────────────

final tablesProvider = StateProvider<List<RestaurantTable>>((_) => _tablesFixture);
final menuProvider   = Provider<List<MenuItem>>((_) => _menuFixture);

final selectedTableIdProvider = StateProvider<String?>((_) => null);

// Customer count entered when claiming a free table — feeds order builder header.
final orderCustomerCountProvider = StateProvider<int>((_) => 2);

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
    required double modsExtra,
    required String itemNote,
  }) {
    state = [
      ...state,
      CartLine(
        item: item,
        qty: qty,
        mods: mods,
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

final operatorProvider = Provider<Operator>(
  (_) => const Operator(
    username: 'riya',
    name: 'Riya Sharma',
    role: 'Senior Waiter',
    shift: '5:00 PM – 11:30 PM',
  ),
);

final operatorStatsProvider = Provider<OperatorStats>(
  (_) => const OperatorStats(ordersToday: 47, tablesServed: 23, itemsSold: 156),
);

final restaurantProvider = Provider<RestaurantInfo>(
  (_) => const RestaurantInfo(
    name: 'Spice Garden',
    address: 'Connaught Place, New Delhi',
    adminDeviceLabel: 'Counter PC · Spice Garden',
    adminIp: '192.168.1.5',
  ),
);

final connectionProvider = StateProvider<ConnectionStatus>(
  (_) => const ConnectionStatus(online: true, label: 'Connected · Spice Garden'),
);

// Active operators (besides "you") for presence indicators.
final activeOperatorsProvider = Provider<List<ActiveOperator>>(
  (_) => const [
    ActiveOperator(name: 'Priya', role: 'Waiter'),
    ActiveOperator(name: 'Karan', role: 'Waiter'),
    ActiveOperator(name: 'Manoj', role: 'Captain'),
  ],
);

final historyProvider = StateProvider<List<HistoryOrder>>((_) => _historyFixture);

// ─────────────── Auth ───────────────

final isAuthenticatedProvider = StateProvider<bool>((_) => false);

// ─────────────── KOT numbering ───────────────

int _kotCounter = 4127; // continues after fixture history
String generateKotId() => 'K-${++_kotCounter}';

final lastKotIdProvider = StateProvider<String>((_) => '');
