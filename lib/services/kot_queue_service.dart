import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log.dart';
import 'socket_service.dart';

/// Offline-first KOT pipeline.
///
/// WiFi blips are a fact of restaurant life, so a `kot:send` that can't reach
/// the desk is persisted and flushed the moment the socket is verified again.
///
/// The previous version inverted that promise. `SocketService.emitAck` never
/// throws — it *returns* `{'kind': 'error'}` — so the `catch { break; }` guard
/// was unreachable for a dropped connection, and the flush loop fell through
/// to `items.removeAt(0)` on every path. A mid-flush disconnect therefore
/// **deleted the queued KOT from disk permanently**, while the waiter's screen
/// still said it would fire on reconnect. Three things changed:
///
///  1. Transport failure and desk rejection are now distinguished
///     ([isTransportFailure]). Transport failure keeps the item and stops.
///  2. A desk rejection *quarantines* the KOT in a dead-letter list and
///     notifies the app. Nothing is ever silently dropped.
///  3. Every read-modify-write of the queue holds a mutex. `_enqueue` and
///     `_doFlush` previously raced, and the flush rewrote a stale snapshot —
///     erasing any KOT queued while it ran.
final Provider<KotQueueService> kotQueueProvider =
    Provider<KotQueueService>((ref) {
  final service = KotQueueService();
  ref.onDispose(service.dispose);
  return service;
});

/// A KOT the desk actively refused. Held for the operator to see and re-fire
/// or discard by hand — never deleted behind their back.
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
      rejectedAt:
          DateTime.tryParse(json['rejected_at']?.toString() ?? '') ??
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

class KotQueueService {
  static const String _queueKey = 'pending_kots_v2';
  static const String _deadLetterKey = 'rejected_kots_v1';
  static const String _tag = '[KotQueue]';

  /// A KOT older than this is stale — the covers have long since left. It is
  /// quarantined rather than fired blind into the kitchen.
  static const Duration maxAge = Duration(hours: 2);

  /// Hard cap so a phone left offline overnight can't fill its storage.
  static const int maxQueued = 200;

  static const Duration _sendTimeout = Duration(seconds: 8);

  /// Serialises every read-modify-write of the on-disk queue.
  Future<void> _lock = Future<void>.value();

  Future<void>? _flushFuture;

  final StreamController<RejectedKot> _rejections =
      StreamController<RejectedKot>.broadcast();

  /// Fires whenever the desk refuses a queued KOT. The UI must surface this;
  /// a KOT that never reaches the kitchen is not allowed to be invisible.
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

  // ---------------------------------------------------------------------
  // Storage (all callers must hold the lock)
  // ---------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _readRaw(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(key) ?? const <String>[];
    final out = <Map<String, dynamic>>[];
    for (final entry in raw) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map) out.add(Map<String, dynamic>.from(decoded));
      } catch (error) {
        // A corrupt row is itself a lost KOT — say so rather than dropping
        // it into a `.where(isNotEmpty)` filter as the old code did.
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
  }

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

  // ---------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------

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

  /// Sends a KOT now if the desk is reachable, otherwise queues it durably.
  ///
  /// [clientRequestId] must be **stable across retries of the same round**.
  /// The old code minted a fresh id inside this method, so a waiter re-tapping
  /// "Send KOT" after a timeout produced a second id the desk could not
  /// recognise as a duplicate — and a second KOT in the kitchen.
  Future<KotSendResult> sendKot(
    SocketService socket,
    Map<String, dynamic> payload, {
    required String clientRequestId,
  }) async {
    final stamped = <String, dynamic>{
      ...payload,
      'client_request_id': clientRequestId,
    };

    if (socket.state != SocketState.verified) {
      await _enqueue(stamped);
      return KotSendResult(
        KotSendOutcome.queued,
        <String, dynamic>{'kind': 'queued'},
      );
    }

    // Older rounds must reach the kitchen before this one. If the queue
    // could not be drained, this round joins the back of it rather than
    // jumping the line — the previous version sent anyway, so round 3 could
    // hit the tandoor before round 2.
    final drained = await flush(socket);
    if (!drained) {
      await _enqueue(stamped);
      return KotSendResult(
        KotSendOutcome.queued,
        <String, dynamic>{'kind': 'queued'},
      );
    }

    final ack = await socket.emitAck(
      'kot:send',
      stamped,
      timeout: _sendTimeout,
    );

    if (ack['kind'] != 'error') return KotSendResult(KotSendOutcome.sent, ack);

    if (isTransportFailure(ack)) {
      await _enqueue(stamped);
      return KotSendResult(
        KotSendOutcome.queued,
        <String, dynamic>{'kind': 'queued'},
      );
    }

    // The desk understood us and said no. Do not queue a retry of something
    // it has already refused; hand it back to the caller to show.
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
        });
        await _writeRaw(_queueKey, items);
        logD(_tag, 'queued KOT (${items.length} pending)');
      });

  /// Fires every pending KOT, oldest first.
  ///
  /// Returns true only when the queue is genuinely empty afterwards. A caller
  /// that needs ordering guarantees must check this.
  Future<bool> flush(SocketService socket) {
    if (socket.state != SocketState.verified) return Future<bool>.value(false);
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

      if (socket.state != SocketState.verified) return false;

      final ack = await socket.emitAck(
        'kot:send',
        payload,
        timeout: _sendTimeout,
      );

      if (ack['kind'] == 'error') {
        if (isTransportFailure(ack)) {
          // Still unreachable. Keep everything and try again next time.
          logD(_tag, 'flush paused — desk unreachable');
          return false;
        }
        final message = ack['message']?.toString().toLowerCase() ?? '';
        final isDuplicate =
            message.contains('duplicate') || message.contains('already');
        if (isDuplicate) {
          // Already applied on a previous attempt. Safe to drop.
          await _dropHead(null);
          continue;
        }
        await _synchronized(() async {
          await _quarantine(
            payload,
            ack['message']?.toString() ?? 'Rejected by the desk',
          );
          final items = await _readRaw(_queueKey);
          if (items.isNotEmpty) {
            items.removeAt(0);
            await _writeRaw(_queueKey, items);
          }
        });
        continue;
      }

      await _dropHead(null);
    }
  }

  /// Removes the head of the queue. Removal happens *by position under the
  /// lock*, so a KOT enqueued while the network call was in flight is never
  /// clobbered by a stale snapshot.
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
