import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'kot_queue_service.dart';
import 'log.dart';
import 'socket_service.dart';

final Provider<OfflineOrderQueueService> offlineOrderQueueProvider =
    Provider<OfflineOrderQueueService>((ref) {
  final service = OfflineOrderQueueService(ref.read(kotQueueProvider));
  ref.onDispose(service.dispose);
  return service;
});

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

  Future<void> _lock = Future<void>.value();
  Future<void>? _flushFuture;

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
  }

  Future<int> pendingCount() =>
      _synchronized(() async => (await _readRaw()).length);

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
  }) async {
    final stampedOrder = <String, dynamic>{
      ...orderPayload,
      'client_request_id': orderRequestId,
    };

    if (socket.state != SocketState.verified) {
      await _enqueue(orderEvent, stampedOrder, kotRequestId);
      return const OrderSubmitResult(OrderSubmitOutcome.queued, {}, {});
    }

    final drained = await flush(socket);
    if (!drained) {
      await _enqueue(orderEvent, stampedOrder, kotRequestId);
      return const OrderSubmitResult(OrderSubmitOutcome.queued, {}, {});
    }

    return _attempt(socket, orderEvent, stampedOrder, kotRequestId);
  }

  Future<OrderSubmitResult> _attempt(
    SocketService socket,
    String orderEvent,
    Map<String, dynamic> stampedOrder,
    String kotRequestId,
  ) async {
    final orderAck =
        await socket.emitAck(orderEvent, stampedOrder, timeout: _sendTimeout);

    if (orderAck['kind'] == 'error') {
      if (isTransportFailure(orderAck)) {
        await _enqueue(orderEvent, stampedOrder, kotRequestId);
        return const OrderSubmitResult(OrderSubmitOutcome.queued, {}, {});
      }
      return OrderSubmitResult(OrderSubmitOutcome.rejected, orderAck, const {});
    }

    final orderId = _orderIdFrom(orderAck);
    if (orderId == null) {
      return OrderSubmitResult(OrderSubmitOutcome.rejected, orderAck, const {});
    }

    final kotResult = await _kotQueue.sendKot(
      socket,
      <String, dynamic>{'order_id': orderId},
      clientRequestId: kotRequestId,
    );

    if (kotResult.isQueued) {
      // The order itself is real and safely on the desk — only the KOT
      // needs to catch up, and KotQueueService already owns that from here.
      return OrderSubmitResult(OrderSubmitOutcome.sent, orderAck, kotResult.ack);
    }
    if (kotResult.isRejected) {
      return OrderSubmitResult(OrderSubmitOutcome.rejected, orderAck, kotResult.ack);
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
  ) =>
      _synchronized(() async {
        final items = await _readRaw();
        if (items.length >= maxQueued) {
          logE(_tag, 'queue full ($maxQueued pending) — dropping oldest');
          items.removeAt(0);
        }
        items.add(<String, dynamic>{
          'order_event': orderEvent,
          'order_payload': stampedOrder,
          'kot_request_id': kotRequestId,
          'queued_at': DateTime.now().toIso8601String(),
        });
        await _writeRaw(items);
        logD(_tag, 'queued order submission (${items.length} pending)');
      });

  /// Replays queued order submissions in order. Returns true once the queue
  /// is empty (including "was already empty"), false if it stopped early
  /// because the desk went unreachable again mid-flush.
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

      final queuedAt = DateTime.tryParse(next['queued_at']?.toString() ?? '');
      if (queuedAt != null && DateTime.now().difference(queuedAt) > maxAge) {
        logE(_tag,
            'dropping order submission older than ${maxAge.inHours}h — not fired automatically');
        await _dropHead();
        continue;
      }

      if (socket.state != SocketState.verified) return false;

      final result = await _attempt(socket, orderEvent, payload, kotRequestId);
      if (result.isQueued) return false;
      await _dropHead();
    }
  }

  Future<void> _dropHead() => _synchronized(() async {
        final items = await _readRaw();
        if (items.isEmpty) return;
        items.removeAt(0);
        await _writeRaw(items);
      });

  void dispose() {}
}
