import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';
import 'escpos_builder.dart';
import 'lan_printer_service.dart';
import 'log.dart';
import 'offline_kot_printer.dart';

const String _tag = '[OfflineKot]';

/// "Print KOT directly when desk is offline" — SharedPreferences, default ON.
class DirectKotPrintSetting {
  DirectKotPrintSetting._();

  static const String key = 'setting_direct_kot_print';

  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}

final Provider<LanPrinter> lanPrinterProvider =
    Provider<LanPrinter>((_) => LanPrinterService());

final Provider<OfflineRefGenerator> offlineRefGeneratorProvider =
    Provider<OfflineRefGenerator>((_) => OfflineRefGenerator());

final Provider<OfflineKotCoordinator> offlineKotCoordinatorProvider =
    Provider<OfflineKotCoordinator>((ref) => OfflineKotCoordinator(ref));

/// What one emergency-print attempt did, for the queue and the UI.
class OfflineKotAttempt {
  /// False when direct printing wasn't tried at all (setting off, no config
  /// from the desk, nothing to print).
  final bool attempted;
  final OfflineKotOutcome? outcome;

  /// Fields to persist INTO the queued KOT payload. Empty unless something
  /// actually printed: the desk must print a KOT normally when nothing did.
  final Map<String, dynamic> fields;

  const OfflineKotAttempt({
    required this.attempted,
    this.outcome,
    this.fields = const <String, dynamic>{},
  });

  static const OfflineKotAttempt skipped = OfflineKotAttempt(attempted: false);

  bool get printedAnything => outcome?.anyPrinted ?? false;

  /// The line the operator sees once the KOT has been queued. Null when no
  /// direct print was attempted (the usual "queued" message then stands).
  String? get message {
    if (!attempted) return null;
    if (printedAnything) {
      final partial = outcome!.failedGroupIds.isNotEmpty
          ? ' (some stations could not print — the desk will print those)'
          : '';
      return 'Printed on kitchen printer directly · will sync when the '
          'desk is back$partial';
    }
    return 'Could not print — will print when the desk is back';
  }
}

/// item id -> category id, read off the desk's raw menu payload. The cart's
/// [MenuItem] only keeps the category NAME, but print-group routing keys on the
/// id. Handles both menu shapes the parser accepts (flat `items` with a
/// `category_id`, or `categories[].items[]`).
Map<String, String> categoryIdsByItem(Map<String, dynamic> rawMenu) {
  final out = <String, String>{};
  final items = rawMenu['items'];
  if (items is List) {
    for (final it in items) {
      if (it is! Map) continue;
      final id = it['id']?.toString();
      final cat = it['category_id']?.toString();
      if (id != null && id.isNotEmpty && cat != null && cat.isNotEmpty) {
        out[id] = cat;
      }
    }
    return out;
  }
  final categories = rawMenu['categories'];
  if (categories is List) {
    for (final c in categories) {
      if (c is! Map) continue;
      final catId = c['id']?.toString();
      final nested = c['items'];
      if (catId == null || catId.isEmpty || nested is! List) continue;
      for (final it in nested) {
        if (it is! Map) continue;
        final id = it['id']?.toString();
        if (id != null && id.isNotEmpty) out[id] = catId;
      }
    }
  }
  return out;
}

/// Gathers everything the emergency slip needs from app state and prints it.
/// The pure routing/printing lives in [OfflineKotPrinter]; this is the thin
/// adapter between it and the providers.
class OfflineKotCoordinator {
  OfflineKotCoordinator(this._ref);

  final Ref _ref;

  /// Tries to put [cart] on the kitchen's LAN printers. Never throws.
  ///
  /// [slotId] is the table's / room's server id; [isRoom] and [isTakeaway]
  /// pick the order type the routing filters on.
  Future<OfflineKotAttempt> printForQueuedKot({
    required List<CartLine> cart,
    required String slotId,
    required bool isRoom,
    bool isTakeaway = false,
    String? orderNotes,
  }) async {
    try {
      if (cart.isEmpty) return OfflineKotAttempt.skipped;
      final config = _ref.read(kotPrintConfigProvider);
      if (config == null || !config.hasDestinations) {
        return OfflineKotAttempt.skipped;
      }
      if (!await DirectKotPrintSetting.isEnabled()) {
        return OfflineKotAttempt.skipped;
      }

      final categories = categoryIdsByItem(_ref.read(rawMenuDataProvider));
      final lines = <OfflineKotLine>[
        for (final l in cart)
          OfflineKotLine(
            itemId: l.item.id,
            categoryId: categories[l.item.id],
            slip: _slipItem(l),
          ),
      ];

      String tableName = '';
      String? floorName;
      if (isRoom) {
        for (final r in _ref.read(roomsProvider)) {
          if (r.serverId == slotId) {
            tableName = r.id;
            break;
          }
        }
      } else if (!isTakeaway) {
        for (final t in _ref.read(tablesProvider)) {
          if (t.serverId == slotId) {
            tableName = t.id;
            floorName = t.floor;
            break;
          }
        }
      }

      final operator = _ref.read(operatorProvider);
      final now = DateTime.now();
      final ref = await _ref.read(offlineRefGeneratorProvider).next();
      final printer = OfflineKotPrinter(printer: _ref.read(lanPrinterProvider));
      final outcome = await printer.print(
        config,
        OfflineKotRequest(
          lines: lines,
          orderType: isRoom ? 'room' : (isTakeaway ? 'takeaway' : 'dine_in'),
          floorId: _ref.read(slotFloorIdsProvider)[slotId],
          floorName: floorName,
          tableName: tableName,
          slotLabel: isRoom ? 'Room' : (isTakeaway ? 'Takeaway' : 'Table'),
          orderNotes: orderNotes,
          operatorName: operator?.name ?? '',
          offlineRef: ref,
          at: now,
        ),
      );
      return OfflineKotAttempt(
        attempted: true,
        outcome: outcome,
        fields: outcome.toPayloadFields(now),
      );
    } catch (e, st) {
      logE(_tag, 'direct print failed', e, st);
      return OfflineKotAttempt.skipped;
    }
  }

  KotSlipItem _slipItem(CartLine l) => KotSlipItem(
        name: l.item.name,
        quantity: l.qty,
        variationName: l.variationName,
        options: <String>[for (final o in l.selectedOptions) o.optionName],
        addons: <({String group, List<String> choices})>[
          for (final g in l.selectedAddons)
            (
              group: g.groupName,
              choices: <String>[for (final c in g.choices) c.name],
            ),
        ],
        notes: l.itemNote.trim().isEmpty ? null : l.itemNote.trim(),
        weight: l.weight,
        weightUnit: l.weight == null ? null : l.item.measureUnit,
      );
}
