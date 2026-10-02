import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log.dart';
import 'socket_service.dart';

final Provider<KotQueueService> kotQueueProvider =
    Provider<KotQueueService>((ref) {
  final service = KotQueueService();
  ref.onDispose(service.dispose);
  return service;
});

/// The desk wants the operator's PIN again before it accepts anything. The
/// stable signal is `code: 'reauth_required'`; the message match covers a desk
/// build that predates the code.
bool isReauthRequired(Map<String, dynamic> ack) {
  if (ack['kind'] != 'error') return false;
  if (ack['code'] == 'reauth_required') return true;
  final message = ack['message']?.toString().toLowerCase() ?? '';
  return message.contains('pin verification required');
}

/// `kot:send` found nothing left to send: the KOT it was queued for already
/// reached the kitchen (an earlier attempt landed but its ack was lost). That
/// is success, not a rejection. The desk now sends `code: 'nothing_to_send'`;
/// older builds only have the message.
bool isNothingToSend(Map<String, dynamic> ack) {
  if (ack['kind'] != 'error') return false;
  if (ack['code'] == 'nothing_to_send') return true;
  final message = ack['message']?.toString().toLowerCase() ?? '';
  return message.contains('no pending items');
}

/// Pause/prompt state shared by the outbox queues for `reauth_required`.
///
/// A refused-for-PIN item is not a bad item: it must stay queued, untouched,
/// and the queue must stop hammering the desk until the operator has typed
/// their PIN. Quarantining it (what any other non-transport error does) would
/// throw away a perfectly good order over a lapsed session.
class ReauthGate {
  /// Asks the operator for their PIN; true once they have entered it.
  Future<bool> Function()? onReauthRequired;

  /// Called when the PIN was accepted and the queue may run again.
  void Function()? onUnpaused;

  bool _paused = false;
  bool _prompting = false;
  DateTime? _declinedAt;

  /// How long after a dismissed prompt a later flush may raise it again, so
  /// queued items can't be stranded behind one cancelled dialog.
  static const Duration reprompt = Duration(seconds: 60);

  bool get isPaused => _paused;

  /// True when a flush must not run right now.
  bool get blocksFlush {
    if (!_paused) return false;
    final declined = _declinedAt;
    if (!_prompting &&
        declined != null &&
        DateTime.now().difference(declined) > reprompt) {
      trip();
    }
    return true;
  }

  void trip() {
    _paused = true;
    if (_prompting) return;
    _prompting = true;
    unawaited(_prompt());
  }

  Future<void> _prompt() async {
    try {
      final ok = await (onReauthRequired?.call() ?? Future<bool>.value(false));
      if (ok) {
        _paused = false;
        _declinedAt = null;
        onUnpaused?.call();
      } else {
        _declinedAt = DateTime.now();
      }
    } catch (_) {
      _declinedAt = DateTime.now();
    } finally {
      _prompting = false;
    }
  }

  /// A fresh verified session is as good as a PIN prompt answered.
  void resume() {
    _paused = false;
    _declinedAt = null;
  }
}

class RejectedKot {
  final Map<String, dynamic> payload;
  final String reason;
  final DateTime rejectedAt;

  const RejectedKot({
    required this.payload,
    required this.reason,
    required this.rejectedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'payload': payload,
        'reason': reason,
        'rejected_at': rejectedAt.toIso8601String(),
      };

  static RejectedKot? fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    if (payload is! Map) return null;
    return RejectedKot(
      payload: Map<String, dynamic>.from(payload),
      reason: json['reason']?.toString() ?? 'Rejected by the desk',
      rejectedAt: DateTime.tryParse(json['rejected_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

enum KotSendOutcome { sent, queued, rejected }

class KotSendResult {
  final KotSendOutcome outcome;
  final Map<String, dynamic> ack;

  const KotSendResult(this.outcome, this.ack);

  bool get isSent => outcome == KotSendOutcome.sent;
  bool get isQueued => outcome == KotSendOutcome.queued;
  bool get isRejected => outcome == KotSendOutcome.rejected;

  String? get message => ack['message']?.toString();
}

/// Called right before a KOT is persisted to the outbox because the desk could
/// not take it. Whatever it returns is merged into the queued payload, so it
/// survives the replay — this is how a KOT that was printed straight to the
/// kitchen's LAN printer tells the desk (`printed_offline`, `offline_ref`,
/// `printed_at`, `failed_group_ids`) not to print it a second time. It may take
/// seconds (it talks to printers), so it runs outside the queue lock; it must
/// not throw (a throw is treated as "nothing to add").
typedef BeforeQueueHook = Future<Map<String, dynamic>> Function();

/// Runs [hook] for [KotQueueService] and [OfflineOrderQueueService] alike.
Future<Map<String, dynamic>> runBeforeQueueHook(BeforeQueueHook? hook) async {
  if (hook == null) return const <String, dynamic>{};
  try {
    return await hook();
  } catch (error) {
    logE('[KotQueue]', 'before-queue hook failed', error);
    return const <String, dynamic>{};
  }
}

class KotQueueService {
  static const String _queueKey = 'pending_kots_v2';
  static const String _deadLetterKey = 'rejected_kots_v1';
  static const String _tag = '[KotQueue]';

  static const Duration maxAge = Duration(hours: 2);

  static const int maxQueued = 200;

  static const Duration _sendTimeout = Duration(seconds: 8);

  Future<void> _lock = Future<void>.value();

  Future<void>? _flushFuture;

  final ReauthGate _gate = ReauthGate();

  /// See [ReauthGate.onReauthRequired].
  set onReauthRequired(Future<bool> Function()? hook) =>
      _gate.onReauthRequired = hook;

  /// Fired when a PIN prompt this queue raised was answered.
  set onUnpaused(void Function()? hook) => _gate.onUnpaused = hook;

  bool get isPaused => _gate.isPaused;

  /// Clears a reauth pause (a new verified session).
  void resume() => _gate.resume();

  /// The signed-in operator's id, for stamping entries and refusing to replay
  /// one queued under somebody else. Wired by SyncService.
  String? Function()? currentOperatorId;

  /// Fired after the persisted queue changes, so the UI can mirror its size.
  void Function()? onChanged;

  final StreamController<RejectedKot> _rejections =
      StreamController<RejectedKot>.broadcast();

  Stream<RejectedKot> get rejections => _rejections.stream;

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

  Future<List<Map<String, dynamic>>> _readRaw(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(key) ?? const <String>[];
    final out = <Map<String, dynamic>>[];
    for (final entry in raw) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map) out.add(Map<String, dynamic>.from(decoded));
      } catch (error) {
        logE(_tag, 'corrupt queue entry discarded', error);
      }
    }
    return out;
  }

  Future<void> _writeRaw(String key, List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      key,
      items.map(jsonEncode).toList(growable: false),
    );
    if (key == _queueKey) onChanged?.call();
  }

  /// Puts something that will never be sent into the same dead-letter store
  /// (and so the same RejectedKotsBanner) a refused KOT goes to. For the order
  /// queue, whose rejected orders used to vanish with only a toast.
  Future<void> quarantineExternal(
          Map<String, dynamic> payload, String reason) =>
      _synchronized(() => _quarantine(payload, reason));

  Future<void> _quarantine(
    Map<String, dynamic> payload,
    String reason,
  ) async {
    final rejected = RejectedKot(
      payload: payload,
      reason: reason,
      rejectedAt: DateTime.now(),
    );
    final existing = await _readRaw(_deadLetterKey);
    existing.add(rejected.toJson());
    await _writeRaw(_deadLetterKey, existing);
    logE(_tag, 'KOT quarantined: $reason');
    if (!_rejections.isClosed) _rejections.add(rejected);
  }

  Future<int> pendingCount() =>
      _synchronized(() async => (await _readRaw(_queueKey)).length);

  Future<List<RejectedKot>> rejectedKots() => _synchronized(() async {
        final rows = await _readRaw(_deadLetterKey);
        return rows
            .map(RejectedKot.fromJson)
            .whereType<RejectedKot>()
            .toList(growable: false);
      });

  Future<void> clearRejected() =>
      _synchronized(() => _writeRaw(_deadLetterKey, <Map<String, dynamic>>[]));

  Future<KotSendResult> sendKot(
    SocketService socket,
    Map<String, dynamic> payload, {
    required String clientRequestId,
    BeforeQueueHook? beforeQueue,
  }) async {
    final stamped = <String, dynamic>{
      ...payload,
      'client_request_id': clientRequestId,
    };

    // The one place a KOT is parked: [beforeQueue] gets its chance first (direct
    // printing), and what it adds is persisted WITH the entry.
    Future<KotSendResult> queue() async {
      final extra = await runBeforeQueueHook(beforeQueue);
      await _enqueue(<String, dynamic>{...stamped, ...extra});
      return const KotSendResult(
        KotSendOutcome.queued,
        <String, dynamic>{'kind': 'queued'},
      );
    }

    if (socket.state != SocketState.verified) return queue();

    // `await flush` first so older queued KOTs go out ahead of this one.
    final drained = await flush(socket);
    if (!drained) return queue();

    final ack = await socket.emitAck(
      'kot:send',
      stamped,
      timeout: _sendTimeout,
    );

    if (ack['kind'] != 'error') return KotSendResult(KotSendOutcome.sent, ack);

    if (isTransportFailure(ack) || isReauthRequired(ack)) {
      if (isReauthRequired(ack)) _gate.trip();
      return queue();
    }

    // The earlier attempt landed and only its ack was lost: already sent.
    if (isNothingToSend(ack)) return KotSendResult(KotSendOutcome.sent, ack);

    return KotSendResult(KotSendOutcome.rejected, ack);
  }

  Future<void> _enqueue(Map<String, dynamic> payload) =>
      _synchronized(() async {
        final items = await _readRaw(_queueKey);
        if (items.length >= maxQueued) {
          await _quarantine(payload, 'Queue full ($maxQueued pending)');
          return;
        }
        items.add(<String, dynamic>{
          'payload': payload,
          'queued_at': DateTime.now().toIso8601String(),
          'operator_id': currentOperatorId?.call(),
        });
        await _writeRaw(_queueKey, items);
        logD(_tag, 'queued KOT (${items.length} pending)');
      });

  Future<bool> flush(SocketService socket) {
    if (socket.state != SocketState.verified) return Future<bool>.value(false);
    if (_gate.blocksFlush) return Future<bool>.value(false);
    final existing = _flushFuture;
    if (existing != null) {
      return existing.then((_) => pendingCount().then((n) => n == 0));
    }
    final run = _doFlush(socket);
    _flushFuture = run.whenComplete(() => _flushFuture = null);
    return run;
  }

  Future<bool> _doFlush(SocketService socket) async {
    while (true) {
      final next = await _synchronized(() async {
        final items = await _readRaw(_queueKey);
        return items.isEmpty ? null : items.first;
      });
      if (next == null) return true;

      final rawPayload = next['payload'];
      if (rawPayload is! Map) {
        await _dropHead('Malformed queue entry');
        continue;
      }
      final payload = Map<String, dynamic>.from(rawPayload);

      final queuedAt = DateTime.tryParse(next['queued_at']?.toString() ?? '');
      if (queuedAt != null && DateTime.now().difference(queuedAt) > maxAge) {
        await _synchronized(() async {
          await _quarantine(
            payload,
            'Older than ${maxAge.inHours}h — not fired automatically',
          );
          final items = await _readRaw(_queueKey);
          if (items.isNotEmpty) {
            items.removeAt(0);
            await _writeRaw(_queueKey, items);
          }
        });
        continue;
      }

      // Queued under another operator: replaying it now would attribute it to
      // whoever is signed in. Dead-letter it for a human instead.
      final queuedBy = next['operator_id'];
      final current = currentOperatorId?.call();
      if (queuedBy is String &&
          current != null &&
          current.isNotEmpty &&
          queuedBy != current) {
        await _dropHead('Queued by a different operator — not sent');
        continue;
      }

      if (socket.state != SocketState.verified) return false;

      final ack = await socket.emitAck(
        'kot:send',
        payload,
        timeout: _sendTimeout,
      );

      if (ack['kind'] == 'error') {
        if (isTransportFailure(ack)) {
          logD(_tag, 'flush paused — desk unreachable');
          return false;
        }
        if (isReauthRequired(ack)) {
          logD(_tag, 'flush paused — the desk wants the PIN again');
          _gate.trip();
          return false;
        }
        if (isNothingToSend(ack)) {
          // Already on the kitchen's printer: this is the success path of a
          // retry whose first ack was lost. Drop quietly.
          await _dropHead(null);
          continue;
        }
        await _dropHead(ack['message']?.toString() ?? 'Rejected by the desk');
        continue;
      }

      await _dropHead(null);
    }
  }

  Future<void> _dropHead(String? quarantineReason) => _synchronized(() async {
        final items = await _readRaw(_queueKey);
        if (items.isEmpty) return;
        if (quarantineReason != null) {
          final payload = items.first['payload'];
          if (payload is Map) {
            await _quarantine(
              Map<String, dynamic>.from(payload),
              quarantineReason,
            );
          }
        }
        items.removeAt(0);
        await _writeRaw(_queueKey, items);
      });

  void dispose() {
    unawaited(_rejections.close());
  }
}
