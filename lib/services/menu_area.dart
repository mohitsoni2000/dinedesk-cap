import 'socket_service.dart';

/// Area-wise menu: the desk can hide items on a floor, for Room Service,
/// Takeaway or Banquet. The desk works out the area from the table, room or
/// order and answers with the item ids hidden there, so this app needs no
/// floor ids or rules of its own. The desk also refuses a hidden item on
/// order:create / order:update, so a stale screen can never slip one through.

/// One row of the "Hidden here" list.
class MenuAreaHiddenEntry {
  final String id;

  /// `item` or `category`.
  final String targetType;
  final String targetId;
  final String targetName;
  final String? categoryName;

  /// `quick` — turned off by staff, anyone permitted can turn it back on.
  /// `admin` — hidden in the menu setup; only an admin lifts it, on the desk.
  final String source;

  const MenuAreaHiddenEntry({
    required this.id,
    required this.targetType,
    required this.targetId,
    required this.targetName,
    required this.categoryName,
    required this.source,
  });

  bool get isQuick => source == 'quick';
  bool get isCategory => targetType == 'category';

  static MenuAreaHiddenEntry? fromMap(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    final targetId = m['target_id']?.toString();
    if (id == null || id.isEmpty || targetId == null || targetId.isEmpty) {
      return null;
    }
    return MenuAreaHiddenEntry(
      id: id,
      targetType: m['target_type']?.toString() ?? 'item',
      targetId: targetId,
      targetName: m['target_name']?.toString() ?? '',
      categoryName: m['category_name']?.toString(),
      source: m['source']?.toString() ?? 'admin',
    );
  }
}

/// What is hidden for the table/room/order on screen.
class MenuAreaContext {
  final bool enabled;

  /// The area's name — a floor, `Room Service`, `Takeaway` or `Banquet`.
  final String? areaLabel;

  /// Whether this waiter may hide / show items here (per-role permission).
  final bool canToggle;
  final Set<String> hiddenItemIds;
  final List<MenuAreaHiddenEntry> entries;

  const MenuAreaContext({
    required this.enabled,
    required this.areaLabel,
    required this.canToggle,
    required this.hiddenItemIds,
    required this.entries,
  });

  static const MenuAreaContext empty = MenuAreaContext(
    enabled: false,
    areaLabel: null,
    canToggle: false,
    hiddenItemIds: <String>{},
    entries: <MenuAreaHiddenEntry>[],
  );

  bool isHidden(String itemId) => hiddenItemIds.contains(itemId);

  /// Parses a `menu_area:context` ack the desk answered. An error answer, or
  /// anything unexpected, hides nothing.
  factory MenuAreaContext.fromAck(Map<String, dynamic> ack) {
    if (ack['kind'] != 'success') return empty;
    final ids = <String>{};
    final rawIds = ack['hidden_item_ids'];
    if (rawIds is List) {
      for (final id in rawIds) {
        if (id != null) ids.add(id.toString());
      }
    }
    final entries = <MenuAreaHiddenEntry>[];
    final rawEntries = ack['entries'];
    if (rawEntries is List) {
      for (final e in rawEntries) {
        if (e is! Map) continue;
        final parsed =
            MenuAreaHiddenEntry.fromMap(Map<String, dynamic>.from(e));
        if (parsed != null) entries.add(parsed);
      }
    }
    final label = ack['area_label']?.toString();
    return MenuAreaContext(
      enabled: ack['enabled'] == true,
      areaLabel: (label == null || label.isEmpty) ? null : label,
      canToggle: ack['can_toggle'] == true,
      hiddenItemIds: ids,
      entries: entries,
    );
  }
}

/// Where the order screen is: its running order, else the table or room.
/// The desk derives the area (floor, Room Service, …) from this itself.
Map<String, dynamic> menuAreaWhere({
  required bool isRoom,
  required String slotId,
  String? orderId,
}) {
  if (orderId != null && orderId.isNotEmpty) {
    return <String, dynamic>{'order_id': orderId};
  }
  return isRoom
      ? <String, dynamic>{'room_id': slotId}
      : <String, dynamic>{'table_id': slotId};
}

/// Silent `menu_area:context` requests per socket. A desk older than this
/// feature never answers the event, and silence must not be read as a dead
/// link (see [SocketService.emitAckProbe]); after two in a row this session
/// stops asking.
final Expando<int> _silentContextAsks = Expando<int>('menuAreaSilence');

/// What the desk hides for [where], or null when it could not be asked (no
/// link, no answer) — callers keep what they had rather than un-hiding
/// everything on a blip. A desk that answers with an error hides nothing.
Future<MenuAreaContext?> fetchMenuAreaContext(
  SocketService socket,
  Map<String, dynamic> where,
) async {
  if ((_silentContextAsks[socket] ?? 0) >= 2) return MenuAreaContext.empty;
  final ack = await socket.emitAckProbe('menu_area:context', where);
  if (isTransportFailure(ack)) {
    if (ack['code'] == AckCode.timeout &&
        socket.state != SocketState.disconnected) {
      _silentContextAsks[socket] = (_silentContextAsks[socket] ?? 0) + 1;
    }
    return null;
  }
  _silentContextAsks[socket] = 0;
  return MenuAreaContext.fromAck(ack);
}

/// Hides (or shows again) an item/category for the area of [where]. Returns
/// the error message, or null on success.
Future<String?> setMenuAreaBlocked(
  SocketService socket,
  Map<String, dynamic> where, {
  required String targetType,
  required String targetId,
  required bool blocked,
}) async {
  try {
    final ack = await socket.emitAck('menu_area:set_blocked', <String, dynamic>{
      ...where,
      'target_type': targetType,
      'target_id': targetId,
      'blocked': blocked,
    });
    if (ack['kind'] == 'success') return null;
    return ack['message']?.toString() ?? 'Could not update the menu';
  } catch (_) {
    return 'Could not reach the desk — try again';
  }
}
