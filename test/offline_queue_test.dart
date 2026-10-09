import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/token.dart';
import 'package:restro/services/kot_queue_service.dart';
import 'package:restro/services/offline_order_queue_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The outbox: queued orders and KOTs must be sent exactly once, never lost
/// silently, never replayed under the wrong operator, and never quarantined
/// just because the desk wanted the PIN again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SocketService socket;
  late KotQueueService kots;
  late OfflineOrderQueueService orders;

  /// event -> scripted responses, consumed in order (last one repeats).
  late Map<String, List<Object>> script;
  late List<String> sent;

  Map<String, dynamic> ok(Map<String, dynamic> extra) =>
      <String, dynamic>{'kind': 'success', ...extra};

  Object timeout() => TimeoutException('ack timed out');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService();
    kots = KotQueueService();
    orders = OfflineOrderQueueService(kots);
    sent = <String>[];
    script = <String, List<Object>>{
      'order:create': <Object>[
        ok(<String, dynamic>{
          'order': <String, dynamic>{'id': 'o1'}
        })
      ],
      'kot:send': <Object>[ok(<String, dynamic>{})],
    };
    socket.rawEmitOverride = (event, data, t) async {
      sent.add(event);
      final queue = script[event];
      if (queue == null || queue.isEmpty) return ok(<String, dynamic>{});
      final next = queue.length > 1 ? queue.removeAt(0) : queue.first;
      if (next is Map<String, dynamic>) return next;
      throw next;
    };
  });

  tearDown(() {
    orders.dispose();
    kots.dispose();
    socket.dispose();
  });

  Future<OrderSubmitResult> submit({String table = 't1'}) => orders.submitOrder(
        socket,
        orderEvent: 'order:create',
        orderPayload: <String, dynamic>{'table_id': table, 'items': <Object>[]},
        orderRequestId: 'req-order',
        kotRequestId: 'req-kot',
      );

  group('orders: no duplicate on a transport failure', () {
    test('a send that times out mid-flush leaves exactly one entry', () async {
      // Queued while offline.
      await submit();
      expect(await orders.pendingCount(), 1);

      socket.debugSetState(SocketState.verified);
      script['order:create'] = <Object>[timeout()];
      final drained = await orders.flush(socket);

      expect(drained, isFalse);
      expect(await orders.pendingCount(), 1,
          reason: '_attempt used to enqueue the order AGAIN while the flush '
              'kept the head: two entries, two orders on the desk');

      script['order:create'] = <Object>[
        ok(<String, dynamic>{
          'order': <String, dynamic>{'id': 'o1'}
        })
      ];
      expect(await orders.flush(socket), isTrue);
      expect(await orders.pendingCount(), 0);
      expect(sent.where((e) => e == 'order:create'), hasLength(2),
          reason: 'one failed try, one successful retry — not three');
    });

    test('a fresh submission that times out is enqueued exactly once',
        () async {
      socket.debugSetState(SocketState.verified);
      script['order:create'] = <Object>[timeout()];

      final result = await submit();

      expect(result.isQueued, isTrue);
      expect(await orders.pendingCount(), 1);
    });

    test('a healthy submission is sent and not queued', () async {
      socket.debugSetState(SocketState.verified);
      final result = await submit();
      expect(result.isSent, isTrue);
      expect(await orders.pendingCount(), 0);
      expect(sent, ['order:create', 'kot:send']);
    });
  });

  group('rejections are never silent', () {
    test('a refused queued order goes to the dead-letter store', () async {
      await submit(table: 't9');
      socket.debugSetState(SocketState.verified);
      script['order:create'] = <Object>[
        <String, dynamic>{'kind': 'error', 'message': 'Table is blocked'}
      ];
      final dropped = <RejectedOrderSubmission>[];
      final sub = orders.rejections.listen(dropped.add);

      expect(await orders.flush(socket), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(await orders.pendingCount(), 0);
      final dead = await kots.rejectedKots();
      expect(dead, hasLength(1));
      expect(dead.single.reason, contains('Table is blocked'));
      expect(dead.single.payload['table_id'], 't9',
          reason: 'so the banner can say which table');
      expect(dropped, hasLength(1));
      await sub.cancel();
    });

    test('an order older than the max age is dead-lettered, not fired',
        () async {
      await submit();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('pending_order_submissions_v1')!;
      final aged = raw.first.replaceFirst(
        RegExp(r'"queued_at":"[^"]+"'),
        '"queued_at":"${DateTime.now().subtract(const Duration(hours: 3)).toIso8601String()}"',
      );
      await prefs.setStringList('pending_order_submissions_v1', <String>[aged]);

      socket.debugSetState(SocketState.verified);
      expect(await orders.flush(socket), isTrue);

      expect(sent, isEmpty);
      expect(await kots.rejectedKots(), hasLength(1));
    });

    test('a KOT refused after its order landed is dead-lettered by order id',
        () async {
      await submit();
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{'kind': 'error', 'message': 'Kitchen closed'}
      ];

      expect(await orders.flush(socket), isTrue);

      final dead = await kots.rejectedKots();
      expect(dead.single.payload['order_id'], 'o1');
      expect(dead.single.reason, contains('Kitchen closed'));
    });
  });

  group('reauth_required pauses the queue and keeps the items', () {
    test('orders: nothing is quarantined, flushes stop, and PIN is requested',
        () async {
      await submit();
      socket.debugSetState(SocketState.verified);
      var prompts = 0;
      final answer = Completer<bool>();
      orders.onReauthRequired = () {
        prompts++;
        return answer.future;
      };
      script['order:create'] = <Object>[
        <String, dynamic>{
          'kind': 'error',
          'code': 'reauth_required',
          'message': 'PIN verification required',
        }
      ];

      expect(await orders.flush(socket), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(prompts, 1);
      expect(orders.isPaused, isTrue);
      expect(await orders.pendingCount(), 1, reason: 'the item stays');
      expect(await kots.rejectedKots(), isEmpty);

      // Paused: further flushes don't touch the desk.
      final before = sent.length;
      expect(await orders.flush(socket), isFalse);
      expect(sent.length, before);

      // PIN entered: back to work.
      script['order:create'] = <Object>[
        ok(<String, dynamic>{
          'order': <String, dynamic>{'id': 'o1'}
        })
      ];
      var unpaused = false;
      orders.onUnpaused = () => unpaused = true;
      answer.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(unpaused, isTrue);
      expect(orders.isPaused, isFalse);
      expect(await orders.flush(socket), isTrue);
      expect(await orders.pendingCount(), 0);
    });

    test('recognised by message alone (a desk without the code)', () {
      expect(
        isReauthRequired(<String, dynamic>{
          'kind': 'error',
          'message': 'PIN verification required',
        }),
        isTrue,
      );
      expect(
          isReauthRequired(<String, dynamic>{'kind': 'error', 'message': 'x'}),
          isFalse);
      expect(isReauthRequired(<String, dynamic>{'kind': 'success'}), isFalse);
    });

    test('a KOT refused for reauth is kept, not quarantined', () async {
      socket.debugSetState(SocketState.verified);
      kots.onReauthRequired = () async => false;
      script['kot:send'] = <Object>[
        <String, dynamic>{
          'kind': 'error',
          'code': 'reauth_required',
          'message': 'PIN verification required',
        }
      ];

      final result = await kots.sendKot(
          socket, <String, dynamic>{'order_id': 'o1'},
          clientRequestId: 'k1');

      expect(result.isQueued, isTrue);
      expect(await kots.pendingCount(), 1);
      expect(await kots.rejectedKots(), isEmpty);
      expect(kots.isPaused, isTrue);
    });

    test('a new verified session resumes a paused queue', () async {
      kots.onReauthRequired = () async => false;
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{
          'kind': 'error',
          'code': 'reauth_required',
        }
      ];
      await kots.sendKot(socket, <String, dynamic>{'order_id': 'o1'},
          clientRequestId: 'k1');
      expect(kots.isPaused, isTrue);
      kots.resume();
      expect(kots.isPaused, isFalse);
    });
  });

  group('KOT duplicates: nothing_to_send means it already went', () {
    Future<void> queueOne() async {
      await kots.sendKot(socket, <String, dynamic>{'order_id': 'o1'},
          clientRequestId: 'k1');
      expect(await kots.pendingCount(), 1);
    }

    test('by code', () async {
      await queueOne();
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{
          'kind': 'error',
          'code': 'nothing_to_send',
          'message': 'No pending items to send to kitchen',
        }
      ];

      expect(await kots.flush(socket), isTrue);
      expect(await kots.pendingCount(), 0);
      expect(await kots.rejectedKots(), isEmpty,
          reason: 'it already reached the kitchen — not a rejection');
    });

    test('by message alone (older desk)', () async {
      await queueOne();
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{
          'kind': 'error',
          'message': 'No pending items to send to kitchen',
        }
      ];
      expect(await kots.flush(socket), isTrue);
      expect(await kots.pendingCount(), 0);
      expect(await kots.rejectedKots(), isEmpty);
    });

    test('the old substrings no longer swallow real refusals', () async {
      await queueOne();
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{'kind': 'error', 'message': 'Order already settled'}
      ];
      expect(await kots.flush(socket), isTrue);
      expect(await kots.rejectedKots(), hasLength(1),
          reason: '"already" used to count as a duplicate and silently dropped '
              'a KOT for a settled order');
    });

    test('a live send answered nothing_to_send is a success', () async {
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{'kind': 'error', 'code': 'nothing_to_send'}
      ];
      final result = await kots.sendKot(
          socket, <String, dynamic>{'order_id': 'o1'},
          clientRequestId: 'k1');
      expect(result.isSent, isTrue);
    });
  });

  group('operator mismatch', () {
    test('a KOT queued under another operator is dead-lettered unsent',
        () async {
      var operatorId = 'opA';
      kots.currentOperatorId = () => operatorId;
      await kots.sendKot(socket, <String, dynamic>{'order_id': 'o1'},
          clientRequestId: 'k1');

      operatorId = 'opB';
      socket.debugSetState(SocketState.verified);
      expect(await kots.flush(socket), isTrue);

      expect(sent, isEmpty, reason: 'never replayed under the wrong login');
      expect(await kots.pendingCount(), 0);
      final dead = await kots.rejectedKots();
      expect(dead, hasLength(1));
      expect(dead.single.reason, contains('different operator'));
    });

    test('an order queued under another operator is dead-lettered unsent',
        () async {
      var operatorId = 'opA';
      orders.currentOperatorId = () => operatorId;
      await submit();

      operatorId = 'opB';
      socket.debugSetState(SocketState.verified);
      expect(await orders.flush(socket), isTrue);

      expect(sent, isEmpty);
      expect(await orders.pendingCount(), 0);
      expect(await kots.rejectedKots(), hasLength(1));
    });

    test('the same operator replays normally', () async {
      orders.currentOperatorId = () => 'opA';
      await submit();
      socket.debugSetState(SocketState.verified);
      expect(await orders.flush(socket), isTrue);
      expect(sent, contains('order:create'));
      expect(await kots.rejectedKots(), isEmpty);
    });
  });

  group('counter orders: local ref, meta and replay', () {
    Future<OrderSubmitResult> counterOrder({String? localRef}) =>
        orders.submitOrder(
          socket,
          orderEvent: 'order:create',
          orderPayload: <String, dynamic>{
            'items': <Object>[],
            'order_type': 'takeaway',
            'fulfillment_type': 'standing',
          },
          orderRequestId: 'req-order-${localRef ?? 'x'}',
          kotRequestId: 'req-kot',
          localRef: localRef,
          meta: QueuedCounterOrder.meta(
            itemCount: 3,
            total: const Money.rupees(420),
            fulfillment: FulfillmentType.standing,
          ),
        );

    test('a queued counter order is Q-1, Q-2… and lists with its meta',
        () async {
      final first = await counterOrder();
      final second = await counterOrder();

      expect(first.isQueued, isTrue);
      expect((first.localRef, second.localRef), ('Q-1', 'Q-2'));
      final queued = await orders.queuedCounterOrders();
      expect(queued.map((q) => q.localRef), <String>['Q-1', 'Q-2']);
      expect(queued.first.itemCount, 3);
      expect(queued.first.total, const Money.rupees(420));
      expect(queued.first.fulfillment, FulfillmentType.standing);
    });

    test('the refs restart each IST day and survive a restart', () async {
      var now = DateTime.utc(2026, 10, 9, 17, 0); // 22:30 IST
      orders.dispose();
      orders = OfflineOrderQueueService(kots, now: () => now);
      expect((await counterOrder()).localRef, 'Q-1');
      expect((await counterOrder()).localRef, 'Q-2');

      // A new instance (an app restart) carries on from Q-2.
      orders.dispose();
      orders = OfflineOrderQueueService(kots, now: () => now);
      expect((await counterOrder()).localRef, 'Q-3');

      now = DateTime.utc(2026, 10, 9, 18, 31); // 00:01 IST, the next day
      expect((await counterOrder()).localRef, 'Q-1');
    });

    test('a ref the caller brings is kept; a table order gets none', () async {
      expect((await counterOrder(localRef: 'Q-9')).localRef, 'Q-9');
      expect((await submit()).localRef, isNull);
      expect(await orders.queuedCounterOrders(), hasLength(1),
          reason: 'only counter orders are listed');
    });

    test('a live send gives no ref and burns none', () async {
      socket.debugSetState(SocketState.verified);
      expect((await counterOrder()).localRef, isNull);
      socket.debugSetState(SocketState.disconnected);
      expect((await counterOrder()).localRef, 'Q-1');
    });

    test('a send that times out queues with a ref', () async {
      socket.debugSetState(SocketState.verified);
      script['order:create'] = <Object>[timeout()];
      final result = await counterOrder();
      expect(result.isQueued, isTrue);
      expect(result.localRef, 'Q-1');
    });

    test('replaying it says which order and token Q-1 became', () async {
      await counterOrder();
      await submit(table: 't4');
      final replayed = <ReplayedOrder>[];
      final sub = orders.replayed.listen(replayed.add);
      addTearDown(sub.cancel);
      script['kot:send'] = <Object>[
        ok(<String, dynamic>{
          'kot': <String, dynamic>{
            'kot_number': 'KOT-0129',
            'token_label': 'T-07',
            'token_number': 7,
          },
          'order': <String, dynamic>{
            'id': 'o1',
            'token_label': 'T-07',
            'token_number': 7,
            'token_status': 'preparing',
          },
        }),
        ok(<String, dynamic>{}),
      ];

      socket.debugSetState(SocketState.verified);
      expect(await orders.flush(socket), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(replayed, hasLength(2));
      expect(replayed.first.localRef, 'Q-1');
      expect(replayed.first.orderId, 'o1');
      expect(replayed.first.token!.label, 'T-07');
      expect(replayed.first.token!.status, TokenStatus.preparing);
      expect(replayed.last.localRef, isNull, reason: 'the table order');
      expect(replayed.last.token, isNull);
      expect(await orders.queuedCounterOrders(), isEmpty);
    });

    test('a refused replay is not reported as landed', () async {
      await counterOrder();
      final replayed = <ReplayedOrder>[];
      final sub = orders.replayed.listen(replayed.add);
      addTearDown(sub.cancel);
      script['order:create'] = <Object>[
        <String, dynamic>{'kind': 'error', 'message': 'Item hidden'}
      ];
      socket.debugSetState(SocketState.verified);
      await orders.flush(socket);
      await Future<void>.delayed(Duration.zero);
      expect(replayed, isEmpty);
      expect(await kots.rejectedKots(), hasLength(1));
    });
  });

  group('queued-table mirror', () {
    test('pendingTableIds lists the tables with a queued order', () async {
      await submit(table: 't1');
      await submit(table: 't2');
      expect(await orders.pendingTableIds(), {'t1', 't2'});
    });
  });

  group('OutboxDrainWorker', () {
    test('flushes on a verified transition and mirrors the queue size',
        () async {
      await submit(table: 't1');
      int? count;
      Set<String>? tables;
      final worker = OutboxDrainWorker(
        socket: socket,
        orders: orders,
        kots: kots,
        onPending: (c, t) {
          count = c;
          tables = t;
        },
      )..start();
      addTearDown(worker.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(count, 1);
      expect(tables, {'t1'});

      socket.debugSetState(SocketState.verified);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(sent, ['order:create', 'kot:send']);
      expect(count, 0);
      expect(tables, isEmpty);
    });

    test('retries a failed flush with backoff while still verified', () async {
      await submit();
      final worker = OutboxDrainWorker(
        socket: socket,
        orders: orders,
        kots: kots,
        baseDelay: const Duration(milliseconds: 40),
        maxDelay: const Duration(milliseconds: 200),
        random: math.Random(1),
      )..start();
      addTearDown(worker.dispose);

      script['order:create'] = <Object>[
        timeout(),
        timeout(),
        ok(<String, dynamic>{
          'order': <String, dynamic>{'id': 'o1'}
        }),
      ];
      socket.debugSetState(SocketState.verified);
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(await orders.pendingCount(), 0,
          reason: 'it kept trying until the desk answered');
      expect(sent.where((e) => e == 'order:create'), hasLength(3));
      expect(worker.consecutiveFailures, 0);
    });

    test('backoff doubles from 2s to a 60s cap, with up to 25% jitter', () {
      final worker = OutboxDrainWorker(
        socket: socket,
        orders: orders,
        kots: kots,
        random: math.Random(7),
      );
      addTearDown(worker.dispose);
      int ms(int n) => worker.backoffFor(n).inMilliseconds;
      expect(ms(0), inInclusiveRange(2000, 2500));
      expect(ms(1), inInclusiveRange(4000, 5000));
      expect(ms(2), inInclusiveRange(8000, 10000));
      expect(ms(5), inInclusiveRange(60000, 75000));
      expect(ms(20), inInclusiveRange(60000, 75000));
    });

    test('does nothing while the socket is not verified', () async {
      await submit();
      final worker =
          OutboxDrainWorker(socket: socket, orders: orders, kots: kots)
            ..start();
      addTearDown(worker.dispose);
      await worker.kick();
      expect(sent, isEmpty);
      expect(await orders.pendingCount(), 1);
    });
  });
}
