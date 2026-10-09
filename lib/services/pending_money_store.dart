/// Money attempts the desk may have taken without saying so: an unanswered
/// Pay & Fire (`pending_checkout_v1`) and an unanswered ticket sale
/// (`pending_issue_v1`), kept in SharedPreferences.
///
/// An attempt is written to the phone BEFORE it is sent and removed only
/// once the desk has answered it for certain (or the cashier dropped it on
/// purpose). A crash, a restart or a sign-out while the desk is answering
/// therefore cannot lose its `client_request_id`: whenever the retry comes,
/// it is the same request, and the desk replays its answer instead of
/// charging twice.
///
/// One key per kind holds `{schema: 1, attempts: {...}}`, one attempt per
/// operator per desk ([ParkedScope]). An operator only ever sees their own:
/// the desk replays by operator (another operator's retry would charge
/// again), and a ticket sale names its guest. A value this app cannot read is
/// moved aside to `<key>.unreadable` by the next write, never deleted.
///
/// The desk replays an id for [kDeskReplayWindow]; an attempt older than that
/// can no longer be retried safely and is not offered again.
///
/// Logs say what happened, never what an attempt holds or whose it is.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/parked_draft.dart' show ParkedScope;
import 'log.dart';
import 'prefs_aside.dart';

const String _tag = '[Pending]';

/// How long the desk replays an answer for a `client_request_id`
/// (electron/server/idempotency.ts, IDEMPOTENCY_TTL_HOURS). After that a
/// resend is a new charge, not a replay.
const Duration kDeskReplayWindow = Duration(hours: 48);

/// A money attempt kept until the desk has answered it for certain.
abstract interface class PendingMoney {
  String get clientRequestId;

  /// Whose it is: the operator who sent it, on the desk it went to. Only
  /// they see it or retry it.
  ParkedScope get scope;

  Map<String, dynamic> toJson();
}

/// One kind's kept attempts on the phone. The app reaches each through its
/// provider; every read-modify-write of one store runs inside its lock.
class PendingMoneyStore {
  PendingMoneyStore(this.prefsKey, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const String checkoutKey = 'pending_checkout_v1';
  static const String issueKey = 'pending_issue_v1';
  static const int schema = 1;

  final String prefsKey;
  final DateTime Function() _now;

  Future<void> _lock = Future<void>.value();
  bool _saidUnreadable = false;

  Future<T> _synchronized<T>(Future<T> Function() action) {
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

  /// The slot of [scope]'s attempt: its desk and operator, unambiguous
  /// whatever characters the ids hold.
  static String _slot(ParkedScope scope) =>
      jsonEncode(<String>[scope.deskInstanceId, scope.operatorId]);

  /// The stored attempts by slot; empty when nothing is stored; null when
  /// what is stored is not ours to read (moved aside by the next write).
  Map<String, Object?>? _decode(SharedPreferences prefs) {
    final Object? raw = prefs.get(prefsKey);
    if (raw == null) return <String, Object?>{};
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map &&
            decoded['schema'] == schema &&
            decoded['attempts'] is Map) {
          return Map<String, Object?>.from(decoded['attempts'] as Map);
        }
      } on FormatException {
        // Not JSON: unreadable, below.
      }
    }
    if (!_saidUnreadable) {
      _saidUnreadable = true;
      logD(
          _tag,
          '$prefsKey holds something this app cannot read — left as it '
          'is until the next write moves it aside');
    }
    return null;
  }

  /// [scope]'s attempt and when it was written, or null when there is none.
  Future<({Map<String, dynamic> attempt, DateTime? savedAt})?> read(
          ParkedScope scope) =>
      _synchronized(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final entry = _decode(prefs)?[_slot(scope)];
          if (entry is! Map) return null;
          final attempt = entry['attempt'];
          if (attempt is! Map) return null;
          final savedAt = entry['saved_at'];
          return (
            attempt: Map<String, dynamic>.from(attempt),
            savedAt: savedAt is String ? DateTime.tryParse(savedAt) : null,
          );
        } catch (error) {
          logE(_tag, 'could not read $prefsKey', error.runtimeType);
          return null;
        }
      });

  /// Saves [attempt] as [scope]'s, replacing the one it had. False when the
  /// phone could not keep it.
  Future<bool> write(ParkedScope scope, Map<String, dynamic> attempt) =>
      _synchronized(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          var attempts = _decode(prefs);
          if (attempts == null) {
            if (!await keepAside(prefs, prefsKey)) {
              logE(_tag, 'could not move an unreadable $prefsKey aside');
              return false;
            }
            logD(_tag,
                'moved an unreadable $prefsKey aside (kept on the phone)');
            _saidUnreadable = false;
            attempts = <String, Object?>{};
          }
          attempts[_slot(scope)] = <String, Object?>{
            'saved_at': _now().toUtc().toIso8601String(),
            'attempt': attempt,
          };
          final saved = await _save(prefs, attempts);
          if (!saved) logE(_tag, 'could not write $prefsKey');
          return saved;
        } catch (error) {
          logE(_tag, 'could not write $prefsKey', error.runtimeType);
          return false;
        }
      });

  /// Removes [scope]'s attempt if it is still the one with
  /// [clientRequestId]; a newer attempt is never touched.
  Future<void> remove(ParkedScope scope, String clientRequestId) =>
      _synchronized(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final attempts = _decode(prefs);
          if (attempts == null) return;
          final slot = _slot(scope);
          final entry = attempts[slot];
          final attempt = entry is Map ? entry['attempt'] : null;
          if (attempt is! Map ||
              attempt['client_request_id'] != clientRequestId) {
            return;
          }
          attempts.remove(slot);
          if (!await _save(prefs, attempts)) {
            logE(_tag, 'could not clear an answered attempt from $prefsKey');
          }
        } catch (error) {
          logE(_tag, 'could not update $prefsKey', error.runtimeType);
        }
      });

  Future<bool> _save(SharedPreferences prefs, Map<String, Object?> attempts) =>
      attempts.isEmpty
          ? prefs.remove(prefsKey)
          : prefs.setString(
              prefsKey,
              jsonEncode(<String, Object?>{
                'schema': schema,
                'attempts': attempts,
              }));
}

/// The signed-in operator's kept attempt of one kind, as the screens see it:
/// read back from the phone when they sign in (after a restart, a crash or a
/// sign-out), and only ever theirs. Nothing is deleted when the operator
/// changes; the attempt waits on the phone for its operator.
class PendingMoneyNotifier<T extends PendingMoney> extends StateNotifier<T?> {
  PendingMoneyNotifier(
    this._store,
    this._scope, {
    required T Function(Map<String, dynamic> json) restore,
    required String what,
    DateTime Function()? now,
  })  : _restore = restore,
        _what = what,
        _now = now ?? DateTime.now,
        super(null) {
    final scope = _scope;
    if (scope != null) unawaited(_load(scope));
  }

  final PendingMoneyStore _store;
  final ParkedScope? _scope;
  final T Function(Map<String, dynamic> json) _restore;
  final String _what;
  final DateTime Function() _now;

  /// Set once this session held or settled an attempt: a slow read of the
  /// phone must not undo that.
  bool _touched = false;

  Future<void> _load(ParkedScope scope) async {
    final stored = await _store.read(scope);
    if (stored == null || !mounted || _touched) return;
    final T attempt;
    try {
      attempt = _restore(stored.attempt);
    } catch (error) {
      logE(_tag, 'a kept $_what could not be read back', error.runtimeType);
      return;
    }
    if (attempt.scope != scope) return;
    final savedAt = stored.savedAt;
    if (savedAt != null && _now().difference(savedAt) > kDeskReplayWindow) {
      // The desk no longer replays it: a retry would be a new charge.
      logD(
          _tag,
          'a kept $_what is past the desk\'s replay window — not '
          'offered again');
      await _store.remove(scope, attempt.clientRequestId);
      return;
    }
    if (!mounted || _touched) return;
    state = attempt;
    logD(_tag, 'a kept $_what is back for its operator');
  }

  /// Writes [attempt] to the phone. Call it BEFORE [attempt] is sent: a
  /// crash, a restart or a sign-out while the desk is answering then cannot
  /// lose its id. What the screens show does not change.
  Future<void> writeAhead(T attempt) async {
    if (attempt.scope.operatorId.isEmpty) return;
    if (!await _store.write(attempt.scope, attempt.toJson())) {
      logE(
          _tag,
          'a $_what could not be written ahead; it is sent all the '
          'same');
    }
  }

  /// The desk did not answer [attempt] (or refused it without proving that
  /// nothing happened): show it, kept for the retry. It stays on the phone.
  void hold(T attempt) {
    _touched = true;
    if (mounted && _isOurs(attempt)) state = attempt;
    // Written ahead already; again in case that write failed.
    unawaited(writeAhead(attempt));
  }

  /// [attempt] belongs on this screen: it was sent under this scope (or,
  /// with nobody known to have sent it, there is no scope either).
  bool _isOurs(T attempt) {
    final scope = _scope;
    return scope == null
        ? attempt.scope.operatorId.isEmpty
        : attempt.scope == scope;
  }

  /// The desk answered [attempt] for certain, or the cashier dropped it on
  /// purpose: forget it on screen and on the phone.
  Future<void> settle(T attempt) async {
    _touched = true;
    if (mounted && state?.clientRequestId == attempt.clientRequestId) {
      state = null;
    }
    if (attempt.scope.operatorId.isEmpty) return;
    await _store.remove(attempt.scope, attempt.clientRequestId);
  }
}
