/// The entry slips this phone owes the guests: one [SlipJob] per ticket,
/// kept in SharedPreferences under ONE key, `pending_slips_v1`:
/// `{schema: 1, jobs: [...]}`.
///
/// A sale's slips are written here before the printer is touched, and every
/// change of state is saved as it happens, so a printer that died, or an app
/// killed mid-print, never loses a slip. A job still "printing" when the app
/// comes back is shown as unknown: it may have printed, so it is offered
/// again with a duplicate warning.
///
/// Like the parked drafts, each job is stamped with the operator and the
/// desk it was made under and only ever shown to that scope. The rules,
/// pinned by test/pending_slips_store_test.dart:
///
/// - **Cap:** [maxJobs] in all. Past it the oldest printed jobs go first,
///   then the oldest of the rest (each is still reprintable from Recent).
/// - **Retention:** printed jobs are pruned [printedRetention] after they
///   printed. Unprinted ones stay until they print or are removed.
/// - **Unreadable entries** are carried through untouched; a whole envelope
///   this app cannot read is left alone and nothing new is saved over it.
///
/// Logs say counts and states, never a ticket number, code or guest.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/parked_providers.dart';
import '../models/entry_ticket.dart';
import '../models/parked_draft.dart';
import 'log.dart';
import 'slip_printer.dart';

const String _tag = '[Slips]';

/// Where one slip is.
enum SlipJobState {
  /// Saved, not sent to the printer yet (auto-print off).
  pending('pending'),

  /// Being sent right now, or the app stopped while it was ([SlipJob.isUnknown]).
  printing('printing'),
  printed('printed'),

  /// The printer did not take it.
  failed('failed');

  const SlipJobState(this.wire);
  final String wire;

  static SlipJobState? fromWire(Object? raw) {
    for (final v in values) {
      if (v.wire == raw) return v;
    }
    return null;
  }
}

/// One ticket's slip and how far it got.
class SlipJob {
  const SlipJob({
    required this.ticketId,
    required this.ticketNumber,
    required this.qrData,
    required this.scope,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.content,
    this.session,
  });

  final String ticketId;
  final String ticketNumber;
  final String qrData;
  final TicketSlipContent? content;
  final ParkedScope scope;
  final SlipJobState state;

  /// The app run that set [SlipJobState.printing]: another run's "printing"
  /// never finished as far as this one knows.
  final String? session;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Left "printing" by an app run that is gone: it may or may not have
  /// printed.
  bool get isUnknown =>
      state == SlipJobState.printing && session != PendingSlipsStore.session;

  /// Being printed by this app run right now.
  bool get isPrintingNow =>
      state == SlipJobState.printing && session == PendingSlipsStore.session;

  /// Still owed to the guest: not printed, and not on its way to the
  /// printer right now.
  bool get isUnprinted => state != SlipJobState.printed && !isPrintingNow;

  TicketSlip toSlip() => TicketSlip(
        ticketId: ticketId,
        ticketNumber: ticketNumber,
        qrData: qrData,
        content: content,
      );

  SlipJob _moved(SlipJobState next, DateTime at) => SlipJob(
        ticketId: ticketId,
        ticketNumber: ticketNumber,
        qrData: qrData,
        content: content,
        scope: scope,
        state: next,
        session: next == SlipJobState.printing ? PendingSlipsStore.session : null,
        createdAt: createdAt,
        updatedAt: at,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'ticket_id': ticketId,
        'ticket_number': ticketNumber,
        'qr_data': qrData,
        if (content != null) 'slip': _slipToJson(content!),
        'operator_id': scope.operatorId,
        'desk_instance_id': scope.deskInstanceId,
        'state': state.wire,
        if (session != null) 'session': session,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  /// Null for anything this app cannot read back.
  static SlipJob? fromJson(Map<String, dynamic> m) {
    final id = m['ticket_id'];
    final number = m['ticket_number'];
    final operator = m['operator_id'];
    final desk = m['desk_instance_id'];
    final state = SlipJobState.fromWire(m['state']);
    final created = DateTime.tryParse('${m['created_at']}');
    final updated = DateTime.tryParse('${m['updated_at']}');
    if (id is! String ||
        id.isEmpty ||
        number is! String ||
        operator is! String ||
        desk is! String ||
        state == null ||
        created == null ||
        updated == null) {
      return null;
    }
    final qr = m['qr_data'];
    final session = m['session'];
    return SlipJob(
      ticketId: id,
      ticketNumber: number,
      qrData: qr is String ? qr : '',
      content: TicketSlipContent.tryParse(m['slip']),
      scope: ParkedScope(operatorId: operator, deskInstanceId: desk),
      state: state,
      session: session is String ? session : null,
      createdAt: created,
      updatedAt: updated,
    );
  }
}

/// The wire shape `TicketSlipContent.tryParse` reads.
Map<String, Object?> _slipToJson(TicketSlipContent slip) => <String, Object?>{
      'header': slip.header,
      'ticket_no': slip.ticketNo,
      'title': slip.title,
      if (slip.highlight != null) 'highlight': slip.highlight,
      'lines': slip.lines,
      'footer': slip.footer,
      if (slip.qrData != null) 'qr_data': slip.qrData,
    };

/// The app reaches it through [pendingSlipsStoreProvider]. One lock for the
/// one key, shared by every instance (the parked store's pattern).
class PendingSlipsStore {
  PendingSlipsStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String prefsKey = 'pending_slips_v1';
  static const int schema = 1;
  static const int maxJobs = 200;
  static const Duration printedRetention = Duration(hours: 24);

  /// This app run. A job marked "printing" under another one is unknown.
  static final String session =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

  final DateTime Function() _now;

  static Future<void> _lock = Future<void>.value();
  static Zone? _lockZone;

  Future<T> _synchronized<T>(Future<T> Function() action) {
    if (!identical(_lockZone, Zone.current)) {
      _lockZone = Zone.current;
      _lock = Future<void>.value();
    }
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  /// [scope]'s jobs, oldest first. Printed jobs past their time are pruned
  /// first.
  Future<List<SlipJob>> list(ParkedScope scope) => _synchronized(() async {
        final stored = await _load();
        if (stored.pruned > 0) await _save(stored);
        return <SlipJob>[
          for (final job in stored.jobs)
            if (job.scope == scope) job,
        ];
      });

  /// Saves [slips] for [scope] in [state], one job per ticket: a ticket
  /// already here keeps its job (and when it was first saved) and only
  /// moves to [state]. False when nothing could be saved.
  Future<bool> put(
    ParkedScope scope,
    List<TicketSlip> slips,
    SlipJobState state,
  ) =>
      _synchronized(() async {
        if (slips.isEmpty) return true;
        final stored = await _load();
        if (!stored.readable) return false;
        final now = _now();
        for (final slip in slips) {
          final index = stored.indexOf(scope, slip.ticketId);
          if (index >= 0) {
            final old = stored.entries[index].job!;
            stored.replace(
                index,
                SlipJob(
                  ticketId: old.ticketId,
                  ticketNumber: slip.ticketNumber,
                  qrData: slip.qrData,
                  content: slip.content ?? old.content,
                  scope: scope,
                  state: state,
                  session: state == SlipJobState.printing ? session : null,
                  createdAt: old.createdAt,
                  updatedAt: now,
                ));
          } else {
            stored.add(SlipJob(
              ticketId: slip.ticketId,
              ticketNumber: slip.ticketNumber,
              qrData: slip.qrData,
              content: slip.content,
              scope: scope,
              state: state,
              session: state == SlipJobState.printing ? session : null,
              createdAt: now,
              updatedAt: now,
            ));
          }
        }
        stored.cap(maxJobs);
        final saved = await _save(stored);
        logD(_tag, '${slips.length} ${state.wire} (${stored.entries.length} kept)');
        return saved;
      });

  /// Records how a print run went for [scope]'s jobs.
  Future<bool> settle(
    ParkedScope scope, {
    required List<String> printed,
    required List<String> failed,
  }) =>
      _synchronized(() async {
        final stored = await _load();
        if (!stored.readable) return false;
        final now = _now();
        void move(List<String> ids, SlipJobState next) {
          for (final id in ids) {
            final index = stored.indexOf(scope, id);
            if (index < 0) continue;
            stored.replace(index, stored.entries[index].job!._moved(next, now));
          }
        }

        move(printed, SlipJobState.printed);
        move(failed, SlipJobState.failed);
        return _save(stored);
      });

  /// Takes [scope]'s jobs for [ticketIds] out (the usher gave up on them).
  Future<bool> remove(ParkedScope scope, List<String> ticketIds) =>
      _synchronized(() async {
        final stored = await _load();
        if (!stored.readable) return false;
        final before = stored.entries.length;
        stored.entries.removeWhere((e) =>
            e.job != null &&
            e.job!.scope == scope &&
            ticketIds.contains(e.job!.ticketId));
        if (stored.entries.length == before) return true;
        logD(_tag, 'removed ${before - stored.entries.length}');
        return _save(stored);
      });

  Future<_Stored> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final Object? text = prefs.get(prefsKey);
    if (text == null) return _Stored(prefs, <_Entry>[]);
    Object? decoded;
    if (text is String) {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
    }
    if (decoded is! Map ||
        decoded['schema'] != schema ||
        decoded['jobs'] is! List) {
      logD(_tag, 'stored slips are from another version — left untouched');
      return _Stored.unreadable(prefs);
    }
    final now = _now();
    final entries = <_Entry>[];
    var unreadable = 0;
    var pruned = 0;
    for (final raw in decoded['jobs'] as List) {
      final job = raw is Map ? SlipJob.fromJson(Map<String, dynamic>.from(raw)) : null;
      if (job == null) {
        unreadable++;
        entries.add(_Entry(raw));
        continue;
      }
      if (job.state == SlipJobState.printed &&
          now.difference(job.updatedAt) > printedRetention) {
        pruned++;
        continue;
      }
      entries.add(_Entry(raw, job));
    }
    if (unreadable > 0) logD(_tag, 'kept $unreadable unreadable as they were');
    if (pruned > 0) logD(_tag, 'pruned $pruned printed');
    return _Stored(prefs, entries)..pruned = pruned;
  }

  Future<bool> _save(_Stored stored) async {
    final text = jsonEncode(<String, Object?>{
      'schema': schema,
      'jobs': <Object?>[for (final e in stored.entries) e.raw],
    });
    final saved = await stored.prefs.setString(prefsKey, text);
    if (!saved) logE(_tag, 'could not save the slips');
    return saved;
  }
}

class _Entry {
  _Entry(this.raw, [this.job]);

  final Object? raw;
  final SlipJob? job;
}

class _Stored {
  _Stored(this.prefs, this.entries) : readable = true;

  _Stored.unreadable(this.prefs)
      : readable = false,
        entries = <_Entry>[];

  final SharedPreferences prefs;
  final bool readable;
  final List<_Entry> entries;
  int pruned = 0;

  Iterable<SlipJob> get jobs => entries.map((e) => e.job).whereType<SlipJob>();

  int indexOf(ParkedScope scope, String ticketId) => entries.indexWhere(
      (e) => e.job != null && e.job!.scope == scope && e.job!.ticketId == ticketId);

  void add(SlipJob job) => entries.add(_Entry(job.toJson(), job));

  void replace(int index, SlipJob job) =>
      entries[index] = _Entry(job.toJson(), job);

  /// Drops the oldest printed jobs, then the oldest of the rest, until at
  /// most [max] are left; equal times go in the order they were saved.
  /// Unreadable entries are never dropped here.
  void cap(int max) {
    var over = entries.length - max;
    if (over <= 0) return;
    for (final printedOnly in <bool>[true, false]) {
      final order = <_Entry, int>{
        for (var i = 0; i < entries.length; i++) entries[i]: i,
      };
      final candidates = entries
          .where((e) =>
              e.job != null &&
              (!printedOnly || e.job!.state == SlipJobState.printed))
          .toList()
        ..sort((a, b) {
          final byTime = a.job!.updatedAt.compareTo(b.job!.updatedAt);
          return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
        });
      for (final e in candidates) {
        if (over <= 0) break;
        entries.remove(e);
        over--;
      }
    }
    logD(_tag, 'over the cap: dropped the oldest');
  }
}

final pendingSlipsStoreProvider =
    Provider<PendingSlipsStore>((_) => PendingSlipsStore());

/// The current scope's slip jobs (signed-in operator on the paired desk),
/// oldest first. Printing and the slip queue go through here so every
/// screen follows.
final slipJobsProvider =
    StateNotifierProvider<SlipJobsNotifier, List<SlipJob>>((ref) =>
        SlipJobsNotifier(ref.watch(pendingSlipsStoreProvider),
            ref.watch(parkedScopeProvider)));

/// The slips still owed to guests (pending, failed, or unknown).
final unprintedSlipsProvider = Provider<List<SlipJob>>((ref) => <SlipJob>[
      for (final job in ref.watch(slipJobsProvider))
        if (job.isUnprinted) job,
    ]);

class SlipJobsNotifier extends StateNotifier<List<SlipJob>> {
  SlipJobsNotifier(this._store, this._scope) : super(const <SlipJob>[]) {
    if (_scope != null) unawaited(refresh());
  }

  final PendingSlipsStore _store;
  final ParkedScope? _scope;

  /// Reads the jobs again. Never throws.
  Future<void> refresh() async {
    final scope = _scope;
    if (scope == null) return;
    try {
      final jobs = await _store.list(scope);
      if (mounted) state = jobs;
    } catch (error) {
      logE(_tag, 'could not read the slips', error.runtimeType);
    }
  }

  /// Saves [slips] in [state]. Never throws: printing goes ahead even when
  /// the phone cannot keep a record of it.
  Future<void> record(List<TicketSlip> slips, SlipJobState state) =>
      _guard((scope) => _store.put(scope, slips, state));

  /// Records a print run's outcome. Never throws.
  Future<void> settle({
    required List<String> printed,
    required List<String> failed,
  }) =>
      _guard((scope) => _store.settle(scope, printed: printed, failed: failed));

  /// Forgets these slips. Never throws.
  Future<void> remove(List<String> ticketIds) =>
      _guard((scope) => _store.remove(scope, ticketIds));

  Future<void> _guard(Future<bool> Function(ParkedScope scope) write) async {
    final scope = _scope;
    if (scope == null) return;
    try {
      await write(scope);
    } catch (error) {
      logE(_tag, 'could not save the slips', error.runtimeType);
    }
    await refresh();
  }
}
