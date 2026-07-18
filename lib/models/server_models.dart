

double _toDouble(dynamic v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int _toInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _toStr(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  return v.toString();
}

bool _toBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is int) return v == 1;
  if (v is String) return v == '1' || v == 'true';
  return fallback;
}

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
  final int activeBillCount;
  final int orderItemCount;
  final int oldestKotMinutes;
  final int kotCount;
  final List<String> operatorIds;
  final List<String> operatorNames;

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
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.oldestKotMinutes = 0,
    this.kotCount = 0,
    this.operatorIds = const [],
    this.operatorNames = const [],
  });

  factory ServerTable.fromMap(Map<String, dynamic> m) {
    final operators = (m['operators'] as List?)
            ?.cast<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];
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
      activeBillCount: _toInt(m['active_bill_count']),
      orderItemCount: _toInt(m['order_item_count']),
      oldestKotMinutes: _toInt(m['oldest_kot_minutes']),
      kotCount: _toInt(m['kot_count']),
      operatorIds:
          operators.map((o) => _toStr(o['operator_id'])).toList(),
      operatorNames:
          operators.map((o) => _toStr(o['operator_name'])).toList(),
    );
  }
}

class ServerRoom {
  final String id;
  final String name;
  final int capacity;
  final String status;
  final String? floorId;
  final String? activeOrderId;
  final String? guestName;
  final double orderTotal;
  final int activeBillCount;
  final int orderItemCount;
  final int kotCount;

  const ServerRoom({
    required this.id,
    required this.name,
    required this.capacity,
    required this.status,
    this.floorId,
    this.activeOrderId,
    this.guestName,
    this.orderTotal = 0,
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.kotCount = 0,
  });

  factory ServerRoom.fromMap(Map<String, dynamic> m) {
    return ServerRoom(
      id: _toStr(m['id']),
      name: _toStr(m['name'], _toStr(m['id'])),
      capacity: _toInt(m['capacity'], 2),
      status: _toStr(m['status'], 'free'),
      floorId: m['floor_id']?.toString(),
      activeOrderId: m['active_order_id']?.toString(),
      guestName: m['guest_name']?.toString(),
      orderTotal: _toDouble(m['order_total']),
      activeBillCount: _toInt(m['active_bill_count']),
      orderItemCount: _toInt(m['order_item_count']),
      kotCount: _toInt(m['kot_count']),
    );
  }
}

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

class ServerOrder {
  final String id;
  final String tableId;
  final String roomId;
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
  final String? createdBy;
  final List<ServerOrderItem> items;

  bool get isRoom => roomId.isNotEmpty;

  const ServerOrder({
    required this.id,
    required this.tableId,
    this.roomId = '',
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
    this.createdBy,
  });

  factory ServerOrder.fromMap(Map<String, dynamic> m) {
    final foodSub = _toDouble(m['food_subtotal']);
    final liquorSub = _toDouble(m['liquor_subtotal']);
    final bevSub = _toDouble(m['beverages_subtotal']);
    final rawTotal = _toDouble(m['total']);
    final computedTotal =
        rawTotal > 0 ? rawTotal : (foodSub + liquorSub + bevSub);

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
      roomId: _toStr(m['room_id']),
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
      createdBy: m['created_by']?.toString() ?? m['operator_id']?.toString(),
    );
  }
}

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
  final String? variationId;
  final String? variationName;

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
    this.variationId,
    this.variationName,
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
      variationId: m['variation_id']?.toString(),
      variationName: m['variation_name']?.toString(),
    );
  }
}

class ServerMenuItem {
  final String id;
  final String name;
  final String categoryName;
  final String categoryType;
  final double basePrice;
  final bool isVeg;
  final bool isAvailable;
  final String? note;

  final String? measureUnit;
  final List<ServerMenuOptionGroup> optionGroups;
  final List<ServerItemVariation> variations;
  final List<ServerAddonGroup> addonGroups;

  const ServerMenuItem({
    required this.id,
    required this.name,
    required this.categoryName,
    required this.categoryType,
    required this.basePrice,
    required this.isVeg,
    required this.isAvailable,
    this.note,
    this.measureUnit,
    this.optionGroups = const [],
    this.variations = const [],
    this.addonGroups = const [],
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
      measureUnit: m['measure_unit']?.toString(),
      optionGroups: const [],
      variations: const [],
      addonGroups: const [],
    );
  }

  ServerMenuItem copyWith({
    List<ServerMenuOptionGroup>? optionGroups,
    List<ServerItemVariation>? variations,
    List<ServerAddonGroup>? addonGroups,
  }) =>
      ServerMenuItem(
        id: id,
        name: name,
        categoryName: categoryName,
        categoryType: categoryType,
        basePrice: basePrice,
        isVeg: isVeg,
        isAvailable: isAvailable,
        note: note,
        measureUnit: measureUnit,
        optionGroups: optionGroups ?? this.optionGroups,
        variations: variations ?? this.variations,
        addonGroups: addonGroups ?? this.addonGroups,
      );
}

class ServerAddonChoice {
  final String id;
  final String groupId;
  final String name;
  final double price;

  const ServerAddonChoice({
    required this.id,
    required this.groupId,
    required this.name,
    required this.price,
  });

  factory ServerAddonChoice.fromMap(Map<String, dynamic> m) {
    return ServerAddonChoice(
      id: _toStr(m['id']),
      groupId: _toStr(m['group_id']),
      name: _toStr(m['name']),
      price: _toDouble(m['price']),
    );
  }
}

class ServerAddonGroup {
  final String id;
  final String itemId;
  final String name;
  final String selectionType;
  final int minSelect;
  final int maxSelect;
  final List<ServerAddonChoice> choices;

  const ServerAddonGroup({
    required this.id,
    required this.itemId,
    required this.name,
    required this.selectionType,
    required this.minSelect,
    required this.maxSelect,
    this.choices = const [],
  });

  factory ServerAddonGroup.fromMap(Map<String, dynamic> m) {
    return ServerAddonGroup(
      id: _toStr(m['group_id'] ?? m['id']),
      itemId: _toStr(m['item_id']),
      name: _toStr(m['name'], 'Add-ons'),
      selectionType: _toStr(m['selection_type'], 'S'),
      minSelect: _toInt(m['min_select']),
      maxSelect: _toInt(m['max_select'], 1),
    );
  }

  ServerAddonGroup copyWith({List<ServerAddonChoice>? choices}) =>
      ServerAddonGroup(
        id: id,
        itemId: itemId,
        name: name,
        selectionType: selectionType,
        minSelect: minSelect,
        maxSelect: maxSelect,
        choices: choices ?? this.choices,
      );
}

class ServerMenuOptionGroup {
  final String id;
  final String itemId;
  final String name;
  final bool isRequired;
  final int minSelect;
  final int maxSelect;
  final List<ServerMenuOption> options;

  const ServerMenuOptionGroup({
    required this.id,
    required this.itemId,
    required this.name,
    required this.isRequired,
    required this.minSelect,
    required this.maxSelect,
    this.options = const [],
  });

  factory ServerMenuOptionGroup.fromMap(Map<String, dynamic> m) {
    return ServerMenuOptionGroup(
      id: _toStr(m['id']),
      itemId: _toStr(m['item_id']),
      name: _toStr(m['name'], 'Options'),
      isRequired: _toBool(m['is_required']),
      minSelect: _toInt(m['min_select']),
      maxSelect: _toInt(m['max_select'], 1),
    );
  }

  ServerMenuOptionGroup copyWith({
    List<ServerMenuOption>? options,
  }) =>
      ServerMenuOptionGroup(
        id: id,
        itemId: itemId,
        name: name,
        isRequired: isRequired,
        minSelect: minSelect,
        maxSelect: maxSelect,
        options: options ?? this.options,
      );
}

class ServerMenuOption {
  final String id;
  final String groupId;
  final String name;
  final double priceModifier;

  const ServerMenuOption({
    required this.id,
    required this.groupId,
    required this.name,
    required this.priceModifier,
  });

  factory ServerMenuOption.fromMap(Map<String, dynamic> m) {
    return ServerMenuOption(
      id: _toStr(m['id']),
      groupId: _toStr(m['group_id']),
      name: _toStr(m['name']),
      priceModifier: _toDouble(m['price_modifier']),
    );
  }
}

class ServerItemVariation {
  final String id;
  final String itemId;
  final String name;
  final double price;
  final int sortOrder;

  const ServerItemVariation({
    required this.id,
    required this.itemId,
    required this.name,
    required this.price,
    required this.sortOrder,
  });

  factory ServerItemVariation.fromMap(Map<String, dynamic> m) {
    return ServerItemVariation(
      id: _toStr(m['id']),
      itemId: _toStr(m['item_id']),
      name: _toStr(m['name']),
      price: _toDouble(m['price']),
      sortOrder: _toInt(m['sort_order']),
    );
  }
}

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
      return t
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return const [];
  }

  List<Map<String, dynamic>> get roomsList {
    final r = raw['rooms'];
    if (r is List) {
      return r
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return const [];
  }

  String? get orderId {
    return raw['order_id']?.toString() ??
        orderMap?['id']?.toString() ??
        raw['id']?.toString();
  }

  Map<String, dynamic>? get kotMap {
    final k = raw['kot'];
    if (k is Map) return Map<String, dynamic>.from(k);
    return null;
  }
}
