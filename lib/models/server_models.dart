// Typed server response models — validated at the boundary.
//
// These classes parse raw Map<String, dynamic> from socket events
// into strictly typed Dart objects. All validation happens in the
// factory constructors. After construction, every field is guaranteed
// non-null and correctly typed.

/// Parses a dynamic value to double. Returns 0 if not parseable.
double _toDouble(dynamic v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

/// Parses a dynamic value to int. Returns [fallback] if not parseable.
int _toInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

/// Parses a dynamic value to String. Returns [fallback] if null.
String _toStr(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  return v.toString();
}

/// Parses a dynamic value to bool. Handles int (0/1), bool, String.
bool _toBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is int) return v == 1;
  if (v is String) return v == '1' || v == 'true';
  return fallback;
}

// ─────────────── Server Table ───────────────

class ServerTable {
  final String id;
  final String name;
  final int capacity;
  final String status;
  final String floorId;
  final double orderTotal;
  final String? activeOrderId;
  final String? reservationCustomer;
  final String? zone;

  const ServerTable({
    required this.id,
    required this.name,
    required this.capacity,
    required this.status,
    required this.floorId,
    required this.orderTotal,
    this.activeOrderId,
    this.reservationCustomer,
    this.zone,
  });

  factory ServerTable.fromMap(Map<String, dynamic> m) {
    return ServerTable(
      id: _toStr(m['id']),
      name: _toStr(m['name'], _toStr(m['id'])),
      capacity: _toInt(m['capacity'], 4),
      status: _toStr(m['status'], 'free'),
      floorId: _toStr(m['floor_id']),
      orderTotal: _toDouble(m['order_total']),
      activeOrderId: m['active_order_id']?.toString(),
      reservationCustomer: m['reservation_customer']?.toString(),
      zone: m['zone']?.toString(),
    );
  }
}

// ─────────────── Server Floor ───────────────

class ServerFloor {
  final String id;
  final String name;

  const ServerFloor({required this.id, required this.name});

  factory ServerFloor.fromMap(Map<String, dynamic> m) {
    return ServerFloor(
      id: _toStr(m['id']),
      name: _toStr(m['name'], 'Floor'),
    );
  }
}

// ─────────────── Server Order ───────────────

class ServerOrder {
  final String id;
  final String tableId;
  final String orderNumber;
  final String status;
  final double foodSubtotal;
  final double liquorSubtotal;
  final double beveragesSubtotal;
  final double total;
  final int itemCount;
  final String createdAt;
  final String? notes;
  final String? kotNumber;
  final List<ServerOrderItem> items;

  const ServerOrder({
    required this.id,
    required this.tableId,
    required this.orderNumber,
    required this.status,
    required this.foodSubtotal,
    required this.liquorSubtotal,
    required this.beveragesSubtotal,
    required this.total,
    required this.itemCount,
    required this.createdAt,
    required this.items,
    this.notes,
    this.kotNumber,
  });

  factory ServerOrder.fromMap(Map<String, dynamic> m) {
    final foodSub = _toDouble(m['food_subtotal']);
    final liquorSub = _toDouble(m['liquor_subtotal']);
    final bevSub = _toDouble(m['beverages_subtotal']);
    final rawTotal = _toDouble(m['total']);
    final computedTotal = rawTotal > 0 ? rawTotal : (foodSub + liquorSub + bevSub);

    final rawItems = m['items'];
    final List<ServerOrderItem> items = (rawItems is List)
        ? rawItems
            .whereType<Map>()
            .map((e) => ServerOrderItem.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : const [];

    final itemCount = _toInt(m['item_count']);

    return ServerOrder(
      id: _toStr(m['id']),
      tableId: _toStr(m['table_id']),
      orderNumber: _toStr(m['order_number']),
      status: _toStr(m['status'], 'open'),
      foodSubtotal: foodSub,
      liquorSubtotal: liquorSub,
      beveragesSubtotal: bevSub,
      total: computedTotal,
      itemCount: itemCount > 0 ? itemCount : items.length,
      createdAt: _toStr(m['created_at']),
      items: items,
      notes: m['notes']?.toString(),
      kotNumber: m['kot_number']?.toString(),
    );
  }
}

// ─────────────── Server Order Item ───────────────

class ServerOrderItem {
  final String id;
  final String itemId;
  final String itemName;
  final int quantity;
  final double unitPrice;
  final double totalPrice;
  final double optionsPrice;
  final String itemType;
  final String selectedOptions;
  final String? notes;
  final String? kotStatus;

  const ServerOrderItem({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.quantity,
    required this.unitPrice,
    required this.totalPrice,
    required this.optionsPrice,
    required this.itemType,
    required this.selectedOptions,
    this.notes,
    this.kotStatus,
  });

  factory ServerOrderItem.fromMap(Map<String, dynamic> m) {
    return ServerOrderItem(
      id: _toStr(m['id']),
      itemId: _toStr(m['item_id']),
      itemName: _toStr(m['item_name'], _toStr(m['name'])),
      quantity: _toInt(m['quantity'], 1),
      unitPrice: _toDouble(m['unit_price']),
      totalPrice: _toDouble(m['total_price']),
      optionsPrice: _toDouble(m['options_price']),
      itemType: _toStr(m['item_type'], 'food'),
      selectedOptions: _toStr(m['selected_options']),
      notes: m['notes']?.toString(),
      kotStatus: m['kot_status']?.toString(),
    );
  }
}

// ─────────────── Server Menu Item ───────────────

class ServerMenuItem {
  final String id;
  final String name;
  final String categoryName;
  final String categoryType;
  final double basePrice;
  final bool isVeg;
  final bool isAvailable;
  final String? note;

  const ServerMenuItem({
    required this.id,
    required this.name,
    required this.categoryName,
    required this.categoryType,
    required this.basePrice,
    required this.isVeg,
    required this.isAvailable,
    this.note,
  });

  factory ServerMenuItem.fromMap(Map<String, dynamic> m) {
    return ServerMenuItem(
      id: _toStr(m['id']),
      name: _toStr(m['name']),
      categoryName: _toStr(
        m['category_name'] ?? m['category'] ?? m['section'],
        'Other',
      ),
      categoryType: _toStr(m['category_type'], 'food'),
      basePrice: _toDouble(m['base_price'] ?? m['price']),
      isVeg: _toBool(m['is_veg']),
      isAvailable: _toBool(m['is_available'] ?? m['available'], true),
      note: m['note']?.toString(),
    );
  }
}

// ─────────────── Server Restaurant Info ───────────────

class ServerRestaurantInfo {
  final String name;
  final String address;
  final String phone;

  const ServerRestaurantInfo({
    required this.name,
    required this.address,
    required this.phone,
  });

  factory ServerRestaurantInfo.fromMap(Map<String, dynamic> m) {
    return ServerRestaurantInfo(
      name: _toStr(m['restaurant_name'] ?? m['name'], 'Restaurant'),
      address: _toStr(m['address']),
      phone: _toStr(m['phone']),
    );
  }
}

// ─────────────── Server Operator Presence ───────────────

class ServerOperatorPresence {
  final String operatorId;
  final String operatorName;
  final String role;

  const ServerOperatorPresence({
    required this.operatorId,
    required this.operatorName,
    required this.role,
  });

  factory ServerOperatorPresence.fromMap(Map<String, dynamic> m) {
    return ServerOperatorPresence(
      operatorId: _toStr(m['operatorId'] ?? m['id']),
      operatorName: _toStr(m['operatorName'] ?? m['name']),
      role: _toStr(m['role']),
    );
  }
}

// ─────────────── Broadcast Envelope ───────────────

/// Many Desktop broadcasts wrap data as `{ order: {...}, tables: [...] }`.
class BroadcastEnvelope {
  final Map<String, dynamic> raw;

  const BroadcastEnvelope(this.raw);

  Map<String, dynamic>? get orderMap {
    final o = raw['order'];
    if (o is Map) return Map<String, dynamic>.from(o);
    return null;
  }

  List<Map<String, dynamic>> get tablesList {
    final t = raw['tables'];
    if (t is List) {
      return t.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    }
    return const [];
  }

  String? get orderId {
    return raw['order_id']?.toString() ??
        orderMap?['id']?.toString() ??
        raw['id']?.toString();
  }
}
