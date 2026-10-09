import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'log.dart';

const String _tag = '[Snapshot]';

/// The file under the app-support directory. Versioned in the name: a future
/// incompatible layout gets a new file instead of a migration.
const String offlineSnapshotFileName = 'offline_snapshot_v1.json.gz';

const int offlineSnapshotSchema = 1;

/// Everything the phone needs to look like the desk's data when it cold-starts
/// with the desk unreachable: menu, orders in flight, flags, the desk's KOT
/// print routing and PIN policy. Floors / tables / rooms are NOT here — they
/// already live in [FloorCache] and this deliberately doesn't duplicate it.
///
/// Every desk-sourced field is kept RAW (the desk's own JSON): hydration then
/// goes through the same parsers as a live sync, so the two can't drift.
class OfflineSnapshot {
  final DateTime savedAt;

  /// The desk this was captured from; a snapshot of another desk is discarded.
  final String? deskInstanceId;
  final Map<String, dynamic>? restaurantInfo;
  final Map<String, dynamic>? featureFlags;
  final Map<String, dynamic>? menu;
  final String? menuVersion;
  final Map<String, dynamic>? fastAdd;
  final List<Map<String, dynamic>> offers;
  final List<Map<String, dynamic>> activeOrders;
  final Map<String, List<String>> linkGroups;
  final Map<String, dynamic>? kotPrintConfig;
  final Map<String, dynamic>? sessionPolicy;

  /// table / room server id -> floor id, so a KOT printed offline can be routed
  /// by floor (the cached tables only carry the floor's NAME).
  final Map<String, String> slotFloorIds;

  /// The desk's `qsr_config`, so a cold start offline still opens the Counter
  /// on a QSR desk. Absent in a file from before QSR (= restaurant mode); an
  /// older app ignores the key, so the schema stays 1.
  final Map<String, dynamic>? qsrConfig;

  const OfflineSnapshot({
    required this.savedAt,
    this.deskInstanceId,
    this.restaurantInfo,
    this.featureFlags,
    this.menu,
    this.menuVersion,
    this.fastAdd,
    this.offers = const <Map<String, dynamic>>[],
    this.activeOrders = const <Map<String, dynamic>>[],
    this.linkGroups = const <String, List<String>>{},
    this.kotPrintConfig,
    this.sessionPolicy,
    this.slotFloorIds = const <String, String>{},
    this.qsrConfig,
  });

  /// The PIN grace in the stored `session_policy`; a missing policy is 0
  /// (fail closed), same as on a live sync.
  int get pinGraceMinutes {
    final raw = sessionPolicy?['pin_grace_minutes'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  /// Everything except the menu, as JSON-ready data. The menu travels
  /// separately (see [OfflineSnapshotStore]) so it need not be re-encoded when
  /// only the orders changed.
  Map<String, dynamic> headerJson() => <String, dynamic>{
        'schema': offlineSnapshotSchema,
        'saved_at': savedAt.toUtc().toIso8601String(),
        'desk_instance_id': deskInstanceId,
        'restaurant_info': restaurantInfo,
        'feature_flags': featureFlags,
        'menu_version': menuVersion,
        'fast_add': fastAdd,
        'offers': offers,
        'active_orders': activeOrders,
        'link_groups': linkGroups,
        'kot_print_config': kotPrintConfig,
        'session_policy': sessionPolicy,
        'slot_floor_ids': slotFloorIds,
        'qsr_config': qsrConfig,
      };

  static OfflineSnapshot? fromJson(Map<String, dynamic> json) {
    if (json['schema'] != offlineSnapshotSchema) return null;
    final savedAt = DateTime.tryParse(json['saved_at']?.toString() ?? '');
    if (savedAt == null) return null;
    return OfflineSnapshot(
      savedAt: savedAt.toUtc(),
      deskInstanceId: json['desk_instance_id']?.toString(),
      restaurantInfo: _map(json['restaurant_info']),
      featureFlags: _map(json['feature_flags']),
      menu: _map(json['menu']),
      menuVersion: json['menu_version']?.toString(),
      fastAdd: _map(json['fast_add']),
      offers: _maps(json['offers']),
      activeOrders: _maps(json['active_orders']),
      linkGroups: _linkGroups(json['link_groups']),
      kotPrintConfig: _map(json['kot_print_config']),
      sessionPolicy: _map(json['session_policy']),
      slotFloorIds: _strings(json['slot_floor_ids']),
      qsrConfig: _map(json['qsr_config']),
    );
  }

  static Map<String, dynamic>? _map(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : null;

  static List<Map<String, dynamic>> _maps(Object? raw) => raw is List
      ? <Map<String, dynamic>>[
          for (final e in raw)
            if (e is Map) Map<String, dynamic>.from(e),
        ]
      : const <Map<String, dynamic>>[];

  static Map<String, List<String>> _linkGroups(Object? raw) {
    final out = <String, List<String>>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is List) out[k.toString()] = v.map((e) => e.toString()).toList();
      });
    }
    return out;
  }

  static Map<String, String> _strings(Object? raw) => raw is Map
      ? <String, String>{
          for (final e in raw.entries) e.key.toString(): e.value.toString(),
        }
      : const <String, String>{};
}

/// Reads and writes the snapshot: one gzip'd JSON file, written atomically
/// (tmp + rename) so a kill mid-write leaves the previous good file, and
/// encoded/decoded off the UI thread.
class OfflineSnapshotStore {
  /// [directory] overrides the app-support directory (tests).
  OfflineSnapshotStore({Directory? directory}) : _directory = directory;

  final Directory? _directory;

  /// The menu's JSON text from the last save and the exact map it was encoded
  /// from: a save that only moves the orders reuses it instead of re-encoding a
  /// ~300KB map every few seconds. Keyed on the map's identity (not on
  /// `menu_version`, which a `menu:updated` broadcast may leave unchanged while
  /// the content moves): a changed menu is always a new map.
  String? _menuJson;
  Map<String, dynamic>? _menuSource;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    if (!dir.existsSync()) await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$offlineSnapshotFileName');
  }

  /// Saves run strictly one after another: they share one tmp file, and a
  /// live sync's save can overlap the debounced orders save or a `menu:updated`
  /// save. (Two writers on one tmp file would have the second rename fail.)
  Future<void> _saves = Future<void>.value();

  /// Completes once every save queued so far is written. The app fires saves
  /// and forgets them; tests await this before deleting the snapshot folder.
  @visibleForTesting
  Future<void> get idle => _saves;

  /// Writes [snapshot]. Never throws: a snapshot that can't be written costs
  /// nothing but the offline cold start it was for.
  Future<void> save(OfflineSnapshot snapshot) {
    final run = _saves.then((_) => _write(snapshot));
    _saves = run;
    return run;
  }

  Future<void> _write(OfflineSnapshot snapshot) async {
    try {
      final menu = snapshot.menu;
      String? menuJson;
      if (menu != null) {
        if (identical(menu, _menuSource) && _menuJson != null) {
          menuJson = _menuJson;
        } else {
          menuJson = jsonEncode(menu);
          _menuJson = menuJson;
          _menuSource = menu;
        }
      }
      final gz = await _runIsolate<List<int>>(
        _encodeSnapshot,
        _EncodeArgs(jsonEncode(snapshot.headerJson()), menuJson),
      );
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(gz, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      logD(_tag, 'save failed: $e');
    }
  }

  /// The stored snapshot, or null when there is none, it is unreadable, or it
  /// was captured from a different desk than [deskInstanceId] (a phone re-paired
  /// elsewhere must not show another restaurant's menu and orders). An
  /// unreadable or foreign file is deleted so it isn't re-parsed every launch.
  Future<OfflineSnapshot?> load({String? deskInstanceId}) async {
    File? file;
    try {
      file = await _file();
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final decoded =
          await _runIsolate<Map<String, dynamic>?>(_decodeSnapshot, bytes);
      final snapshot = decoded == null ? null : OfflineSnapshot.fromJson(decoded);
      if (snapshot == null) {
        logD(_tag, 'unreadable snapshot — discarded');
        await _deleteQuietly(file);
        return null;
      }
      if (deskInstanceId != null &&
          snapshot.deskInstanceId != deskInstanceId) {
        logD(_tag, 'snapshot belongs to another desk — discarded');
        await _deleteQuietly(file);
        return null;
      }
      return snapshot;
    } catch (e) {
      logD(_tag, 'load failed: $e');
      if (file != null) await _deleteQuietly(file);
      return null;
    }
  }

  Future<void> clear() async {
    _menuJson = null;
    _menuSource = null;
    try {
      await _deleteQuietly(await _file());
    } catch (_) {}
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}

class _EncodeArgs {
  final String headerJson;
  final String? menuJson;
  const _EncodeArgs(this.headerJson, this.menuJson);
}

/// `compute`, falling back to running inline where isolates aren't available
/// (some test environments), as the menu parser does.
Future<R> _runIsolate<R>(FutureOr<R> Function(Object) fn, Object arg) async {
  try {
    return await compute<Object, R>(fn, arg);
  } catch (e) {
    logD(_tag, 'isolate unavailable ($e) — running inline');
    return await fn(arg);
  }
}

List<int> _encodeSnapshot(Object arg) {
  final args = arg as _EncodeArgs;
  var json = args.headerJson;
  final menu = args.menuJson;
  if (menu != null) {
    // Splice the pre-encoded menu in as the last key of the header object.
    json = '${json.substring(0, json.length - 1)},"menu":$menu}';
  }
  return gzip.encode(utf8.encode(json));
}

Map<String, dynamic>? _decodeSnapshot(Object arg) {
  try {
    final text = utf8.decode(gzip.decode(arg as List<int>));
    final decoded = jsonDecode(text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}
