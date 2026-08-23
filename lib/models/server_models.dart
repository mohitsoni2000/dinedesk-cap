import '../data/money.dart';
import 'wire.dart';

class ServerTable {
  final String id;
  final String name;
  final int capacity;
  final String status;
  final String floorId;

  final Money? orderTotal;

  final String? activeOrderId;
  final String? reservationCustomer;
  final String? zone;
  final int activeBillCount;
  final int orderItemCount;
  final int oldestKotMinutes;
  final int kotCount;

  final DateTime? occupiedSince;

  final List<String> operatorIds;
  final List<String> operatorNames;
  final bool isActive;

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
    this.occupiedSince,
    this.operatorIds = const <String>[],
    this.operatorNames = const <String>[],
    this.isActive = true,
  });

  factory ServerTable.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerTable';
    final id = requireString(m, 'id', entity);
    final operators = mapList(m['operators']);

    final ids = <String>[];
    final names = <String>[];
    for (final op in operators) {
      final opId = optionalString(op, 'operator_id');
      if (opId == null) continue;
      ids.add(opId);
      names.add(stringOr(op, 'operator_name', 'Operator'));
    }

    return ServerTable(
      id: id,
      name: stringOr(m, 'name', id),
      capacity: intOr(m, 'capacity', 4),
      status: stringOr(m, 'status', 'free'),
      floorId: stringOr(m, 'floor_id', ''),
      orderTotal: optionalMoney(m, 'order_total'),
      activeOrderId: optionalString(m, 'active_order_id'),
      reservationCustomer: optionalString(m, 'reservation_customer'),
      zone: optionalString(m, 'zone'),
      activeBillCount: intOr(m, 'active_bill_count', 0),
      orderItemCount: intOr(m, 'order_item_count', 0),
      oldestKotMinutes: intOr(m, 'oldest_kot_minutes', 0),
      kotCount: intOr(m, 'kot_count', 0),
      occupiedSince: _parseUtc(optionalString(m, 'occupied_since')),
      operatorIds: ids,
      operatorNames: names,
      isActive: boolOr(m, 'is_active', true),
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
  final Money? orderTotal;
  final int activeBillCount;
  final int orderItemCount;
  final int kotCount;

  const ServerRoom({
    required this.id,
    required this.name,
    required this.capacity,
    required this.status,
    required this.orderTotal,
    this.floorId,
    this.activeOrderId,
    this.guestName,
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.kotCount = 0,
  });

  factory ServerRoom.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerRoom';
    final id = requireString(m, 'id', entity);
    return ServerRoom(
      id: id,
      name: stringOr(m, 'name', id),
      capacity: intOr(m, 'capacity', 2),
      status: stringOr(m, 'status', 'free'),
      orderTotal: optionalMoney(m, 'order_total'),
      floorId: optionalString(m, 'floor_id'),
      activeOrderId: optionalString(m, 'active_order_id'),
      guestName: optionalString(m, 'guest_name'),
      activeBillCount: intOr(m, 'active_bill_count', 0),
      orderItemCount: intOr(m, 'order_item_count', 0),
      kotCount: intOr(m, 'kot_count', 0),
    );
  }
}

class ServerFloor {
  final String id;
  final String name;

  const ServerFloor({required this.id, required this.name});

  factory ServerFloor.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerFloor';
    final id = requireString(m, 'id', entity);
    return ServerFloor(id: id, name: stringOr(m, 'name', 'Floor'));
  }
}

class ServerOrder {
  final String id;
  final String tableId;
  final String roomId;
  final String orderNumber;
  final String status;

  final Money total;

  final int itemCount;

  final String createdAt;

  final String? businessDate;

  final String? notes;
  final String? kotNumber;
  final String? createdBy;
  final String? customerId;
  final String? customerName;
  final List<ServerOrderItem> items;
  final List<ServerBill> bills;

  bool get isRoom => roomId.isNotEmpty;

  bool get hasBills => bills.isNotEmpty;

  const ServerOrder({
    required this.id,
    required this.tableId,
    required this.orderNumber,
    required this.status,
    required this.total,
    required this.itemCount,
    required this.createdAt,
    required this.items,
    this.bills = const <ServerBill>[],
    this.roomId = '',
    this.businessDate,
    this.notes,
    this.kotNumber,
    this.createdBy,
    this.customerId,
    this.customerName,
  });

  factory ServerOrder.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerOrder';
    final items = parseEach(
      mapList(m['items']),
      ServerOrderItem.fromMap,
      'ServerOrderItem',
    );
    final bills = parseEach(
      mapList(m['bills']),
      ServerBill.fromMap,
      'ServerBill',
    );
    final sentCount = optionalInt(m, 'item_count');

    return ServerOrder(
      id: requireString(m, 'id', entity),
      tableId: optionalString(m, 'table_id') ?? '',
      roomId: optionalString(m, 'room_id') ?? '',
      orderNumber: optionalString(m, 'order_number') ?? '',
      status: stringOr(m, 'status', 'open'),
      total: requireMoney(m, 'total', entity),
      itemCount: sentCount ?? items.length,
      createdAt: optionalString(m, 'created_at') ?? '',
      businessDate: optionalString(m, 'business_date'),
      items: items,
      bills: bills,
      notes: optionalString(m, 'notes'),
      kotNumber: optionalString(m, 'kot_number'),
      createdBy: optionalStringAny(m, <String>['created_by', 'operator_id']),
      customerId: optionalString(m, 'customer_id'),
      customerName: optionalString(m, 'customer_name'),
    );
  }
}

class ServerBill {
  final String id;
  final String billNumber;
  final Money totalAmount;
  final String billType;
  final bool isPaid;

  const ServerBill({
    required this.id,
    required this.billNumber,
    required this.totalAmount,
    required this.billType,
    required this.isPaid,
  });

  factory ServerBill.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerBill';
    return ServerBill(
      id: requireString(m, 'id', entity),
      billNumber: optionalString(m, 'bill_number') ?? '',
      totalAmount: requireMoney(m, 'total_amount', entity),
      billType: stringOr(m, 'bill_type', 'food'),
      isPaid: boolOr(m, 'is_paid', false) ||
          <String>['paid', 'credit', 'settled']
              .contains(stringOr(m, 'status', '').toLowerCase()),
    );
  }
}

class ServerOrderItem {
  final String id;
  final String itemId;
  final String itemName;
  final int quantity;

  final Money unitPrice;

  final Money totalPrice;
  final Money optionsPrice;
  final String itemType;
  final String selectedOptions;
  final String? notes;
  final String? kotStatus;

  final String? kotNumber;

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
    this.kotNumber,
    this.variationId,
    this.variationName,
  });

  factory ServerOrderItem.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerOrderItem';
    return ServerOrderItem(
      id: requireString(m, 'id', entity),
      itemId: optionalString(m, 'item_id') ?? '',
      itemName: optionalStringAny(m, <String>['item_name', 'name']) ?? 'Item',
      quantity: intOr(m, 'quantity', 1),
      unitPrice: requireMoney(m, 'unit_price', entity),
      totalPrice: requireMoney(m, 'total_price', entity),
      optionsPrice: optionalMoney(m, 'options_price') ?? Money.zero,
      itemType: stringOr(m, 'item_type', 'food'),
      selectedOptions: optionalString(m, 'selected_options') ?? '',
      notes: optionalString(m, 'notes'),
      kotStatus: optionalString(m, 'kot_status'),
      kotNumber: optionalString(m, 'kot_number'),
      variationId: optionalString(m, 'variation_id'),
      variationName: optionalString(m, 'variation_name'),
    );
  }
}

class ServerMenuItem {
  final String id;
  final String name;
  final String categoryName;
  final String categoryType;
  final Money basePrice;
  final bool isVeg;
  final bool isAvailable;
  final String? note;
  final String? measureUnit;
  final int sortOrder;
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
    this.sortOrder = 0,
    this.optionGroups = const <ServerMenuOptionGroup>[],
    this.variations = const <ServerItemVariation>[],
    this.addonGroups = const <ServerAddonGroup>[],
  });

  factory ServerMenuItem.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerMenuItem';
    return ServerMenuItem(
      id: requireString(m, 'id', entity),
      name: stringOr(m, 'name', 'Item'),
      categoryName: optionalStringAny(
              m, <String>['category_name', 'category', 'section']) ??
          'Other',
      categoryType: stringOr(m, 'category_type', 'food'),
      basePrice: optionalMoney(m, 'base_price') ??
          optionalMoney(m, 'price') ??
          Money.zero,
      isVeg: requireBool(m, 'is_veg', entity),
      isAvailable: optionalBool(m, 'is_available') ??
          optionalBool(m, 'available') ??
          true,
      note: optionalString(m, 'note'),
      measureUnit: optionalString(m, 'measure_unit'),
      sortOrder: intOr(m, 'sort_order', 0),
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
        sortOrder: sortOrder,
        optionGroups: optionGroups ?? this.optionGroups,
        variations: variations ?? this.variations,
        addonGroups: addonGroups ?? this.addonGroups,
      );
}

class ServerAddonChoice {
  final String id;
  final String groupId;
  final String name;
  final Money price;

  const ServerAddonChoice({
    required this.id,
    required this.groupId,
    required this.name,
    required this.price,
  });

  factory ServerAddonChoice.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerAddonChoice';
    return ServerAddonChoice(
      id: requireString(m, 'id', entity),
      groupId: optionalString(m, 'group_id') ?? '',
      name: stringOr(m, 'name', 'Add-on'),
      price: requireMoney(m, 'price', entity),
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
    this.choices = const <ServerAddonChoice>[],
  });

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
    this.options = const <ServerMenuOption>[],
  });

  factory ServerMenuOptionGroup.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerMenuOptionGroup';
    return ServerMenuOptionGroup(
      id: requireString(m, 'id', entity),
      itemId: optionalString(m, 'item_id') ?? '',
      name: stringOr(m, 'name', 'Options'),
      isRequired: boolOr(m, 'is_required', false),
      minSelect: intOr(m, 'min_select', 0),
      maxSelect: intOr(m, 'max_select', 1),
    );
  }

  ServerMenuOptionGroup copyWith({List<ServerMenuOption>? options}) =>
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
  final Money priceModifier;

  const ServerMenuOption({
    required this.id,
    required this.groupId,
    required this.name,
    required this.priceModifier,
  });

  factory ServerMenuOption.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerMenuOption';
    return ServerMenuOption(
      id: requireString(m, 'id', entity),
      groupId: optionalString(m, 'group_id') ?? '',
      name: stringOr(m, 'name', 'Option'),
      priceModifier: optionalMoney(m, 'price_modifier') ?? Money.zero,
    );
  }
}

class ServerItemVariation {
  final String id;
  final String itemId;
  final String name;
  final Money price;
  final int sortOrder;

  const ServerItemVariation({
    required this.id,
    required this.itemId,
    required this.name,
    required this.price,
    required this.sortOrder,
  });

  factory ServerItemVariation.fromMap(Map<String, dynamic> m) {
    const entity = 'ServerItemVariation';
    return ServerItemVariation(
      id: requireString(m, 'id', entity),
      itemId: optionalString(m, 'item_id') ?? '',
      name: stringOr(m, 'name', 'Variation'),
      price: requireMoney(m, 'price', entity),
      sortOrder: intOr(m, 'sort_order', 0),
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

  factory ServerRestaurantInfo.fromMap(Map<String, dynamic> m) =>
      ServerRestaurantInfo(
        name: optionalStringAny(m, <String>['restaurant_name', 'name']) ??
            'Restaurant',
        address: optionalString(m, 'address') ?? '',
        phone: optionalString(m, 'phone') ?? '',
      );
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

  factory ServerOperatorPresence.fromMap(Map<String, dynamic> m) =>
      ServerOperatorPresence(
        operatorId: optionalStringAny(m, <String>['operatorId', 'id']) ?? '',
        operatorName:
            optionalStringAny(m, <String>['operatorName', 'name']) ?? '',
        role: optionalString(m, 'role') ?? '',
      );
}

class BroadcastEnvelope {
  final Map<String, dynamic> raw;

  const BroadcastEnvelope(this.raw);

  Map<String, dynamic>? get orderMap => optionalMap(raw, 'order');

  List<Map<String, dynamic>> get tablesList => mapList(raw['tables']);

  List<Map<String, dynamic>> get roomsList => mapList(raw['rooms']);

  String? get orderId =>
      optionalString(raw, 'order_id') ??
      (orderMap == null ? null : optionalString(orderMap!, 'id')) ??
      optionalString(raw, 'id');

  Map<String, dynamic>? get kotMap => optionalMap(raw, 'kot');

  bool get orderSettled => raw['order_settled'] == true;
}

DateTime? _parseUtc(String? iso) {
  if (iso == null) return null;
  return DateTime.tryParse(iso)?.toLocal();
}
