/// The phone's parked carts and parked ticket sales ("Hold & Resume"), kept in
/// SharedPreferences under ONE key, `parked_drafts_v1`:
/// `{schema: 1, drafts: [...]}`.
///
/// Each draft is stamped with the operator and the desk it was parked under
/// and is only ever handed back to that scope; everyone else's stay on disk,
/// untouched. The rules, all pinned by test/parked_drafts_store_test.dart:
///
/// - **Cap:** 20 drafts per kind per operator (per desk). The 21st is REFUSED
///   with [ParkedCapReached]; nothing is ever evicted to make room.
/// - **Retention:** drafts older than [maxAge] are pruned, from every scope.
/// - **Never delete what we cannot read.** An entry that is corrupt, or of a
///   kind this app does not know, is skipped and logged but written back as it
///   was. A whole envelope from another schema (or not JSON at all) shows
///   nothing and is left as it is by reads, resumes and discards; the next
///   park moves it aside to `parked_drafts_v1.unreadable` (kept on the phone)
///   and starts a fresh envelope, so it can never block parking for good.
/// - **Labels:** the Nth draft of a kind an operator parks on an IST day is
///   "P<N>"; the count starts again each IST day.
///
/// Every read-modify-write runs inside one lock ([_synchronized], the pattern
/// of KotQueueService), so parks racing each other cannot lose a draft.
///
/// Logs say counts and kinds, never what is in a draft or whose it is.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/ist_time.dart';
import '../models/parked_draft.dart';
import 'log.dart';
import 'prefs_aside.dart';

const String _tag = '[Parked]';

/// Something the cashier should be told about, in words fit to show.
class ParkedDraftsException implements Exception {
  const ParkedDraftsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An operator already has [ParkedDraftsStore.maxPerKind] drafts of [kind].
final class ParkedCapReached extends ParkedDraftsException {
  ParkedCapReached(this.kind, this.limit)
      : super('You already have $limit parked ${kind.plural}. '
            'Resume or discard one first.');

  final ParkedKind kind;
  final int limit;
}

/// The app reaches it through `parkedDraftsStoreProvider`; nothing else
/// should construct one. The lock is shared by every instance all the same,
/// so a second store could not race the first.
class ParkedDraftsStore {
  ParkedDraftsStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String prefsKey = 'parked_drafts_v1';
  static const int schema = 1;

  /// Per kind, per operator (and desk).
  static const int maxPerKind = 20;
  static const Duration maxAge = Duration(days: 7);

  final DateTime Function() _now;
  final Random _random = Random();

  /// The last thing said about what could not be read: said again only when
  /// it changes, not on every read.
  String? _lastNote;

  /// One lock for the one key, whatever the instance: two stores each with
  /// their own lock would bring back the lost update it exists to prevent.
  ///
  /// It is a chain of futures, kept for one zone. A call from another zone
  /// starts the chain afresh: a future made in a zone that is gone (in tests,
  /// a finished test's fake clock) would never run its callbacks here. The
  /// app runs in a single zone, so every store shares one chain.
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

  /// Parks [payload] for [scope] and returns the draft, with its label.
  ///
  /// Throws [ParkedCapReached] at the cap, and [ParkedDraftsException] when
  /// there is nothing to park or the phone could not save it. In every case
  /// nothing was parked.
  Future<ParkedDraft> park(ParkedScope scope, ParkedPayload payload) =>
      _synchronized(() async {
        if (payload.isEmpty) {
          throw const ParkedDraftsException('There is nothing to park.');
        }
        var stored = await _load();
        if (!stored.readable) {
          // Kept, out of the way: what this app cannot read must not block
          // parking for good, and is never deleted.
          if (!await keepAside(stored.prefs, prefsKey)) {
            throw ParkedDraftsException(
                "Couldn't save the parked ${payload.kind.noun} on this phone. "
                'Try again.');
          }
          logD(
              _tag, 'moved unreadable parked drafts aside (kept on the phone)');
          _lastNote = null;
          stored = _Stored(stored.prefs, <_Entry>[]);
        }
        final now = _now();
        final mine = stored.drafts
            .where((d) => d.scope == scope && d.kind == payload.kind)
            .toList();
        if (mine.length >= maxPerKind) {
          // The prune stands even though the park does not.
          if (stored.expired > 0) await _save(stored);
          throw ParkedCapReached(payload.kind, maxPerKind);
        }
        final draft = ParkedDraft(
          id: _freshId(stored, now),
          scope: scope,
          createdAt: now.toUtc(),
          seq: _nextSeq(mine, now),
          payload: payload,
        );
        stored.add(draft);
        if (!await _save(stored)) {
          throw ParkedDraftsException(
              "Couldn't save the parked ${payload.kind.noun} on this phone. "
              'Try again.');
        }
        logD(_tag, 'parked ${draft.kind.name} (${mine.length + 1} held)');
        return draft;
      });

  /// [scope]'s drafts, oldest first (the order they were parked in), or just
  /// those of [kind]. Anything past [maxAge] is pruned first.
  Future<List<ParkedDraft>> list(ParkedScope scope, {ParkedKind? kind}) =>
      _synchronized(() async {
        final stored = await _load();
        if (stored.expired > 0) await _save(stored);
        return <ParkedDraft>[
          for (final d in stored.drafts)
            if (d.scope == scope && (kind == null || d.kind == kind)) d,
        ];
      });

  /// Takes the draft out of the store and returns it (a resume); null when
  /// [scope] has no such draft, for example because another counter took it.
  Future<ParkedDraft?> take(ParkedScope scope, String id) =>
      _remove(scope, id, 'resumed');

  /// Throws the draft away; false when [scope] has no such draft.
  Future<bool> discard(ParkedScope scope, String id) async =>
      await _remove(scope, id, 'discarded') != null;

  Future<ParkedDraft?> _remove(ParkedScope scope, String id, String verb) =>
      _synchronized(() async {
        final stored = await _load();
        if (!stored.readable) return null;
        final draft = stored.drafts
            .where((d) => d.id == id && d.scope == scope)
            .firstOrNull;
        if (draft == null) {
          if (stored.expired > 0) await _save(stored);
          return null;
        }
        stored.remove(draft);
        if (!await _save(stored)) {
          throw const ParkedDraftsException(
              "Couldn't update the parked drafts on this phone. Try again.");
        }
        final left = stored.drafts
            .where((d) => d.scope == scope && d.kind == draft.kind)
            .length;
        logD(_tag, '$verb ${draft.kind.name} ($left left)');
        return draft;
      });

  /// One more than the highest number handed out today (IST) among [mine], so
  /// a number is never shared by two drafts that are both still parked.
  int _nextSeq(List<ParkedDraft> mine, DateTime now) {
    final today = istDateOf(now);
    var highest = 0;
    for (final d in mine) {
      if (d.seq > highest && istDateOf(d.createdAt) == today) highest = d.seq;
    }
    return highest + 1;
  }

  String _freshId(_Stored stored, DateTime now) {
    final taken = stored.ids;
    while (true) {
      final id = 'pk_${now.microsecondsSinceEpoch}_'
          '${_random.nextInt(1 << 30).toRadixString(16)}';
      if (!taken.contains(id)) return id;
    }
  }

  /// What is on disk, sorted into what this app understands and what it
  /// only keeps. Expired drafts are dropped from the result (and so from disk
  /// at the next [_save]); everything else is carried through as it was.
  Future<_Stored> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final Object? text = prefs.get(prefsKey);
    if (text == null) {
      _note(null);
      return _Stored(prefs, <_Entry>[]);
    }
    if (text is! String) {
      _note('the stored parked drafts are not text — left untouched');
      return _Stored.unreadable(prefs);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      _note('the stored parked drafts are not JSON — left untouched');
      return _Stored.unreadable(prefs);
    }
    if (decoded is! Map || decoded['schema'] != schema) {
      final found = decoded is Map ? decoded['schema'] : null;
      _note('parked drafts use schema ${found is int ? found : 'unknown'}, '
          'this app reads schema $schema — left untouched');
      return _Stored.unreadable(prefs);
    }
    final rawEntries = decoded['drafts'];
    if (rawEntries is! List) {
      _note('the stored parked drafts have no list — left untouched');
      return _Stored.unreadable(prefs);
    }

    final now = _now();
    final entries = <_Entry>[];
    var unknown = 0;
    var unreadable = 0;
    var expired = 0;
    for (final raw in rawEntries) {
      if (raw is! Map) {
        unreadable++;
        entries.add(_Entry(raw));
        continue;
      }
      final entry = Map<String, dynamic>.from(raw);
      final name = entry['kind'];
      if (ParkedKind.fromName(name) == null) {
        if (name is String && name.isNotEmpty) {
          unknown++;
        } else {
          unreadable++;
        }
        entries.add(_Entry(raw));
        continue;
      }
      try {
        final draft = ParkedDraft.fromJson(entry);
        if (now.difference(draft.createdAt) > maxAge) {
          expired++;
          continue;
        }
        entries.add(_Entry(raw, draft));
      } catch (_) {
        unreadable++;
        entries.add(_Entry(raw));
      }
    }
    _note(unknown + unreadable > 0
        ? 'skipped $unknown of an unknown kind and $unreadable unreadable '
            '(left on disk)'
        : null);
    if (expired > 0) logD(_tag, 'pruned $expired expired');
    return _Stored(prefs, entries)..expired = expired;
  }

  /// Logs [note] about what could not be read, once: not again until it
  /// changes (null: everything was read).
  void _note(String? note) {
    if (note == _lastNote) return;
    _lastNote = note;
    if (note != null) logD(_tag, note);
  }

  /// Writes [stored] back: every entry it carries, readable or not, in order.
  /// False when the platform refused; the cache is then re-read so the phone
  /// does not show what it failed to keep.
  Future<bool> _save(_Stored stored) async {
    final text = jsonEncode(<String, Object?>{
      'schema': schema,
      'drafts': <Object?>[for (final e in stored.entries) e.raw],
    });
    final saved = await stored.prefs.setString(prefsKey, text);
    if (!saved) {
      logE(_tag, 'could not write the parked drafts');
      try {
        await stored.prefs.reload();
      } catch (_) {}
    }
    return saved;
  }
}

/// One entry of the stored list: what is on disk, and the draft it makes when
/// this app can read it.
class _Entry {
  _Entry(this.raw, [this.draft]);

  final Object? raw;
  final ParkedDraft? draft;
}

class _Stored {
  _Stored(this.prefs, this.entries) : readable = true;

  _Stored.unreadable(this.prefs)
      : readable = false,
        entries = <_Entry>[];

  final SharedPreferences prefs;

  /// False when the stored value is not an envelope this app may rewrite.
  final bool readable;
  final List<_Entry> entries;

  /// Drafts past their time that [ParkedDraftsStore._load] left out of
  /// [entries]; a [ParkedDraftsStore._save] makes the prune real.
  int expired = 0;

  Iterable<ParkedDraft> get drafts =>
      entries.map((e) => e.draft).whereType<ParkedDraft>();

  /// Every `id` on disk, readable or not.
  Set<Object?> get ids => <Object?>{
        for (final e in entries)
          if (e.raw is Map) (e.raw! as Map)['id'],
      };

  void add(ParkedDraft draft) => entries.add(_Entry(draft.toJson(), draft));

  /// Takes out exactly [draft]'s entry, never another that merely shares its
  /// id (a stranger's draft is not ours to remove).
  void remove(ParkedDraft draft) =>
      entries.removeWhere((e) => identical(e.draft, draft));
}
