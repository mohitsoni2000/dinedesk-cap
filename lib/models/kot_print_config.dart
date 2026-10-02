/// The desk's KOT print routing, in the shape the desk sends it as
/// `kot_print_config` (initial sync / resync) and `print_config:updated`.
///
/// It exists so a handset can put a KOT on a LAN thermal printer by itself when
/// the desk is unreachable. It carries only what the desk's own router
/// (`planKotDispatch`, print-group branch) needs and only NETWORK destinations
/// — a Windows-spooled printer cannot be reached from a phone. The desk omits
/// the whole object when print groups are off or no network destination
/// exists, and then direct printing is simply unavailable.
///
/// Parsing is lenient on purpose (ids may arrive as numbers, lists may be
/// missing): a config that is partly malformed must degrade to "fewer
/// destinations", never to a thrown exception on the sync path.
library;

/// One physical printer a group prints to.
class KotPrintDestination {
  final String host;
  final int port;
  final int copies;
  final int printableWidthMm;
  final int charsPerLine;

  const KotPrintDestination({
    required this.host,
    required this.port,
    this.copies = 1,
    this.printableWidthMm = 72,
    this.charsPerLine = 42,
  });

  /// `host:port`, the unit a job is serialised on.
  String get key => '$host:$port';

  static KotPrintDestination? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final host = raw['host']?.toString().trim() ?? '';
    if (host.isEmpty) return null;
    final port = _int(raw['port']) ?? 9100;
    if (port <= 0 || port > 65535) return null;
    final copies = _int(raw['copies']) ?? 1;
    return KotPrintDestination(
      host: host,
      port: port,
      // The desk treats 0/negative copies as 1.
      copies: copies > 0 ? copies : 1,
      printableWidthMm: _int(raw['printable_width_mm']) ?? 72,
      charsPerLine: _int(raw['chars_per_line']) ?? 42,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'port': port,
        'copies': copies,
        'printable_width_mm': printableWidthMm,
        'chars_per_line': charsPerLine,
      };
}

/// A print group: a station (Kitchen, Bar...) and where it prints.
class KotPrintGroup {
  final String id;
  final String name;
  final bool isMaster;
  final bool isFallback;

  /// Empty means "every order type".
  final List<String> orderTypes;

  /// Empty means "every floor".
  final List<String> floorIds;
  final List<KotPrintDestination> destinations;

  const KotPrintGroup({
    required this.id,
    required this.name,
    this.isMaster = false,
    this.isFallback = false,
    this.orderTypes = const <String>[],
    this.floorIds = const <String>[],
    this.destinations = const <KotPrintDestination>[],
  });

  static KotPrintGroup? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final destinations = <KotPrintDestination>[];
    final rawDestinations = raw['destinations'];
    if (rawDestinations is List) {
      for (final d in rawDestinations) {
        final parsed = KotPrintDestination.tryParse(d);
        if (parsed != null) destinations.add(parsed);
      }
    }
    return KotPrintGroup(
      id: id,
      name: raw['name']?.toString() ?? id,
      isMaster: _bool(raw['is_master']),
      isFallback: _bool(raw['is_fallback']),
      orderTypes: _strings(raw['order_types']),
      floorIds: _strings(raw['floor_ids']),
      destinations: destinations,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'is_master': isMaster,
        'is_fallback': isFallback,
        'order_types': orderTypes,
        'floor_ids': floorIds,
        'destinations': destinations.map((d) => d.toJson()).toList(),
      };
}

/// How a floor is written on a slip.
class KotFloorLabel {
  final String printName;

  /// Print the bare table name, without the "Table" word.
  final bool nameOnly;

  const KotFloorLabel({required this.printName, this.nameOnly = false});

  static KotFloorLabel? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return KotFloorLabel(
      printName: raw['print_name']?.toString() ?? '',
      nameOnly: _bool(raw['name_only']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'print_name': printName,
        'name_only': nameOnly,
      };
}

class KotPrintConfig {
  /// A hash of the content; changes whenever the routing does.
  final String version;
  final List<KotPrintGroup> groups;

  /// item id -> print group ids.
  final Map<String, List<String>> itemGroups;

  /// category id -> print group ids.
  final Map<String, List<String>> categoryGroups;

  /// floor id -> how to print it.
  final Map<String, KotFloorLabel> floors;
  final bool beveragesEnabled;

  const KotPrintConfig({
    required this.version,
    required this.groups,
    this.itemGroups = const <String, List<String>>{},
    this.categoryGroups = const <String, List<String>>{},
    this.floors = const <String, KotFloorLabel>{},
    this.beveragesEnabled = false,
  });

  KotPrintGroup? groupById(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// True when at least one destination exists, i.e. direct printing can do
  /// anything at all.
  bool get hasDestinations => groups.any((g) => g.destinations.isNotEmpty);

  /// Null for an absent / unusable config (a `null` from the desk is the
  /// normal "direct printing not available" answer, not an error).
  static KotPrintConfig? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final groups = <KotPrintGroup>[];
    final rawGroups = raw['groups'];
    if (rawGroups is List) {
      for (final g in rawGroups) {
        final parsed = KotPrintGroup.tryParse(g);
        if (parsed != null) groups.add(parsed);
      }
    }
    if (groups.isEmpty) return null;
    final floors = <String, KotFloorLabel>{};
    final rawFloors = raw['floors'];
    if (rawFloors is Map) {
      rawFloors.forEach((k, v) {
        final label = KotFloorLabel.tryParse(v);
        if (label != null) floors[k.toString()] = label;
      });
    }
    return KotPrintConfig(
      version: raw['version']?.toString() ?? '',
      groups: groups,
      itemGroups: _groupMap(raw['item_groups']),
      categoryGroups: _groupMap(raw['category_groups']),
      floors: floors,
      beveragesEnabled: _bool(raw['beverages_enabled']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'groups': groups.map((g) => g.toJson()).toList(),
        'item_groups': itemGroups,
        'category_groups': categoryGroups,
        'floors': floors.map((k, v) => MapEntry(k, v.toJson())),
        'beverages_enabled': beveragesEnabled,
      };
}

int? _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is double && raw.isFinite) return raw.round();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

bool _bool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) return raw == '1' || raw.toLowerCase() == 'true';
  return false;
}

List<String> _strings(Object? raw) {
  if (raw is List) {
    return <String>[
      for (final e in raw)
        if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
    ];
  }
  // The desk's own columns are CSV strings; tolerate one slipping through.
  if (raw is String) {
    return <String>[
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }
  return const <String>[];
}

Map<String, List<String>> _groupMap(Object? raw) {
  final out = <String, List<String>>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      final ids = _strings(v);
      if (ids.isNotEmpty) out[k.toString()] = ids;
    });
  }
  return out;
}
