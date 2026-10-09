import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:restro/data/counter_providers.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/parked_providers.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/models/token.dart';
import 'package:restro/screens/counter_checkout_screen.dart';
import 'package:restro/screens/order_builder_screen.dart';
import 'package:restro/screens/order_detail_screen.dart';
import 'package:restro/screens/order_success_screen.dart';
import 'package:restro/screens/token_result_screen.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/offline_order_queue_service.dart';
import 'package:restro/services/qsr_checkout_service.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/parked_fixtures.dart';
import 'support/payment_sheet_harness.dart' show fieldWithHint;

class _Bootstrap extends ConnectionBootstrap {
  _Bootstrap(super.ref);
}

typedef _Sent = ({String event, Map<String, dynamic> data});

const _hybrid = QsrConfig(
    operatingMode: OperatingMode.qsr, paymentFlow: QsrPaymentFlow.hybrid);
const _prepaid = QsrConfig(
    operatingMode: OperatingMode.qsr, paymentFlow: QsrPaymentFlow.prepaid);
const _postpaid = QsrConfig(
    operatingMode: OperatingMode.qsr, paymentFlow: QsrPaymentFlow.postpaid);

final FeatureFlags _cashier = FeatureFlags.fromMap(<String, dynamic>{
  'flag_collect_payment': 1,
  'flag_generate_bill': 1,
  'flag_order_tokens': 1,
  'flag_takeaway': 1,
});

/// The counter screens over a fake desk, on the counter's routes.
class _Counter {
  _Counter(this.socket, this.container, this.router);

  final SocketService socket;
  final ProviderContainer container;
  final GoRouter router;
  final List<_Sent> sent = <_Sent>[];
  late FutureOr<Object> Function(String event, Map<String, dynamic> data)
      answer;

  List<Map<String, dynamic>> payloads(String event) => <Map<String, dynamic>>[
        for (final s in sent)
          if (s.event == event) s.data,
      ];

  String get path => router.routerDelegate.currentConfiguration.uri.path;
  List<CartLine> get cart => container.read(cartProvider);
}

void main() {
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;

  /// What the desk answers, by event.
  Object desk(String event, Map<String, dynamic> data) => switch (event) {
        'order:preview-totals' => <String, dynamic>{
            'kind': 'success',
            'totals': <String, dynamic>{'totalAmount': 1050},
          },
        'qsr:checkout' => fixture('qsr_checkout_ack.json'),
        'order:create' => <String, dynamic>{
            'kind': 'success',
            'order': <String, dynamic>{
              'id': 'ord_9c21',
              'order_number': 'ORD-0045',
              'status': 'placed',
              'total': 420,
              'order_type': 'takeaway',
              'fulfillment_type': 'standing',
              'items': <Object>[],
            },
          },
        'kot:send' => <String, dynamic>{
            'kind': 'success',
            'kot': <String, dynamic>{
              'kot_number': 'KOT-0129',
              'token_label': 'T-07',
              'token_number': 7,
            },
            'order': fixture('order_with_token.json'),
          },
        _ => <String, dynamic>{'kind': 'success'},
      };

  Future<_Counter> pumpCounter(
    WidgetTester tester, {
    String initial = '/counter/order',
    QsrConfig qsr = _hybrid,
    FeatureFlags? flags,
    List<CartLine> cart = const <CartLine>[],
    bool online = true,
    Map<String, Object> prefs = const <String, Object>{},
    List<Override> overrides = const <Override>[],
  }) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(prefs);

    final socket = SocketService()
      ..debugSetState(online ? SocketState.verified : SocketState.disconnected);
    addTearDown(socket.dispose);
    final container = ProviderContainer(overrides: [
      socketServiceProvider.overrideWithValue(socket),
      connectionBootstrapProvider.overrideWith((ref) => _Bootstrap(ref)
        ..debugSetPairing(const PairingInfo(
            host: '192.168.1.20',
            port: 4100,
            token: 'tok',
            deskInstanceId: 'desk-1'))),
      ...overrides,
    ]);
    addTearDown(container.dispose);
    container.read(operatorProvider.notifier).state = const Operator(
        name: 'Asha', role: 'Cashier', shift: 'Day', id: 'op-asha');
    container.read(flagsProvider.notifier).state = flags ?? _cashier;
    container.read(qsrConfigProvider.notifier).state = qsr;
    container.read(menuProvider.notifier).state = <MenuItem>[
      menuItem(),
      coffee()
    ];
    container.read(cartProvider.notifier).replaceAll(cart);

    final router = GoRouter(
      initialLocation: initial,
      routes: <RouteBase>[
        GoRoute(
            path: '/counter',
            builder: (_, __) => const Scaffold(body: Text('COUNTER HOME'))),
        GoRoute(
            path: '/tables',
            builder: (_, __) => const Scaffold(body: Text('TABLES HOME'))),
        GoRoute(
            path: '/counter/order',
            builder: (_, __) => const OrderBuilderScreen.counter()),
        GoRoute(
            path: '/counter/order/checkout',
            builder: (_, __) => const CounterCheckoutScreen()),
        GoRoute(
            path: '/counter/order/token',
            builder: (_, __) => const TokenResultScreen()),
        GoRoute(
            path: '/order/:tableId',
            builder: (_, s) =>
                OrderBuilderScreen(tableId: s.pathParameters['tableId']!)),
        GoRoute(
            path: '/order/:tableId/success',
            builder: (_, s) =>
                OrderSuccessScreen(tableId: s.pathParameters['tableId']!)),
      ],
    );
    addTearDown(router.dispose);

    final h = _Counter(socket, container, router)..answer = desk;
    socket.rawEmitOverride = (event, data, timeout) async {
      h.sent.add((event: event, data: Map<String, dynamic>.from(data)));
      final reply = await h.answer(event, data);
      if (reply is Exception || reply is Error) throw reply;
      return reply;
    };

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    return h;
  }

  /// Lets every toast run out, so no timer outlives the test.
  Future<void> drain(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(seconds: 5));

  group('the builder in counter mode', () {
    testWidgets('joins and leaves no table, and asks the menu for the counter',
        (tester) async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        final h = await pumpCounter(tester);
        expect(find.text('Counter'), findsOneWidget);
        expect(find.text('Takeaway'), findsOneWidget);
        expect(find.text('Standing'), findsOneWidget);
        expect(h.payloads('table:presence:join'), isEmpty);
        expect(h.payloads('menu_area:context').single,
            <String, dynamic>{'counter': true});

        h.router.go('/counter');
        await tester.pumpAndSettle();
        expect(logs.where((l) => l.contains('table:presence')), isEmpty,
            reason: 'no leave either: the counter never joined');

        // The same builder for a table does both, as before.
        h.router.go('/order/t1');
        await tester.pumpAndSettle();
        expect(h.payloads('table:presence:join').single,
            <String, dynamic>{'table_id': 't1'});
        h.router.go('/tables');
        await tester.pumpAndSettle();
        expect(logs.where((l) => l.contains('-> table:presence:leave {')),
            hasLength(1));
      } finally {
        debugPrint = original;
      }
    });

    testWidgets('the cart bar says Charge, Fire or Checkout by the flow',
        (tester) async {
      for (final (qsr, label) in <(QsrConfig, String)>[
        (_prepaid, 'Charge'),
        (_postpaid, 'Fire'),
        (_hybrid, 'Checkout'),
      ]) {
        await pumpCounter(tester, qsr: qsr, cart: <CartLine>[dosaLine()]);
        expect(find.text(label), findsOneWidget, reason: '${qsr.paymentFlow}');
        expect(find.text('Send KOT'), findsNothing);
      }
    });

    testWidgets('Park keeps the cart on the phone and empties the screen',
        (tester) async {
      final h = await pumpCounter(tester, cart: <CartLine>[dosaLine(qty: 2)]);
      await tester.tap(find.byTooltip('Park'));
      await tester.pumpAndSettle();
      expect(find.text('Parked as P1'), findsOneWidget);
      expect(h.cart, isEmpty);
      expect(h.container.read(parkedCountProvider(ParkedKind.counterCart)), 1);
      expect(find.text('Parked 1'), findsOneWidget);
      await drain(tester);
    });

    testWidgets(
        'resuming at the parking cap offers Replace or Discard first, not a '
        'bare error', (tester) async {
      final at = DateTime.now().subtract(const Duration(minutes: 5));
      final h = await pumpCounter(
        tester,
        cart: <CartLine>[CartLine(item: coffee(), qty: 3)],
        prefs: <String, Object>{
          'parked_drafts_v1': envelopeJson(<Object?>[
            for (var i = 1; i <= 20; i++)
              draftOf(cartDraft(), createdAt: at, seq: i).toJson(),
          ]),
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Parked 20'));
      await tester.pumpAndSettle();

      Future<void> resumeP1AndParkCurrent() async {
        await tester.tap(find.byKey(
            const ValueKey<String>('parked-resume-pk-op-asha-counterCart-1')));
        await tester.pumpAndSettle();
        expect(find.text('Cart in progress'), findsOneWidget);
        await tester.tap(find.text('Park current and resume'));
        await tester.pumpAndSettle();
        expect(find.text('Parking is full'), findsOneWidget);
      }

      await resumeP1AndParkCurrent();
      await tester.tap(find.text('Discard a parked cart first'));
      await tester.pumpAndSettle();
      expect(find.text('Parked carts'), findsOneWidget,
          reason: 'the sheet stays open to discard one');
      expect(h.cart.single.item.id, 'coffee', reason: 'nothing changed');
      expect(h.container.read(parkedCountProvider(ParkedKind.counterCart)), 20);

      await resumeP1AndParkCurrent();
      await tester.tap(find.text('Replace current cart'));
      await tester.pumpAndSettle();
      expect(find.text('Parked carts'), findsNothing);
      expect(h.cart.single.item.id, 'dosa', reason: 'P1 is the cart now');
      expect(h.container.read(parkedCountProvider(ParkedKind.counterCart)), 19);
      await drain(tester);
    });
  });

  group('checkout', () {
    testWidgets('the actions follow the desk\'s payment flow', (tester) async {
      for (final (qsr, fire, pay) in <(QsrConfig, bool, bool)>[
        (_prepaid, false, true),
        (_postpaid, true, false),
        (_hybrid, true, true),
      ]) {
        await pumpCounter(tester,
            initial: '/counter/order/checkout',
            qsr: qsr,
            cart: <CartLine>[dosaLine()]);
        expect(find.text('Fire KOT · pay at pickup'),
            fire ? findsOneWidget : findsNothing,
            reason: '${qsr.paymentFlow}');
        expect(find.textContaining('Pay & Fire'),
            pay ? findsOneWidget : findsNothing,
            reason: '${qsr.paymentFlow}');
      }
    });

    testWidgets(
        'post-paid: Fire KOT sends order:create with how it leaves, then the '
        'KOT, and shows the token', (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _postpaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      await h.container
          .read(counterFulfillmentProvider.notifier)
          .set(FulfillmentType.standing);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fire KOT · pay at pickup'));
      await tester.pumpAndSettle();

      final order = h.payloads('order:create').single;
      expect(order['fulfillment_type'], 'standing');
      expect(order['order_type'], 'takeaway');
      expect(order.containsKey('table_id'), isFalse);
      expect(order.containsKey('room_id'), isFalse);
      expect(order['items'], <Map<String, dynamic>>[
        <String, dynamic>{
          'item_id': 'dosa',
          'quantity': 2,
          'selected_options': <Object>[],
          'notes': '',
        },
      ]);
      expect(order['client_request_id'], isA<String>());
      expect(h.payloads('kot:send').single['order_id'], 'ord_9c21');
      expect(h.payloads('qsr:checkout'), isEmpty,
          reason: 'pay at pickup never goes through qsr:checkout');

      expect(h.path, '/counter/order/token');
      expect(find.text('T-07'), findsOneWidget);
      expect(find.text('Pay at pickup'), findsOneWidget);
      expect(find.text('Standing'), findsOneWidget);
      expect(h.cart, isEmpty);
      expect(h.container.read(lastTokenProvider)!.label, 'T-07');
    });

    testWidgets(
        'split: ₹500 cash on a ₹1,050 bill leaves Pay & Fire off until the '
        'rest is tendered', (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          flags: FeatureFlags.fromMap(<String, dynamic>{
            'flag_collect_payment': 1,
            'flag_generate_bill': 1,
            'flag_order_tokens': 1,
            'flag_takeaway': 1,
            'flag_split_payment': 1,
          }),
          cart: <CartLine>[dosaLine(qty: 2)]);
      final add = find.byKey(const ValueKey<String>('tender-add-split'));
      Future<void> addSplit() async {
        await tester.ensureVisible(add);
        await tester.pump();
        await tester.tap(add);
        await tester.pump();
      }

      LiquidPrimaryButton pay() => tester.widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Pay & Fire ₹1,050'));

      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldWithHint('₹1,050').last, '500');
      await addSplit();
      expect(find.text('Remaining: ₹550'), findsOneWidget);
      expect(pay().onPressed, isNull,
          reason: 'the fill would charge the ₹550 to cash unasked');

      await tester.ensureVisible(find.text('Cash').first);
      await tester.tap(find.text('Cash').first);
      await tester.pump();
      await tester.enterText(fieldWithHint('₹550').last, '550');
      await addSplit();
      expect(pay().onPressed, isNotNull, reason: 'the splits cover the bill');

      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();
      final payments = h.payloads('qsr:checkout').single['payments'] as List;
      expect(payments, hasLength(2));
      expect((payments.first as Map)['amount'], 500);
      expect((payments.last as Map).containsKey('amount'), isFalse,
          reason: 'the desk fills only the last tender, from the real bill');
    });

    testWidgets(
        'prepaid: Pay & Fire sends one qsr:checkout with fill tenders and '
        'the shown total, and shows the paid token', (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();

      final sent = h.payloads('qsr:checkout').single;
      expect(sent['mode'], 'pay_and_fire');
      expect(sent['fulfillment_type'], 'takeaway');
      expect(sent['expected_total'], 1050.0);
      expect(
          sent['payments'],
          <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'cash'},
          ],
          reason: 'no amount: the desk fills it from the real bill');
      expect(h.payloads('order:create'), isEmpty);

      expect(h.path, '/counter/order/token');
      expect(find.text('S-03'), findsOneWidget);
      expect(find.text('Paid'), findsOneWidget);
      expect(find.text('2 items · ₹1,050.00'), findsOneWidget,
          reason: 'the real total from the ack');
      expect(h.cart, isEmpty);
      expect(h.container.read(pendingCheckoutProvider), isNull);
      expect(h.container.read(lastCounterPayModeProvider), 'cash');

      // The next order starts on the mode charged last.
      h.container
          .read(cartProvider.notifier)
          .replaceAll(<CartLine>[dosaLine()]);
      h.router.go('/counter/order/checkout');
      await tester.pumpAndSettle();
      final pay = tester.widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Pay & Fire ₹1,050'));
      expect(pay.onPressed, isNotNull, reason: 'Cash is picked already');
    });

    testWidgets(
        'no answer: the token screen says not confirmed, and Retry sends the '
        'same request', (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      h.answer = (event, data) => event == 'qsr:checkout'
          ? TimeoutException('ack timed out')
          : desk(event, data);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();

      expect(h.path, '/counter/order/token');
      expect(find.text('NOT CONFIRMED'), findsOneWidget);
      expect(find.textContaining('Next order'), findsNothing,
          reason: 'nothing moves on by itself');
      expect(h.cart, hasLength(1), reason: 'kept until the desk answers');
      expect(h.container.read(pendingCheckoutProvider), isNotNull);

      h.answer = desk;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      final calls = h.payloads('qsr:checkout');
      expect(calls, hasLength(2));
      expect(calls[1], calls[0], reason: 'the very same request and id');
      expect(find.text('S-03'), findsOneWidget);
      expect(h.container.read(pendingCheckoutProvider), isNull);
      expect(h.cart, isEmpty);
    });

    testWidgets(
        'price_changed shows the desk\'s total and charges it only once the '
        'cashier agrees, as a new attempt', (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      var first = true;
      h.answer = (event, data) {
        if (event == 'qsr:checkout' && first) {
          first = false;
          return fixture('qsr_checkout_price_changed_ack.json');
        }
        return desk(event, data);
      };
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();

      expect(find.text('The total changed'), findsOneWidget);
      await tester.tap(find.text('Charge ₹1,102.50'));
      await tester.pumpAndSettle();

      final calls = h.payloads('qsr:checkout');
      expect(calls, hasLength(2));
      expect(calls[0]['expected_total'], 1050.0);
      expect(calls[1]['expected_total'], 1102.5);
      expect(
          calls[1]['client_request_id'], isNot(calls[0]['client_request_id']));
      expect(find.text('S-03'), findsOneWidget);
    });

    testWidgets('without the desk, Pay & Fire offers to park the cart',
        (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          online: false,
          cart: <CartLine>[dosaLine(qty: 2)]);
      await tester.tap(find.text('Pay & Fire'));
      await tester.pumpAndSettle();
      expect(find.text('The desk is not reachable'), findsOneWidget);
      await tester.tap(find.text('Park cart'));
      await tester.pumpAndSettle();

      expect(h.payloads('qsr:checkout'), isEmpty);
      expect(h.cart, isEmpty);
      expect(h.container.read(parkedCountProvider(ParkedKind.counterCart)), 1);
      expect(h.path, '/counter/order');
      await drain(tester);
    });
  });

  group('hardening', () {
    /// A prepaid checkout whose first Pay & Fire got no answer: the token
    /// screen is showing NOT CONFIRMED and the attempt is kept.
    Future<_Counter> unconfirmed(WidgetTester tester,
        {List<Override> overrides = const <Override>[]}) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          cart: <CartLine>[dosaLine(qty: 2)],
          overrides: overrides);
      h.answer = (event, data) => event == 'qsr:checkout'
          ? TimeoutException('ack timed out')
          : desk(event, data);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();
      expect(find.text('NOT CONFIRMED'), findsOneWidget);
      return h;
    }

    testWidgets(
        'a retry refused for a business reason drops the attempt: nothing '
        'was charged', (tester) async {
      final h = await unconfirmed(tester);
      h.answer = (event, data) => event == 'qsr:checkout'
          ? <String, dynamic>{
              'kind': 'error',
              'code': 'cover_empty',
              'message': 'No cover left on ET-041',
            }
          : desk(event, data);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text("This ticket's cover is used up. Nothing was charged."),
          findsOneWidget);
      expect(h.container.read(pendingCheckoutProvider), isNull);
      expect(h.path, '/counter/order', reason: 'back to the kept cart');
      expect(h.cart.single.qty, 2);
      await drain(tester);
    });

    testWidgets(
        'a retry refused without a business code keeps the attempt as '
        'unconfirmed, and the next retry is the same request', (tester) async {
      final h = await unconfirmed(tester);
      h.answer = (event, data) => event == 'qsr:checkout'
          ? <String, dynamic>{'kind': 'error', 'message': 'Internal error'}
          : desk(event, data);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text(kCheckoutNoAnswer), findsNWidgets(2),
          reason: 'the card, and the toast');
      expect(find.textContaining('Nothing was charged'), findsNothing);
      expect(find.text('NOT CONFIRMED'), findsOneWidget);
      expect(h.container.read(pendingCheckoutProvider), isNotNull);
      await drain(tester);

      h.answer = desk;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      final calls = h.payloads('qsr:checkout');
      expect(calls, hasLength(3));
      for (final call in calls.skip(1)) {
        expect(call, calls.first,
            reason: 'one attempt: the same request every time');
      }
      expect(find.text('S-03'), findsOneWidget);
    });

    testWidgets('a first attempt refused without a business code is kept too',
        (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      h.answer = (event, data) => event == 'qsr:checkout'
          ? <String, dynamic>{'kind': 'error', 'message': 'Internal error'}
          : desk(event, data);
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();

      expect(find.text('NOT CONFIRMED'), findsOneWidget);
      expect(h.container.read(pendingCheckoutProvider), isNotNull);
    });

    testWidgets(
        'a retry the phone cannot take in never leaves the screen stuck',
        (tester) async {
      final h = await unconfirmed(tester, overrides: <Override>[
        syncServiceProvider.overrideWith((ref) => throw StateError('down')),
      ]);
      h.answer = desk;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget, reason: 'not "Checking…"');
      final retry = tester.widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Retry'));
      expect(retry.onPressed, isNotNull);
      expect(find.text(kCheckoutNoAnswer), findsNWidgets(2),
          reason: 'the card, and the toast');
      expect(h.container.read(pendingCheckoutProvider), isNotNull,
          reason: 'kept: the next Retry replays the desk\'s answer');
      await drain(tester);
    });

    testWidgets(
        'while a changed total is being worked out, Pay & Fire stays busy',
        (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _prepaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      // The refusal carries no total, so the screen asks the desk again;
      // that answer is held back until the test lets it go.
      final fresh = Completer<Object>();
      h.answer = (event, data) {
        if (event == 'qsr:checkout') {
          return <String, dynamic>{
            'kind': 'error',
            'code': 'price_changed',
            'message': 'Prices changed',
          };
        }
        if (event == 'order:preview-totals') return fresh.future;
        return desk(event, data);
      };
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay & Fire ₹1,050'));
      await tester.pumpAndSettle();

      final pay = tester.widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Pay & Fire ₹1,050'));
      expect(pay.onPressed, isNull, reason: 'busy while the total is fetched');

      fresh.complete(<String, dynamic>{
        'kind': 'success',
        'totals': <String, dynamic>{'totalAmount': 1102.5},
      });
      await tester.pumpAndSettle();
      expect(find.text('The total changed'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.payloads('qsr:checkout'), hasLength(1));
      final again = tester.widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Pay & Fire ₹1,102.50'));
      expect(again.onPressed, isNotNull);
    });

    testWidgets('Fire KOT says so when the kitchen printer refuses the KOT',
        (tester) async {
      final h = await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _postpaid,
          cart: <CartLine>[dosaLine(qty: 2)]);
      h.answer = (event, data) => event == 'print:kot'
          ? <String, dynamic>{'kind': 'error'}
          : desk(event, data);
      await tester.tap(find.text('Fire KOT · pay at pickup'));
      await tester.pumpAndSettle();

      expect(h.payloads('print:kot').single['order_id'], 'ord_9c21');
      expect(h.path, '/counter/order/token');
      expect(find.text('KOT print failed — check the kitchen printer'),
          findsOneWidget);
      await drain(tester);
    });

    testWidgets('a queued order\'s total is said to be before tax',
        (tester) async {
      await pumpCounter(tester,
          initial: '/counter/order/checkout',
          qsr: _postpaid,
          online: false,
          cart: <CartLine>[dosaLine(qty: 2)]);
      await tester.tap(find.text('Fire KOT · pay at pickup'));
      await tester.pumpAndSettle();

      expect(find.text('QUEUED'), findsOneWidget);
      expect(find.text('2 items · ₹200.00 before tax'), findsOneWidget);
    });
  });

  group('the token screen', () {
    Future<_Counter> showResult(WidgetTester tester, CounterOrderResult result,
        {FeatureFlags? flags}) async {
      final h = await pumpCounter(tester, initial: '/counter', flags: flags);
      h.container.read(counterResultProvider.notifier).state = result;
      h.router.go('/counter/order/token');
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('fired: the token big (#42 unified, T-07 as is) and paid',
        (tester) async {
      await showResult(
          tester,
          const CounterOrderResult(
            outcome: CounterOutcome.fired,
            fulfillment: FulfillmentType.takeaway,
            paid: true,
            itemCount: 2,
            total: Money.rupees(420),
            token: TokenInfo(label: '42', number: 42),
          ));
      expect(find.text('#42'), findsOneWidget);
      expect(find.text('#0042'), findsNothing, reason: 'never zero-padded');
      expect(find.text('Takeaway'), findsOneWidget);
      expect(find.text('Paid'), findsOneWidget);
      expect(find.text('2 items · ₹420.00'), findsOneWidget);
      expect(find.text('Next order (8)'), findsOneWidget);
      expect(tokenDisplay('T-07'), 'T-07');
    });

    testWidgets('with tokens off it shows the KOT, not a token on its way',
        (tester) async {
      await showResult(
          tester,
          const CounterOrderResult(
            outcome: CounterOutcome.fired,
            fulfillment: FulfillmentType.takeaway,
            paid: false,
            itemCount: 1,
            total: Money.rupees(100),
            kotNumber: 'KOT-0131',
          ),
          flags: FeatureFlags.fromMap(<String, dynamic>{
            'flag_collect_payment': 1,
            'flag_order_tokens': 0,
          }));
      expect(find.text('SENT TO THE KITCHEN'), findsOneWidget);
      expect(find.text('KOT-0131'), findsOneWidget);
      expect(find.text('Token on its way'), findsNothing);
    });

    testWidgets('back means done: to the Counter', (tester) async {
      final h = await showResult(
          tester,
          const CounterOrderResult(
            outcome: CounterOutcome.fired,
            fulfillment: FulfillmentType.takeaway,
            paid: true,
            itemCount: 1,
            total: Money.rupees(100),
            token: TokenInfo(label: '42'),
          ));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(h.path, '/counter');
    });

    testWidgets('the 8 s countdown goes back to a new order', (tester) async {
      final h = await showResult(
          tester,
          const CounterOrderResult(
            outcome: CounterOutcome.fired,
            fulfillment: FulfillmentType.standing,
            paid: false,
            itemCount: 1,
            total: Money.rupees(100),
            token: TokenInfo(label: 'S-03'),
          ));
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(h.path, '/counter/order/token');
      expect(find.text('Next order (1)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(h.path, '/counter/order');
    });

    testWidgets(
        'queued: the local ref until the desk is back, then the token, live',
        (tester) async {
      final h = await pumpCounter(tester, initial: '/counter', online: false);
      final queue = h.container.read(offlineOrderQueueProvider);
      // Driven by the test clock: the queue was made under it.
      final queuing = queue.submitOrder(
        h.socket,
        orderEvent: 'order:create',
        orderPayload: <String, dynamic>{
          'items': <Object>[],
          'order_type': 'takeaway',
          'fulfillment_type': 'takeaway',
        },
        orderRequestId: 'req-o',
        kotRequestId: 'req-k',
        meta: QueuedCounterOrder.meta(
            itemCount: 2,
            total: const Money.rupees(420),
            fulfillment: FulfillmentType.takeaway),
      );
      await tester.pumpAndSettle();
      final queued = await queuing;
      expect(queued.localRef, 'Q-1');
      h.container.read(counterResultProvider.notifier).state =
          CounterOrderResult(
        outcome: CounterOutcome.queued,
        fulfillment: FulfillmentType.takeaway,
        paid: false,
        itemCount: 2,
        total: const Money.rupees(420),
        localRef: queued.localRef,
        offlineRef: 'A7Q2-014',
      );
      h.router.go('/counter/order/token');
      await tester.pumpAndSettle();

      expect(find.text('QUEUED'), findsOneWidget);
      expect(find.text('Q-1'), findsOneWidget);
      expect(find.text('The token is assigned when the desk is back.'),
          findsOneWidget);
      expect(find.text('Kitchen slip printed · A7Q2-014'), findsOneWidget);
      expect(find.text('Pay at pickup'), findsOneWidget);

      // The desk is back and the queue replays it.
      h.socket.debugSetState(SocketState.verified);
      final flushing = queue.flush(h.socket);
      await tester.pumpAndSettle();
      expect(await flushing, isTrue);
      await tester.pumpAndSettle();

      expect(find.text('QUEUED'), findsNothing);
      expect(find.text('T-07'), findsOneWidget);
      final shown = h.container.read(counterResultProvider)!;
      expect(shown.outcome, CounterOutcome.fired);
      expect(shown.orderId, 'ord_9c21');
      expect(find.text('Q-1 → Token T-07'), findsOneWidget);
      await drain(tester);
    });
  });

  testWidgets(
      'a table order on a QSR desk goes back to Tables, not to the Counter',
      (tester) async {
    final h = await pumpCounter(tester, initial: '/counter');
    h.router.go('/order/t1/success');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Back to Tables ('), findsOneWidget);
    expect(find.textContaining('Back to Counter'), findsNothing);
    await tester.tap(find.textContaining('Back to Tables ('));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(h.path, '/tables');
  });

  testWidgets(
      'order detail: one tap Collect bills a counter order, then opens the '
      'payment sheet; the token shows', (tester) async {
    final h = await pumpCounter(tester, initial: '/counter');
    h.container.read(historyProvider.notifier).state = <HistoryOrder>[
      const HistoryOrder(
        id: 'KOT-0129',
        orderId: 'ord_9c21',
        tableId: 'Token T-07',
        time: '14:58',
        date: '2026-10-09',
        itemCount: 2,
        total: Money.rupees(420),
        status: OrderStatus.sent,
        lines: <HistoryOrderLine>[],
        tokenLabel: 'T-07',
        tokenStatus: TokenStatus.ready,
        fulfillmentType: FulfillmentType.takeaway,
      ),
    ];
    h.answer = (event, data) => event == 'bill:generate'
        ? <String, dynamic>{
            'kind': 'success',
            'bills': <Object>[
              <String, dynamic>{
                'id': 'bill_1',
                'bill_number': 'INV/26-27/001300',
                'bill_type': 'food',
                'total_amount': 441,
                'payment_status': 'unpaid',
                'status': 'active',
              },
            ],
          }
        : desk(event, data);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const OrderDetailScreen(orderId: 'KOT-0129'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('T-07 · Ready'), findsOneWidget);
    expect(find.text('Generate Bill'), findsNothing);
    await tester.tap(find.text('Collect payment'));
    await tester.pumpAndSettle();

    expect(h.payloads('bill:generate').single['order_id'], 'ord_9c21');
    expect(find.text('Collect Payment'), findsOneWidget,
        reason: 'the payment sheet, with the fresh bill');
    expect(find.text('₹441'), findsWidgets);
    await drain(tester);
  });
}
