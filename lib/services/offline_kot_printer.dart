import 'dart:async';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../data/ist_time.dart';
import '../models/kot_print_config.dart';
import 'escpos_builder.dart';
import 'lan_printer_service.dart';
import 'log.dart';

const String _tag = '[OfflineKot]';

/// `failed_group_ids` entry for items the desk would have sent to its legacy
/// per-type (Windows) printers: no group claims them and there is no fallback
/// group. The phone cannot reach those, so the desk must print them on replay.
const String legacyFailedGroupId = 'legacy';

/// One line of the KOT with the two keys routing reads.
class OfflineKotLine {
  final String itemId;

  /// The menu category the item belongs to (null when unknown: the item then
  /// can only be routed by its own `item_groups` entry).
  final String? categoryId;
  final KotSlipItem slip;

  const OfflineKotLine({
    required this.itemId,
    this.categoryId,
    required this.slip,
  });
}

/// What to print.
class OfflineKotRequest {
  final List<OfflineKotLine> lines;

  /// `dine_in` | `takeaway` | `room` — the same values the order carries.
  final String orderType;

  /// The table's / room's floor id, when known (needed to honour floor-scoped
  /// groups; dine-in/room KOTs with an unknown floor skip those groups, as on
  /// the desk).
  final String? floorId;

  /// Fallback floor text when the config has no label for [floorId].
  final String? floorName;
  final String tableName;
  final String slotLabel;
  final String? guestName;
  final String? orderNotes;

  /// The signed-in operator, printed as "Steward".
  final String operatorName;
  final String offlineRef;
  final DateTime at;

  /// The order's daily token when it already has one: the slip then carries
  /// the desk's token banner. A counter order queued before reaching the
  /// desk has none yet (the desk gives it with the first KOT).
  final KotTokenView? token;

  const OfflineKotRequest({
    required this.lines,
    required this.orderType,
    this.floorId,
    this.floorName,
    required this.tableName,
    this.slotLabel = 'Table',
    this.guestName,
    this.orderNotes,
    required this.operatorName,
    required this.offlineRef,
    required this.at,
    this.token,
  });
}

/// The routing decision, before anything is sent. Mirrors the desk's
/// `planKotDispatch` print-group branch.
class OfflineKotPlan {
  /// group id -> the lines it prints, in dispatch order (item groups, then the
  /// fallback group, then masters).
  final Map<String, List<OfflineKotLine>> byGroup;

  /// Lines no group claims and no fallback group exists for: the desk would use
  /// its legacy Windows printers, which a phone cannot reach.
  final List<OfflineKotLine> legacy;

  const OfflineKotPlan(this.byGroup, this.legacy);
}

/// Outcome of one direct-print attempt.
class OfflineKotOutcome {
  final String offlineRef;
  final List<String> printedGroupIds;
  final List<String> failedGroupIds;

  /// group id -> why its (first failing) destination failed. For logs/UI.
  final Map<String, String> errors;

  const OfflineKotOutcome({
    required this.offlineRef,
    this.printedGroupIds = const <String>[],
    this.failedGroupIds = const <String>[],
    this.errors = const <String, String>{},
  });

  /// Nothing was printable at all (no config, no items, no usable group).
  static OfflineKotOutcome none(String ref) => OfflineKotOutcome(
      offlineRef: ref, errors: const <String, String>{});

  bool get anyPrinted => printedGroupIds.isNotEmpty;
  bool get allPrinted => anyPrinted && failedGroupIds.isEmpty;

  /// The fields that ride in the queued `kot:send` payload (contract item 10).
  /// Empty when nothing printed — the desk must then print normally, so the
  /// flag must not be set at all.
  Map<String, dynamic> toPayloadFields(DateTime printedAt) {
    if (!anyPrinted) return const <String, dynamic>{};
    return <String, dynamic>{
      'printed_offline': true,
      'offline_ref': offlineRef,
      'printed_at': printedAt.toUtc().toIso8601String(),
      'failed_group_ids': failedGroupIds,
    };
  }
}

/// Prints a KOT straight to the LAN thermal printers when the desk can't be
/// reached, using the routing config the desk last synced.
class OfflineKotPrinter {
  OfflineKotPrinter({required LanPrinter printer}) : _printer = printer;

  final LanPrinter _printer;

  /// `groupAppliesToOrderType`: empty list or unknown order type = all.
  static bool _appliesToOrderType(KotPrintGroup g, String orderType) {
    if (g.orderTypes.isEmpty) return true;
    if (orderType.isEmpty) return true;
    return g.orderTypes.contains(orderType);
  }

  /// `groupAppliesToFloorForJob` for a KOT: takeaway/online orders have no
  /// floor and must still reach floor-scoped groups; seating needs a known
  /// floor to match.
  static bool _appliesToFloor(
      KotPrintGroup g, String orderType, String? floorId) {
    if (orderType == 'online' || orderType == 'takeaway') return true;
    if (g.floorIds.isEmpty) return true;
    if (floorId == null || floorId.isEmpty) return false;
    return g.floorIds.contains(floorId);
  }

  static bool _accepts(KotPrintGroup g, String orderType, String? floorId) =>
      _appliesToOrderType(g, orderType) &&
      _appliesToFloor(g, orderType, floorId);

  /// The ids a line routes to, in precedence order: its own item groups, else
  /// its category's groups (only groups present in the config count).
  static List<String> _resolveGroupIds(
      OfflineKotLine line, KotPrintConfig config) {
    List<String> valid(List<String>? ids) => <String>[
          for (final id in ids ?? const <String>[])
            if (config.groupById(id) != null) id,
        ];
    final own = valid(config.itemGroups[line.itemId]);
    if (own.isNotEmpty) return own;
    final category = line.categoryId;
    if (category != null) return valid(config.categoryGroups[category]);
    return const <String>[];
  }

  /// Pure routing. Print groups on: each item goes to the non-master groups it
  /// resolves to that accept this KOT (order type + floor); items nobody claims
  /// go to the fallback group; every master group also gets everything.
  static OfflineKotPlan plan(
    List<OfflineKotLine> lines,
    KotPrintConfig config, {
    required String orderType,
    String? floorId,
  }) {
    final buckets = <String, List<OfflineKotLine>>{};
    final unrouted = <OfflineKotLine>[];
    for (final line in lines) {
      var routed = false;
      for (final gid in _resolveGroupIds(line, config).toSet()) {
        final grp = config.groupById(gid);
        if (grp != null &&
            !grp.isMaster &&
            _accepts(grp, orderType, floorId)) {
          routed = true;
          buckets.putIfAbsent(gid, () => <OfflineKotLine>[]).add(line);
        }
      }
      if (!routed) unrouted.add(line);
    }

    final byGroup = <String, List<OfflineKotLine>>{...buckets};
    final legacy = <OfflineKotLine>[];
    String? fallbackId;
    if (unrouted.isNotEmpty) {
      KotPrintGroup? fallback;
      for (final g in config.groups) {
        if (g.isFallback && _accepts(g, orderType, floorId)) {
          fallback = g;
          break;
        }
      }
      if (fallback != null) {
        fallbackId = fallback.id;
        byGroup[fallback.id] = <OfflineKotLine>[
          ...?byGroup[fallback.id],
          ...unrouted,
        ];
      } else {
        legacy.addAll(unrouted);
      }
    }

    if (lines.isNotEmpty) {
      for (final g in config.groups) {
        if (!g.isMaster || !_accepts(g, orderType, floorId)) continue;
        if (g.id == fallbackId) continue;
        byGroup[g.id] = <OfflineKotLine>[...lines];
      }
    }
    return OfflineKotPlan(byGroup, legacy);
  }

  /// The slip for one group, mirroring `groupTask`'s heading (upper-cased group
  /// name) and the desk's context.
  EscposDoc buildSlip(
    KotPrintConfig config,
    KotPrintGroup group,
    List<OfflineKotLine> lines,
    OfflineKotRequest req,
  ) {
    final floor = req.floorId == null ? null : config.floors[req.floorId];
    final floorText = (floor != null && floor.printName.trim().isNotEmpty)
        ? floor.printName
        : req.floorName;
    return buildKotEscpos(KotSlipContext(
      stationLabel: group.name.toUpperCase(),
      kotNumber: req.offlineRef,
      tableName: req.tableName,
      floorName: floorText,
      slotLabel: req.slotLabel,
      nameOnly: floor?.nameOnly ?? false,
      guestName: req.guestName,
      waiterName: req.operatorName,
      orderNotes: req.orderNotes,
      dateStr: formatIstSlipDate(req.at),
      timeStr: formatIstSlipTime(req.at),
      isOffline: true,
      items: <KotSlipItem>[for (final l in lines) l.slip],
      token: req.token,
    ));
  }

  /// Routes and prints. Never throws.
  Future<OfflineKotOutcome> print(
    KotPrintConfig config,
    OfflineKotRequest req,
  ) async {
    if (req.lines.isEmpty) return OfflineKotOutcome.none(req.offlineRef);
    final plan = OfflineKotPrinter.plan(
      req.lines,
      config,
      orderType: req.orderType,
      floorId: req.floorId,
    );

    final failed = <String>[];
    final printed = <String>[];
    final errors = <String, String>{};
    if (plan.legacy.isNotEmpty) {
      failed.add(legacyFailedGroupId);
      errors[legacyFailedGroupId] =
          'no print group or fallback group for ${plan.legacy.length} item(s)';
    }

    // One future per group; within a group every destination runs in parallel
    // and the service queues jobs per destination, so two groups sharing one
    // printer still go out one slip at a time.
    final results = await Future.wait(<Future<_GroupResult>>[
      for (final entry in plan.byGroup.entries)
        _printGroup(config, entry.key, entry.value, req),
    ]);
    for (final r in results) {
      if (r.ok) {
        printed.add(r.groupId);
      } else {
        failed.add(r.groupId);
        errors[r.groupId] = r.error ?? 'failed';
      }
    }
    logD(_tag, '${req.offlineRef}: printed=$printed failed=$failed');
    return OfflineKotOutcome(
      offlineRef: req.offlineRef,
      printedGroupIds: printed,
      failedGroupIds: failed,
      errors: errors,
    );
  }

  Future<_GroupResult> _printGroup(
    KotPrintConfig config,
    String groupId,
    List<OfflineKotLine> lines,
    OfflineKotRequest req,
  ) async {
    final group = config.groupById(groupId);
    if (group == null || group.destinations.isEmpty) {
      // A group the desk lists but gave no network destination (a Windows
      // printer): the phone cannot print it, so the desk must.
      return _GroupResult(groupId, false, 'no network printer');
    }
    final doc = buildSlip(config, group, lines, req);
    final outcomes = await Future.wait(<Future<LanPrintResult>>[
      for (final dest in group.destinations)
        _safePrint(dest, doc),
    ]);
    // The desk's 'all' mode: a group counts as printed only if EVERY one of its
    // destinations took the slip. A partial success is reported failed, so the
    // desk reprints the group (possibly a duplicate on the printer that worked,
    // never a missing slip in the kitchen).
    for (final r in outcomes) {
      if (!r.ok) return _GroupResult(groupId, false, r.error);
    }
    return _GroupResult(groupId, true, null);
  }

  Future<LanPrintResult> _safePrint(
      KotPrintDestination dest, EscposDoc doc) async {
    try {
      return await _printer.printDoc(dest, doc);
    } catch (e) {
      return LanPrintResult.failure('${dest.key} failed');
    }
  }
}

class _GroupResult {
  final String groupId;
  final bool ok;
  final String? error;
  const _GroupResult(this.groupId, this.ok, this.error);
}

/// Mints `offline_ref`s: `<4-char device code>-<counter>` (e.g. `A7Q2-014`).
///
/// The counter lives in SharedPreferences and only ever goes up, so refs from
/// one phone never repeat across restarts; the device code comes from a random
/// id generated once per install, so two phones' refs differ. Kitchen staff use
/// the ref to match the paper slip to the order that syncs later.
class OfflineRefGenerator {
  OfflineRefGenerator({math.Random? random}) : _random = random;

  static const String _idKey = 'offline_kot_device_id_v1';
  static const String _counterKey = 'offline_kot_counter_v1';

  /// No 0/O/1/I: the code is read off a paper slip.
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  final math.Random? _random;
  Future<void> _lock = Future<void>.value();

  /// The 4-char code for a persistent random [deviceId].
  static String deviceCode(String deviceId) {
    // FNV-1a over the id, 5 bits per character.
    var hash = 0x811c9dc5;
    for (final unit in deviceId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buffer.write(_alphabet[(hash >> (i * 5)) & 31]);
    }
    return buffer.toString();
  }

  /// `CODE-NNN` (the counter is at least three digits).
  static String format(String code, int counter) =>
      '$code-${counter.toString().padLeft(3, '0')}';

  Future<String> next() {
    final completer = Completer<String>();
    _lock = _lock.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        var id = prefs.getString(_idKey);
        if (id == null || id.isEmpty) {
          final rng = _random ?? math.Random.secure();
          id = List<String>.generate(
                  16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
              .join();
          await prefs.setString(_idKey, id);
        }
        final counter = (prefs.getInt(_counterKey) ?? 0) + 1;
        await prefs.setInt(_counterKey, counter);
        completer.complete(format(deviceCode(id), counter));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
