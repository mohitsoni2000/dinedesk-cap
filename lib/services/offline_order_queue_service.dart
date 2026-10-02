import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';
import 'kot_queue_service.dart';
import 'log.dart';
import 'socket_service.dart';

final Provider<OfflineOrderQueueService> offlineOrderQueueProvider =
    Provider<OfflineOrderQueueService>((ref) {
  final service = OfflineOrderQueueService(ref.read(kotQueueProvider));
  service.currentOperatorId = () => ref.read(operatorProvider)?.id;
  ref.read(kotQueueProvider).currentOperatorId = service.currentOperatorId;
  ref.onDispose(service.dispose);
  return service;
});

/// The background worker that keeps the outbox draining. See
/// [OutboxDrainWorker].
final Provider<OutboxDrainWorker> outboxDrainProvider =
    Provider<OutboxDrainWorker>((ref) {
  final worker = OutboxDrainWorker(
    socket: ref.read(socketServiceProvider),
    orders: ref.read(offlineOrderQueueProvider),
    kots: ref.read(kotQueueProvider),
    onPending: (count, tableIds) {
      ref.read(outboxPendingCountProvider.notifier).state = count;
      ref.read(pendingTableIdsProvider.notifier).state = tableIds;
    },
  );
  ref.onDispose(worker.dispose);
  return worker;
});

/// An order submission that was dropped from the local queue without ever
/// reaching the desk — either it sat offline longer than [OfflineOrderQueueService.maxAge]
/// or the queue was full. Mirrors [RejectedKot]: same "don't fail silently"
/// principle, kept as its own type since an order+KOT drop is a different
/// event than a bare KOT rejection.
class RejectedOrderSubmission {
  final String reason;
  final DateTime rejectedAt;

  const RejectedOrderSubmission(
      {required this.reason, required this.rejectedAt});
}

enum OrderSubmitOutcome { sent, queued, rejected }

/// Result of [OfflineOrderQueueService.submitOrder]. When [outcome] is
/// [OrderSubmitOutcome.queued], neither the order nor its KOT have actually
/// reached the desk yet — [orderAck]/[kotAck] are empty placeholders, not
/// real server responses. The caller must not read an order_id out of a
/// queued result; there isn't one yet.
class OrderSubmitResult {
  final OrderSubmitOutcome outcome;
  final Map<String, dynamic> orderAck;
  final Map<String, dynamic> kotAck;

  const OrderSubmitResult(this.outcome, this.orderAck, this.kotAck);

  bool get isSent => outcome == OrderSubmitOutcome.sent;
  bool get isQueued => outcome == OrderSubmitOutcome.queued;
  bool get isRejected => outcome == OrderSubmitOutcome.rejected;
}

/// Queues "create/update an order, then send its KOT" as one unit so a
/// waiter offline never has to wait or watch it fail — the whole submission
/// is replayed in order once the desk is reachable again.
///
/// This is deliberately scoped to the non-money order+KOT flow only. Bill
/// generation and payment always wait for a live connection
/// (SocketService.emitAckWhenConnected already does that) — an offline
/// device must never complete a payment or generate a bill it cannot
/// immediately confirm with the desk.
///
/// Mirrors [KotQueueService]'s proven persistence pattern (same
/// SharedPreferences-backed FIFO queue, same _synchronized lock, same
/// transport-failure detection) rather than inventing a new one — that
/// queue has already been exercised in production for kot:send.
class OfflineOrderQueueService {
  static const String _queueKey = 'pending_order_submissions_v1';
  static const String _tag = '[OfflineOrder]';

  /// Matches KotQueueService.maxAge — an order submission stale enough that
  /// the table/menu state it was built against is no longer trustworthy
  /// should surface to a human, not fire silently hours later.
  static const Duration maxAge = Duration(hours: 2);

  static const int maxQueued = 100;
  static const Duration _sendTimeout = Duration(seconds: 8);

  final KotQueueService _kotQueue;
  OfflineOrderQueueService(this._kotQueue);

  final ReauthGate _gate = ReauthGate();

  /// See [ReauthGate.onReauthRequired].
  set onReauthRequired(Future<bool> Function()? hook) {
    _gate.onReauthRequired = hook;
    _kotQueue.onReauthRequired = hook;
  }

  /// Fired when a PIN prompt this queue raised was answered.
  set onUnpaused(void Function()? hook) => _gate.onUnpaused = hook;

  bool get isPaused => _gate.isPaused;

  /// Clears a reauth pause (a new verified session).
  void resume() => _gate.resume();

  /// The signed-in operator's id. Entries are stamped with it, and one queued
  /// under somebody else is dead-lettered instead of replayed under the wrong
  /// login. Wired by [offlineOrderQueueProvider].
  String? Function()? currentOperatorId;

  /// Fired after the persisted queue changes (the drain worker mirrors it into
  /// providers for the UI).
  void Function()? onChanged;

  Future<void> _lock = Future<void>.value();
  Future<void>? _flushFuture;

  final StreamController<RejectedOrderSubmission> _rejections =
      StreamController<RejectedOrderSubmission>.broadcast();

  Stream<RejectedOrderSubmission> get rejections => _rejections.stream;

  void _reportDropped(String reason) {
    logE(_tag, reason);
    if (!_rejections.isClosed) {
      _rejections.add(
        RejectedOrderSubmission(reason: reason, rejectedAt: DateTime.now()),
      );
    }
  }

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

  Future<List<Map<String, dynamic>>> _readRaw() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_queueKey) ?? const <String>[];
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

  Future<void> _writeRaw(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _queueKey,
      items.map(jsonEncode).toList(growable: false),
    );
    onChanged?.call();
  }

  Future<int> pendingCount() =>
      _synchronized(() async => (await _readRaw()).length);

  /// Table/room ids that have an order waiting in the outbox, for the "queued"
  /// badge on their cards.
  Future<Set<String>> pendingTableIds() => _synchronized(() async {
        final ids = <String>{};
        for (final entry in await _readRaw()) {
          final id = entry['table_id'];
          if (id is String && id.isNotEmpty) ids.add(id);
        }
        return ids;
      });

  /// Submits an order create/update, then its KOT, as one unit. If the
  /// socket isn't verified right now, queues the whole thing and returns
  /// immediately — the caller should treat [OrderSubmitResult.isQueued] the
  /// same way it already treats a queued bare KOT: tell the waiter it will
  /// fire automatically, and move on. Never blocks waiting for a
  /// reconnect — that's what makes this different from
  /// [SocketService.emitAckWhenConnected], which is still correct for the
  /// money-handling paths that must not proceed without a live desk.
  Future<OrderSubmitResult> submitOrder(
    SocketService socket, {
    required String orderEvent,
    required Map<String, dynamic> orderPayload,
    required String orderRequestId,
    required String kotRequestId,
    String? tableId,
    BeforeQueueHook? beforeQueue,
  }) async {
    final stampedOrder = <String, dynamic>{
      ...orderPayload,
      'client_request_id': orderRequestId,
    };
    final slot = tableId ??
        (orderPayload['table_id'] ?? orderPayload['room_id'])?.toString();

    if (socket.state != SocketState.verified) {
      await _enqueue(orderEvent, stampedOrder, kotRequestId, slot,
          beforeQueue: beforeQueue);
      return const OrderSubmitResult(OrderSubmitOutcome.queued, {}, {});
    }

    final drained = await flush(socket);
    if (!drained) {
      await _enqueue(orderEvent, stampedOrder, kotRequestId, slot,
          beforeQueue: beforeQueue);
      return const OrderSubmitResult(OrderSubmitOutcome.queued, {}, {});
    }

    return _attempt(
      socket,
      orderEvent,
      stampedOrder,
      kotRequestId,
      slot,
      enqueueOnTransportFailure: true,
      beforeQueue: beforeQueue,
    );
  }

  /// One send of an order submission (the order, then its KOT).
  ///
  /// [enqueueOnTransportFailure] is true only for a brand-new submission that
  /// has no queue entry yet ([submitOrder]). The flush replays an entry that
  /// is *already* the head of the queue, so a transport failure there must
  /// leave it exactly where it is: this used to enqueue it again while the
  /// flush also kept the head, and the order was then sent twice.
  Future<OrderSubmitResult> _attempt(
    SocketService socket,
    String orderEvent,
    Map<String, dynamic> stampedOrder,
    String kotRequestId,
    String? slot, {
    required bool enqueueOnTransportFailure,
    Map<String, dynamic> kotExtra = const <String, dynamic>{},
    BeforeQueueHook? beforeQueue,
  }) async {
    final orderAck =
        await socket.emitAck(orderEvent, stampedOrder, timeout: _sendTimeout);

    if (orderAck['kind'] == 'error') {
      final reauth = isReauthRequired(orderAck);
      if (isTransportFailure(orderAck) || reauth) {
        if (reauth) _gate.trip();
        if (enqueueOnTransportFailure) {
          await _enqueue(orderEvent, stampedOrder, kotRequestId, slot,
              beforeQueue: beforeQueue);
        }
        return const OrderSubmitResult(OrderSubmitOutcome.queued, {}, {});
      }
      return OrderSubmitResult(OrderSubmitOutcome.rejected, orderAck, const {});
    }

    final orderId = _orderIdFrom(orderAck);
    if (orderId == null) {
      return OrderSubmitResult(OrderSubmitOutcome.rejected, orderAck, const {});
    }

    // [kotExtra] is what a queued entry carried from the moment it was parked
    // (the direct-print marker): it must reach the desk on the KOT even though
    // the KOT is only built here, once the order has an id.
    final kotResult = await _kotQueue.sendKot(
      socket,
      <String, dynamic>{...kotExtra, 'order_id': orderId},
      clientRequestId: kotRequestId,
      beforeQueue: beforeQueue,
    );

    if (kotResult.isQueued) {
      // The order itself is real and safely on the desk — only the KOT
      // needs to catch up, and KotQueueService already owns that from here.
      return OrderSubmitResult(
          OrderSubmitOutcome.sent, orderAck, kotResult.ack);
    }
    if (kotResult.isRejected) {
      return OrderSubmitResult(
          OrderSubmitOutcome.rejected, orderAck, kotResult.ack);
    }
    return OrderSubmitResult(OrderSubmitOutcome.sent, orderAck, kotResult.ack);
  }

  String? _orderIdFrom(Map<String, dynamic> ack) {
    final order = ack['order'];
    if (order is Map) {
      final id = order['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    final id = ack['order_id'] ?? ack['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  Future<void> _enqueue(
    String orderEvent,
    Map<String, dynamic> stampedOrder,
    String kotRequestId,
    String? slot, {
    BeforeQueueHook? beforeQueue,
  }) async {
    // Outside the lock: printing to a LAN printer can take seconds and every
    // other queue operation (the UI's pending count) waits on the lock.
    final kotExtra = await runBeforeQueueHook(beforeQueue);
    await _synchronized(() async {
      final items = await _readRaw();
      if (items.length >= maxQueued) {
        const reason = 'Order queue full ($maxQueued pending) — oldest dropped';
        _reportDropped(reason);
        final oldest = items.removeAt(0);
        final oldestPayload = oldest['order_payload'];
        await _kotQueue.quarantineExternal(
          <String, dynamic>{
            'order_event': oldest['order_event'],
            if (oldest['table_id'] != null) 'table_id': oldest['table_id'],
            if (oldestPayload is Map) 'order_payload': oldestPayload,
          },
          reason,
        );
      }
      items.add(<String, dynamic>{
        'order_event': orderEvent,
        'order_payload': stampedOrder,
        'kot_request_id': kotRequestId,
        'queued_at': DateTime.now().toIso8601String(),
        'operator_id': currentOperatorId?.call(),
        if (slot != null && slot.isNotEmpty) 'table_id': slot,
        // Rides to the replay's kot:send (see _attempt).
        if (kotExtra.isNotEmpty) 'kot_extra': kotExtra,
      });
      await _writeRaw(items);
      logD(_tag, 'queued order submission (${items.length} pending)');
    });
  }

  /// Replays queued order submissions in order. Returns true once the queue
  /// is empty (including "was already empty"), false if it stopped early
  /// because the desk went unreachable again mid-flush.
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
        final items = await _readRaw();
        return items.isEmpty ? null : items.first;
      });
      if (next == null) return true;

      final orderEvent = next['order_event']?.toString();
      final rawPayload = next['order_payload'];
      final kotRequestId = next['kot_request_id']?.toString();
      if (orderEvent == null || rawPayload is! Map || kotRequestId == null) {
        await _dropHead();
        continue;
      }
      final payload = Map<String, dynamic>.from(rawPayload);
      final slot = next['table_id']?.toString();
      final rawExtra = next['kot_extra'];
      final kotExtra = rawExtra is Map
          ? Map<String, dynamic>.from(rawExtra)
          : const <String, dynamic>{};

      final queuedAt = DateTime.tryParse(next['queued_at']?.toString() ?? '');
      if (queuedAt != null && DateTime.now().difference(queuedAt) > maxAge) {
        await _deadLetter(
          payload,
          orderEvent,
          slot,
          'Order was offline more than ${maxAge.inHours}h and was not sent — check the table and re-place it if needed',
        );
        continue;
      }

      // Queued under another operator: replaying it now would attribute the
      // order to whoever is signed in. Hand it to a human instead.
      final queuedBy = next['operator_id'];
      final current = currentOperatorId?.call();
      if (queuedBy is String &&
          current != null &&
          current.isNotEmpty &&
          queuedBy != current) {
        await _deadLetter(
          payload,
          orderEvent,
          slot,
          'Order was queued under a different operator and was not sent — check the table and re-place it if needed',
        );
        continue;
      }

      if (socket.state != SocketState.verified) return false;

      final result = await _attempt(
        socket,
        orderEvent,
        payload,
        kotRequestId,
        slot,
        enqueueOnTransportFailure: false,
        kotExtra: kotExtra,
      );
      // Desk unreachable, or PIN needed (queue is now paused): the entry is
      // still the head, untouched. Stop here and let the drain worker retry.
      if (result.isQueued) return false;
      if (result.isRejected) {
        final orderFailed = result.orderAck['kind'] == 'error';
        final message =
            (orderFailed ? result.orderAck : result.kotAck)['message']
                    ?.toString() ??
                'Rejected by the desk';
        if (orderFailed) {
          await _deadLetter(
            payload,
            orderEvent,
            slot,
            'Order was refused by the desk: $message',
          );
        } else {
          // The order is on the desk; only its KOT was refused.
          final orderId = _orderIdFrom(result.orderAck);
          _reportDropped('KOT for a queued order was refused: $message');
          await _kotQueue.quarantineExternal(
            <String, dynamic>{
              if (orderId != null) 'order_id': orderId,
              if (slot != null) 'table_id': slot,
            },
            'KOT refused by the desk: $message',
          );
          await _dropHead();
        }
        continue;
      }
      await _dropHead();
    }
  }

  /// Takes the head entry out of the queue for good, but never silently: the
  /// toast says so, and the order lands in the same dead-letter store (and
  /// RejectedKotsBanner) a refused KOT does, so someone re-places it by hand.
  Future<void> _deadLetter(
    Map<String, dynamic> payload,
    String orderEvent,
    String? slot,
    String reason,
  ) async {
    _reportDropped(reason);
    await _kotQueue.quarantineExternal(
      <String, dynamic>{
        'order_event': orderEvent,
        if (slot != null) 'table_id': slot,
        if (payload['order_id'] != null) 'order_id': payload['order_id'],
        'order_payload': payload,
      },
      reason,
    );
    await _dropHead();
  }

  Future<void> _dropHead() => _synchronized(() async {
        final items = await _readRaw();
        if (items.isEmpty) return;
        items.removeAt(0);
        await _writeRaw(items);
      });

  void dispose() {
    unawaited(_rejections.close());
  }
}

/// Keeps the outbox (queued order submissions + KOTs) draining without anyone
/// having to trigger it.
///
/// The queues themselves only flush when something calls them, and the only
/// callers used to be "a resync just succeeded" and "a new item was queued" —
/// so a flush that failed halfway (the link dropped again, a send timed out)
/// simply stopped, and the rest of the queue sat there until the next lucky
/// resync. This worker:
///
/// - flushes on every transition into `verified`;
/// - while items are still pending and the socket is verified but a flush
///   failed, retries with exponential backoff (2s, 4s, 8s … capped at 60s) plus
///   jitter, so a struggling link isn't hammered and a fleet of phones that
///   reconnect together doesn't retry in lockstep;
/// - mirrors the queue size and the tables that have a queued order into the
///   UI (the "N queued" pill and the per-table "queued" badge).
class OutboxDrainWorker {
  OutboxDrainWorker({
    required this.socket,
    required this.orders,
    required this.kots,
    this.onPending,
    this.baseDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 60),
    math.Random? random,
  }) : _random = random ?? math.Random();

  final SocketService socket;
  final OfflineOrderQueueService orders;
  final KotQueueService kots;

  /// Called with (total pending items, table ids with a queued order).
  final void Function(int count, Set<String> tableIds)? onPending;

  final Duration baseDelay;
  final Duration maxDelay;
  final math.Random _random;

  StreamSubscription<void>? _verifiedSub;
  Timer? _retryTimer;
  Future<void>? _running;
  int _failures = 0;
  bool _started = false;
  bool _disposed = false;

  int get consecutiveFailures => _failures;

  void start() {
    if (_started) return;
    _started = true;
    _verifiedSub = socket.verifiedStream.listen((_) {
      // A new verified session is fresh PIN evidence, and a fresh start for
      // the backoff.
      orders.resume();
      kots.resume();
      _failures = 0;
      unawaited(kick());
    });
    orders.onChanged = () => unawaited(refresh());
    kots.onChanged = () => unawaited(refresh());
    // A PIN prompt answered: the queues may run again straight away.
    orders.onUnpaused = () => unawaited(kick());
    kots.onUnpaused = () => unawaited(kick());
    // Show whatever survived an app restart.
    unawaited(refresh());
    if (socket.state == SocketState.verified) unawaited(kick());
  }

  /// Recomputes the UI mirror from the persisted queues.
  Future<void> refresh() async {
    if (_disposed) return;
    final count = await orders.pendingCount() + await kots.pendingCount();
    final tables = await orders.pendingTableIds();
    if (!_disposed) onPending?.call(count, tables);
  }

  /// Flush now (single-flight). On failure with work remaining, schedules the
  /// next backoff retry.
  Future<void> kick() {
    if (_disposed) return Future<void>.value();
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (socket.state != SocketState.verified) return;
    var ok = false;
    try {
      final ordersDone = await orders.flush(socket);
      final kotsDone = await kots.flush(socket);
      ok = ordersDone && kotsDone;
    } catch (err, stack) {
      logE('[Outbox]', 'drain failed', err, stack);
    }
    await refresh();
    if (_disposed) return;
    if (ok) {
      _failures = 0;
      return;
    }
    final pending = await orders.pendingCount() + await kots.pendingCount();
    if (pending == 0) {
      _failures = 0;
      return;
    }
    _scheduleRetry();
  }

  /// 2s, 4s, 8s … max 60s, each stretched by up to 25% jitter.
  /// Exposed for tests.
  Duration backoffFor(int failures) {
    final exp = baseDelay.inMilliseconds * math.pow(2, failures).toInt();
    final capped = math.min(exp, maxDelay.inMilliseconds);
    final jitter = (capped * 0.25 * _random.nextDouble()).round();
    return Duration(milliseconds: capped + jitter);
  }

  void _scheduleRetry() {
    final delay = backoffFor(_failures);
    _failures++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      // Not verified: the next `verified` event kicks us; nothing to retry.
      if (socket.state == SocketState.verified) unawaited(kick());
    });
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    unawaited(_verifiedSub?.cancel());
  }
}
