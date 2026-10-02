import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/kot_print_config.dart';
import 'package:restro/services/escpos_builder.dart';
import 'package:restro/services/kot_queue_service.dart';
import 'package:restro/services/lan_printer_service.dart';
import 'package:restro/services/offline_kot_coordinator.dart';
import 'package:restro/services/offline_order_queue_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The direct-print marker (`printed_offline`, `offline_ref`, `printed_at`,
/// `failed_group_ids`) has to ride in the queued payloads and survive the
/// replay — including the order+KOT unit, whose kot:send is only built once the
/// order has an id — and must be ABSENT when nothing printed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SocketService socket;
  late KotQueueService kots;
  late OfflineOrderQueueService orders;
  late Map<String, List<Object>> script;
  late List<({String event, Map<String, dynamic> data})> sent;

  Map<String, dynamic> ok(Map<String, dynamic> extra) =>
      <String, dynamic>{'kind': 'success', ...extra};

  const printedFields = <String, dynamic>{
    'printed_offline': true,
    'offline_ref': 'A7Q2-014',
    'printed_at': '2026-10-05T04:45:00.000Z',
    'failed_group_ids': <String>['bar'],
  };

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService();
    kots = KotQueueService();
    orders = OfflineOrderQueueService(kots);
    sent = [];
    script = <String, List<Object>>{
      'order:create': <Object>[
        ok(<String, dynamic>{
          'order': <String, dynamic>{'id': 'o1'}
        })
      ],
      'kot:send': <Object>[ok(<String, dynamic>{})],
    };
    socket.rawEmitOverride = (event, data, t) async {
      sent.add((event: event, data: Map<String, dynamic>.from(data)));
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

  Future<OrderSubmitResult> submit({BeforeQueueHook? hook}) =>
      orders.submitOrder(
        socket,
        orderEvent: 'order:create',
        orderPayload: <String, dynamic>{'table_id': 't1', 'items': <Object>[]},
        orderRequestId: 'req-order',
        kotRequestId: 'req-kot',
        beforeQueue: hook,
      );

  Future<List<Map<String, dynamic>>> queued(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return [
      for (final e in prefs.getStringList(key) ?? const <String>[])
        Map<String, dynamic>.from(jsonDecode(e) as Map),
    ];
  }

  Map<String, dynamic> lastKotSend() =>
      sent.lastWhere((s) => s.event == 'kot:send').data;

  group('order + KOT unit', () {
    test(
        'printed fields are persisted in the entry and reach the replayed kot:send',
        () async {
      var hookCalls = 0;
      final result = await submit(hook: () async {
        hookCalls++;
        return printedFields;
      });
      expect(result.isQueued, isTrue);
      expect(hookCalls, 1,
          reason: 'printed exactly once per queued submission');

      final entry = (await queued('pending_order_submissions_v1')).single;
      expect(entry['kot_extra'], printedFields);

      // The desk comes back: the replay sends the order, then its KOT.
      socket.debugSetState(SocketState.verified);
      expect(await orders.flush(socket), isTrue);

      final kot = lastKotSend();
      expect(kot['order_id'], 'o1');
      expect(kot['client_request_id'], 'req-kot');
      expect(kot['printed_offline'], isTrue);
      expect(kot['offline_ref'], 'A7Q2-014');
      expect(kot['printed_at'], '2026-10-05T04:45:00.000Z');
      expect(kot['failed_group_ids'], ['bar']);
      expect(hookCalls, 1, reason: 'the replay must not print again');
    });

    test('nothing printed: the flag is not set on the replayed KOT', () async {
      await submit(hook: () async => const <String, dynamic>{});
      final entry = (await queued('pending_order_submissions_v1')).single;
      expect(entry.containsKey('kot_extra'), isFalse);

      socket.debugSetState(SocketState.verified);
      await orders.flush(socket);
      final kot = lastKotSend();
      expect(kot.containsKey('printed_offline'), isFalse,
          reason: 'the desk must print a KOT nobody printed');
      expect(kot.containsKey('offline_ref'), isFalse);
      expect(kot.containsKey('failed_group_ids'), isFalse);
    });

    test('no hook at all behaves exactly as before', () async {
      await submit();
      socket.debugSetState(SocketState.verified);
      await orders.flush(socket);
      expect(lastKotSend().keys.toSet(), {'order_id', 'client_request_id'});
    });

    test('a hook that throws queues the order with no marker', () async {
      final result = await submit(hook: () async => throw StateError('boom'));
      expect(result.isQueued, isTrue);
      final entry = (await queued('pending_order_submissions_v1')).single;
      expect(entry.containsKey('kot_extra'), isFalse);
    });

    test('a live send never prints', () async {
      socket.debugSetState(SocketState.verified);
      var hookCalls = 0;
      final result = await submit(hook: () async {
        hookCalls++;
        return printedFields;
      });
      expect(result.isSent, isTrue);
      expect(hookCalls, 0);
      expect(lastKotSend().containsKey('printed_offline'), isFalse);
    });

    test('the order timing out while "verified" queues it and prints once',
        () async {
      socket.debugSetState(SocketState.verified);
      script['order:create'] = <Object>[TimeoutException('ack timed out')];
      var hookCalls = 0;
      final result = await submit(hook: () async {
        hookCalls++;
        return printedFields;
      });
      expect(result.isQueued, isTrue);
      expect(hookCalls, 1);
      expect((await queued('pending_order_submissions_v1')).single['kot_extra'],
          printedFields);
    });

    test(
        'order lands but its KOT times out: the marker goes into the KOT queue',
        () async {
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[TimeoutException('ack timed out')];
      var hookCalls = 0;
      final result = await submit(hook: () async {
        hookCalls++;
        return printedFields;
      });
      expect(result.isSent, isTrue, reason: 'the order itself is on the desk');
      expect(result.kotAck['kind'], 'queued');
      expect(hookCalls, 1);

      final kot = (await queued('pending_kots_v2')).single['payload']
          as Map<String, dynamic>;
      expect(kot['order_id'], 'o1');
      expect(kot['printed_offline'], isTrue);
      expect(kot['failed_group_ids'], ['bar']);
    });

    test('a replayed entry whose KOT then times out keeps its marker',
        () async {
      await submit(hook: () async => printedFields);
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[TimeoutException('ack timed out')];
      await orders.flush(socket);

      final kot = (await queued('pending_kots_v2')).single['payload']
          as Map<String, dynamic>;
      expect(kot['printed_offline'], isTrue,
          reason: 'queued under kot_extra, so the KOT queue inherits it');
      expect(kot['offline_ref'], 'A7Q2-014');
    });
  });

  group('bare KOT queue', () {
    test('the marker is part of the persisted payload and survives replay',
        () async {
      final result = await kots.sendKot(
        socket,
        <String, dynamic>{'order_id': 'o9'},
        clientRequestId: 'k9',
        beforeQueue: () async => printedFields,
      );
      expect(result.isQueued, isTrue);
      final stored = (await queued('pending_kots_v2')).single['payload']
          as Map<String, dynamic>;
      expect(stored['printed_offline'], isTrue);
      expect(stored['offline_ref'], 'A7Q2-014');

      socket.debugSetState(SocketState.verified);
      expect(await kots.flush(socket), isTrue);
      final kot = lastKotSend();
      expect(kot['order_id'], 'o9');
      expect(kot['printed_offline'], isTrue);
      expect(kot['printed_at'], '2026-10-05T04:45:00.000Z');
    });

    test('nothing printed: the queued payload has no marker', () async {
      await kots.sendKot(
        socket,
        <String, dynamic>{'order_id': 'o9'},
        clientRequestId: 'k9',
        beforeQueue: () async => const <String, dynamic>{},
      );
      final stored = (await queued('pending_kots_v2')).single['payload']
          as Map<String, dynamic>;
      expect(stored.containsKey('printed_offline'), isFalse);
      expect(stored.keys.toSet(), {'order_id', 'client_request_id'});
    });

    test('PIN needed (reauth_required) also parks the KOT, and prints',
        () async {
      socket.debugSetState(SocketState.verified);
      script['kot:send'] = <Object>[
        <String, dynamic>{
          'kind': 'error',
          'code': 'reauth_required',
          'message': 'PIN verification required',
        },
      ];
      var hookCalls = 0;
      final result = await kots.sendKot(
        socket,
        <String, dynamic>{'order_id': 'o9'},
        clientRequestId: 'k9',
        beforeQueue: () async {
          hookCalls++;
          return printedFields;
        },
      );
      expect(result.isQueued, isTrue);
      expect(hookCalls, 1);
    });

    test('a live send does not call the hook', () async {
      socket.debugSetState(SocketState.verified);
      var hookCalls = 0;
      final result = await kots.sendKot(
        socket,
        <String, dynamic>{'order_id': 'o9'},
        clientRequestId: 'k9',
        beforeQueue: () async {
          hookCalls++;
          return printedFields;
        },
      );
      expect(result.isSent, isTrue);
      expect(hookCalls, 0);
    });
  });

  group('OfflineKotCoordinator', () {
    const config = KotPrintConfig(
      version: 'v1',
      groups: <KotPrintGroup>[
        KotPrintGroup(
          id: 'kitchen',
          name: 'Kitchen',
          isFallback: true,
          destinations: <KotPrintDestination>[
            KotPrintDestination(host: '10.0.0.11', port: 9100),
          ],
        ),
      ],
      categoryGroups: <String, List<String>>{
        'c1': <String>['kitchen'],
      },
    );

    const item = MenuItem(
      id: 'i1',
      name: 'Paneer Tikka',
      section: 'Starters',
      kitchenSection: 'food',
      price: Money.zero,
      isVeg: true,
    );

    late ProviderContainer container;
    late _RecordingPrinter printer;

    ProviderContainer build({bool failPrint = false}) {
      printer = _RecordingPrinter(fail: failPrint);
      final c = ProviderContainer(overrides: [
        lanPrinterProvider.overrideWithValue(printer),
      ]);
      c.read(kotPrintConfigProvider.notifier).state = config;
      c.read(operatorProvider.notifier).state =
          const Operator(name: 'Ram', role: 'Waiter', shift: 'Day', id: 'op1');
      c.read(rawMenuDataProvider.notifier).state = <String, dynamic>{
        'items': [
          {'id': 'i1', 'category_id': 'c1'}
        ],
      };
      c.read(tablesProvider.notifier).state = const <RestaurantTable>[
        RestaurantTable(
            id: 'T4',
            serverId: 't4',
            seats: 4,
            floor: 'Ground',
            state: TableState.free),
      ];
      return c;
    }

    final cart = <CartLine>[CartLine(item: item, qty: 2, itemNote: 'less oil')];

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = build();
    });
    tearDown(() => container.dispose());

    test('prints, and returns the fields to persist', () async {
      final attempt = await container
          .read(offlineKotCoordinatorProvider)
          .printForQueuedKot(cart: cart, slotId: 't4', isRoom: false);

      expect(attempt.attempted, isTrue);
      expect(attempt.printedAnything, isTrue);
      expect(attempt.fields['printed_offline'], isTrue);
      expect(
          attempt.fields['offline_ref'], matches(RegExp(r'^[A-Z2-9]{4}-001$')));
      expect(attempt.fields['failed_group_ids'], isEmpty);
      expect(attempt.message,
          'Printed on kitchen printer directly · will sync when the desk is back');

      final doc = printer.docs.single;
      expect(doc.subtitleLines, contains('Ground | Table T4'));
      expect(doc.itemLines, ['2 x Paneer Tikka', '    ! less oil']);
      expect(doc.footerLines, ['Steward: Ram']);
    });

    test('the setting can switch it off (default is on)', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{DirectKotPrintSetting.key: false});
      final attempt = await container
          .read(offlineKotCoordinatorProvider)
          .printForQueuedKot(cart: cart, slotId: 't4', isRoom: false);
      expect(attempt.attempted, isFalse);
      expect(attempt.fields, isEmpty);
      expect(attempt.message, isNull);
      expect(printer.docs, isEmpty);
    });

    test('no config from the desk means no direct printing', () async {
      container.read(kotPrintConfigProvider.notifier).state = null;
      final attempt = await container
          .read(offlineKotCoordinatorProvider)
          .printForQueuedKot(cart: cart, slotId: 't4', isRoom: false);
      expect(attempt.attempted, isFalse);
      expect(attempt.fields, isEmpty);
    });

    test('nothing printed: no marker, and the operator is told', () async {
      container.dispose();
      container = build(failPrint: true);
      final attempt = await container
          .read(offlineKotCoordinatorProvider)
          .printForQueuedKot(cart: cart, slotId: 't4', isRoom: false);
      expect(attempt.attempted, isTrue);
      expect(attempt.printedAnything, isFalse);
      expect(attempt.fields, isEmpty,
          reason: 'the desk prints it normally on replay');
      expect(attempt.message, 'Could not print — will print when the desk is back');
    });

    test('categoryIdsByItem reads both menu shapes', () {
      expect(
        categoryIdsByItem(<String, dynamic>{
          'items': [
            {'id': 'a', 'category_id': 'c1'},
            {'id': 'b'},
          ],
        }),
        {'a': 'c1'},
      );
      expect(
        categoryIdsByItem(<String, dynamic>{
          'categories': [
            {
              'id': 'c9',
              'items': [
                {'id': 'z'}
              ]
            },
          ],
        }),
        {'z': 'c9'},
      );
      expect(categoryIdsByItem(<String, dynamic>{}), isEmpty);
    });
  });
}

class _RecordingPrinter implements LanPrinter {
  final bool fail;
  final List<EscposDoc> docs = <EscposDoc>[];
  _RecordingPrinter({this.fail = false});

  @override
  Future<LanPrintResult> printDoc(
      KotPrintDestination dest, EscposDoc doc) async {
    docs.add(doc);
    return fail
        ? const LanPrintResult.failure('refused')
        : const LanPrintResult.success();
  }
}
