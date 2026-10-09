import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/counter_providers.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/screens/counter_checkout_screen.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/token.dart';
import 'package:restro/services/qsr_checkout_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counter "Pay & Fire" over a fake desk: one `qsr:checkout`, a money event
/// with a 15s timeout, one request id per attempt (kept for the retry of an
/// unanswered one), no send without the desk, and every refusal in staff
/// words.
void main() {
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;

  late SocketService socket;
  late QsrCheckoutService service;
  late List<({String event, Map<String, dynamic> data, Duration timeout})> sent;
  late FutureOr<Object> Function(String event, Map<String, dynamic> data)
      answer;

  setUp(() {
    socket = SocketService()..debugSetState(SocketState.verified);
    service = QsrCheckoutService(socket);
    sent = <({String event, Map<String, dynamic> data, Duration timeout})>[];
    answer = (_, __) => fixture('qsr_checkout_ack.json');
    socket.rawEmitOverride = (event, data, timeout) async {
      sent.add((
        event: event,
        data: Map<String, dynamic>.from(data),
        timeout: timeout,
      ));
      final reply = await answer(event, data);
      if (reply is Exception || reply is Error) throw reply;
      return reply;
    };
  });

  tearDown(() => socket.dispose());

  QsrCheckoutRequest request({Money? expected}) => QsrCheckoutRequest(
        fulfillment: FulfillmentType.standing,
        items: <Map<String, dynamic>>[
          <String, dynamic>{'item_id': 'itm_roll', 'quantity': 2},
          <String, dynamic>{'item_id': 'itm_platter', 'quantity': 1},
        ],
        payments: const <TenderLine>[
          TenderLine(
              mode: 'cover_ticket',
              amount: Money.rupees(800),
              ticketCode: 'CDT:7QKX2MZ4HB6TNW3R'),
          TenderLine(mode: 'cash'),
        ],
        notes: '  no onion  ',
        expectedTotal: expected ?? const Money.rupees(1050),
      );

  test(
      'sends one pay_and_fire: cover at its planned amount, the last tender '
      'filled, 15s and the attempt id', () async {
    final req = request();
    final result = await service.payAndFire(req);

    expect(result, isA<QsrCheckoutOk>());
    final call = sent.single;
    expect(call.event, 'qsr:checkout');
    expect(call.timeout, const Duration(seconds: 15));
    expect(call.data, <String, dynamic>{
      'fulfillment_type': 'standing',
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'item_id': 'itm_roll', 'quantity': 2},
        <String, dynamic>{'item_id': 'itm_platter', 'quantity': 1},
      ],
      'notes': 'no onion',
      'mode': 'pay_and_fire',
      'payments': <Map<String, dynamic>>[
        // The cover the cashier was shown (the desk refuses rather than
        // place less); only the last tender is left for the desk to fill.
        <String, dynamic>{
          'payment_mode': 'cover_ticket',
          'amount': 800.0,
          'ticket_code': 'CDT:7QKX2MZ4HB6TNW3R',
        },
        <String, dynamic>{'payment_mode': 'cash'},
      ],
      'expected_total': 1050.0,
      'client_request_id': req.clientRequestId,
    });
  });

  test('the ack gives the token, the order, the KOT and the real total',
      () async {
    final result = await service.payAndFire(request()) as QsrCheckoutOk;
    final ack = result.ack;
    expect(ack.token!.label, 'S-03');
    expect(ack.token!.number, 3);
    expect(ack.orderId, 'ord_a7d4');
    expect(ack.kotNumber, 'KOT-0130');
    expect(ack.bills.single.id, 'bill_a7d4_food');
    expect(ack.total, const Money.rupees(1050));
    expect(ack.orderSettled, isTrue);
  });

  group('an answer that never came', () {
    for (final (name, reply) in <(String, Object)>[
      ('a timeout', TimeoutException('ack timed out')),
      ('a dropped link', const SocketException('reset')),
      ('a garbled reply', 'not a map'),
    ]) {
      test('$name is unconfirmed, and the retry is the same request', () async {
        final req = request();
        answer = (_, __) => reply;
        expect(await service.payAndFire(req), isA<QsrCheckoutUnconfirmed>());

        answer = (_, __) => fixture('qsr_checkout_ack.json');
        expect(await service.payAndFire(req), isA<QsrCheckoutOk>());

        expect(sent, hasLength(2));
        expect(sent[1].data, sent[0].data,
            reason: 'same payload, so the desk replays instead of charging '
                'twice');
        expect(sent[1].data['client_request_id'], req.clientRequestId);
      });
    }
  });

  test('without the desk nothing is sent: money never queues', () async {
    socket.debugSetState(SocketState.disconnected);
    expect(await service.payAndFire(request()), isA<QsrCheckoutOffline>());
    socket.debugSetState(SocketState.connected);
    expect(await service.payAndFire(request()), isA<QsrCheckoutOffline>(),
        reason: 'connected but not yet re-verified is not the desk');
    expect(sent, isEmpty);
  });

  group('refusals', () {
    Future<QsrCheckoutRejected> refusedWith(Map<String, dynamic> ack) async {
      answer = (_, __) => ack;
      return await service.payAndFire(request()) as QsrCheckoutRejected;
    }

    test('price_changed carries the desk\'s total (the fixture)', () async {
      final r =
          await refusedWith(fixture('qsr_checkout_price_changed_ack.json'));
      expect(r.priceChanged, isTrue);
      expect(r.newTotal, const Money(110250));
      expect(r.message, 'Prices changed on the desk — check the new total');
    });

    test('price_changed without a total reads it off the message', () async {
      final r = await refusedWith(<String, dynamic>{
        'kind': 'error',
        'code': 'price_changed',
        'message': 'Total is now ₹1,250',
      });
      expect(r.newTotal, const Money.rupees(1250));
      expect(
          priceChangedTotal(<String, dynamic>{'message': 'no figure'}), isNull);
    });

    test('each §2.10 code reads as staff words', () async {
      final copy = <String, String>{
        'item_unavailable': 'Something in the cart is no longer available — '
            'remove it and try again',
        'payment_short': "The payments don't cover the bill",
        'payment_over': 'The payments are more than the bill',
        'flow_blocked': 'The desk now takes payment at pickup here — use '
            'Fire KOT',
        'cover_empty': "This ticket's cover is used up",
        'cover_changed':
            "This ticket's cover changed since it was scanned — scan it again",
        'cover_expired': 'This ticket was for an earlier day',
        'cover_not_applicable': "Cover can't pay a room, comp or credit bill",
        'ticket_not_found': 'No ticket matches that code',
        'qsr_disabled': 'The desk is no longer in counter mode',
      };
      for (final entry in copy.entries) {
        final r = await refusedWith(<String, dynamic>{
          'kind': 'error',
          'code': entry.key,
          'message': 'DESK TEXT',
        });
        expect(r.code, entry.key);
        expect(r.message, entry.value, reason: entry.key);
        expect(r.newTotal, isNull);
      }
    });

    test(
        'cover_changed (spent elsewhere since the scan) proves nothing was '
        'charged; with two tickets the desk\'s words name it', () async {
      answer = (_, __) => <String, dynamic>{
            'kind': 'error',
            'code': 'cover_changed',
            'message':
                'Cover on ET-042 changed — now ₹300. Scan the ticket again.',
          };
      final one = await service.payAndFire(request()) as QsrCheckoutRejected;
      expect(one.isBusinessRefusal, isTrue);
      expect(one.message,
          "This ticket's cover changed since it was scanned — scan it again");
      expect(retryRefusalCopy(one), endsWith('Nothing was charged.'));

      final two = await service.payAndFire(QsrCheckoutRequest(
        fulfillment: FulfillmentType.takeaway,
        items: <Map<String, dynamic>>[
          <String, dynamic>{'item_id': 'itm_roll', 'quantity': 2},
        ],
        payments: const <TenderLine>[
          TenderLine(
              mode: 'cover_ticket',
              amount: Money.rupees(400),
              ticketCode: 'CDT:P3VJ5LDY2GQA7FEC'),
          TenderLine(
              mode: 'cover_ticket',
              amount: Money.rupees(650),
              ticketCode: 'CDT:7QKX2MZ4HB6TNW3R'),
        ],
        expectedTotal: const Money.rupees(1050),
      )) as QsrCheckoutRejected;
      expect(two.message,
          'Cover on ET-042 changed — now ₹300. Scan the ticket again.');
    });

    test('two cover tickets, one refused: the desk\'s words name it', () async {
      answer = (_, __) => <String, dynamic>{
            'kind': 'error',
            'code': 'cover_empty',
            'message': 'No cover left on ET-041',
          };
      final r = await service.payAndFire(QsrCheckoutRequest(
        fulfillment: FulfillmentType.takeaway,
        items: <Map<String, dynamic>>[
          <String, dynamic>{'item_id': 'itm_roll', 'quantity': 2},
        ],
        payments: const <TenderLine>[
          TenderLine(mode: 'cover_ticket', ticketCode: 'CDT:P3VJ5LDY2GQA7FEC'),
          TenderLine(mode: 'cover_ticket', ticketCode: 'CDT:7QKX2MZ4HB6TNW3R'),
        ],
        expectedTotal: const Money.rupees(1050),
      )) as QsrCheckoutRejected;
      expect(r.message, 'No cover left on ET-041');
      expect(r.isBusinessRefusal, isTrue);
    });

    test('a code this app does not word shows the desk\'s message', () async {
      final r = await refusedWith(<String, dynamic>{
        'kind': 'error',
        'code': 'something_new',
        'message': 'Counter closed for cleaning',
      });
      expect(r.message, 'Counter closed for cleaning');
    });
  });

  test('only a business refusal proves an attempt never went through', () {
    QsrCheckoutRejected refused(String? code) =>
        QsrCheckoutRejected(code: code, message: 'desk text');
    for (final code in <String>[
      'price_changed',
      'payment_short',
      'payment_over',
      'payment_invalid',
      'cover_empty',
      'cover_changed',
      'cover_expired',
      'cover_not_applicable',
      'ticket_not_found',
      'ticket_cancelled',
      'item_unavailable',
      'menu_blocked',
      'flow_blocked',
      'qsr_disabled',
    ]) {
      expect(refused(code).isBusinessRefusal, isTrue, reason: code);
    }
    for (final code in <String?>[
      null,
      'reauth_required',
      'permission_denied',
      'something_new',
    ]) {
      expect(refused(code).isBusinessRefusal, isFalse, reason: '$code');
    }
    expect(refused('reauth_required').needsPin, isTrue);
    expect(refused('payment_short').needsPin, isFalse);
  });

  test('it is a money event: no default timeout allowed', () {
    expect(() => socket.emitAck('qsr:checkout', <String, dynamic>{}),
        throwsArgumentError);
  });

  test('logs carry no ticket code and no guest note', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = original);

    await service.payAndFire(request());
    answer = (_, __) => fixture('qsr_checkout_price_changed_ack.json');
    await service.payAndFire(request());

    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, isNot(contains('CDT:')));
      expect(line, isNot(contains('onion')));
      expect(line, isNot(contains('ET-04')));
    }
  });

  group('a kept Pay & Fire belongs to its operator', () {
    const asha =
        Operator(name: 'Asha', role: 'Cashier', shift: 'Day', id: 'op-asha');
    const ravi =
        Operator(name: 'Ravi', role: 'Cashier', shift: 'Day', id: 'op-ravi');
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = ProviderContainer(overrides: [
        qsrCheckoutServiceProvider.overrideWithValue(service),
      ]);
      addTearDown(container.dispose);
      container.read(operatorProvider.notifier).state = asha;
    });

    PendingCheckout keep() {
      final pending = PendingCheckout(
        request: request(),
        cart: const <CartLine>[],
        estimate: const Money.rupees(1050),
        operatorId: asha.id,
      );
      container.read(pendingCheckoutProvider.notifier).hold(pending);
      return pending;
    }

    test('another operator signing in drops it; the same one back keeps it',
        () {
      final pending = keep();
      container.read(operatorProvider.notifier).state = const Operator(
          name: 'Asha', role: 'Cashier', shift: 'Night', id: 'op-asha');
      expect(container.read(pendingCheckoutProvider), same(pending));
      container.read(operatorProvider.notifier).state = ravi;
      expect(container.read(pendingCheckoutProvider), isNull,
          reason: 'his retry would charge again: the desk replays by operator');
    });

    test('it is never sent under another operator', () async {
      final pending = keep();
      container.read(operatorProvider.notifier).state = ravi;
      final result = await retryPendingCheckout(container, pending);
      expect(result, isA<QsrCheckoutRejected>());
      expect((result as QsrCheckoutRejected).code, kOtherOperatorCode);
      expect(sent, isEmpty, reason: 'nothing went to the desk');
      expect(retryRefusalCopy(result), contains('Another operator'));
    });
  });
}
