import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/gate_providers.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/services/entry_ticket_service.dart';
import 'package:restro/services/socket_service.dart';

/// The gate over a fake desk: a ticket sale and a check-in are money events
/// (15s, one request id per attempt, kept for the retry of an unanswered
/// one, resent once after a PIN prompt), nothing goes without the desk, a
/// sale is shown only when it adds up, and every refusal is in staff words.
void main() {
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;

  late SocketService socket;
  late EntryTicketService service;
  late List<({String event, Map<String, dynamic> data, Duration timeout})> sent;
  late FutureOr<Object> Function(String event, Map<String, dynamic> data)
      answer;
  late int pinPrompts;
  late bool pinEntered;

  setUp(() {
    socket = SocketService()..debugSetState(SocketState.verified);
    pinPrompts = 0;
    pinEntered = true;
    service = EntryTicketService(socket, reauth: () async {
      pinPrompts++;
      return pinEntered;
    });
    sent = <({String event, Map<String, dynamic> data, Duration timeout})>[];
    answer = (_, __) => fixture('ticket_issue_ack.json');
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

  const reauth = <String, dynamic>{
    'kind': 'error',
    'code': 'reauth_required',
    'message': 'PIN verification required',
  };

  TicketIssueRequest sale({String? id}) => TicketIssueRequest(
        lines: const <TicketIssueLine>[
          TicketIssueLine(ticketTypeId: 'ett_couple', qty: 2),
        ],
        guestName: '  Ravi Sharma ',
        guestPhone: '9876543210',
        payments: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(1000)),
          // The last tender leaves the amount out: it takes the balance.
          TenderLine(mode: 'upi', reference: '628311904417'),
        ],
        expectedTotal: const Money.rupees(4000),
        clientRequestId: id ?? 'req_1760020812000000_3fa9c2d1',
      );

  group('ticket:issue', () {
    test('sends the contract payload (the request fixture) as a money event',
        () async {
      expect(await service.issue(sale()), isA<TicketIssueOk>());
      final call = sent.single;
      expect(call.event, 'ticket:issue');
      expect(call.timeout, const Duration(seconds: 15));
      expect(call.data, fixture('ticket_issue_request.json'));
    });

    test('the ack is the sale and one ticket per unit sold', () async {
      final ok = await service.issue(sale()) as TicketIssueOk;
      expect(ok.result.sale.saleNumber, 'ET/26-27/000037');
      expect(ok.result.sale.totals.total, const Money.rupees(4000));
      expect(ok.result.tickets.map((t) => t.ticketNumber),
          <String>['ET-041', 'ET-042']);
    });

    test('a blank guest is left out; a ticket tender carries only its keys',
        () {
      final bare = TicketIssueRequest(
        lines: const <TicketIssueLine>[
          TicketIssueLine(ticketTypeId: 'ett_stag', qty: 1),
        ],
        guestName: '   ',
        guestPhone: '',
        payments: const <TenderLine>[
          TenderLine(
            mode: 'custom_phonepe',
            reference: ' 77 ',
            reason: ' staff party ',
            notes: 'never sent',
            ticketCode: 'CDT:7QKX2MZ4HB6TNW3R',
          ),
        ],
        expectedTotal: const Money.rupees(1108),
      ).toPayload();
      expect(bare.containsKey('guest_name'), isFalse);
      expect(bare.containsKey('guest_phone'), isFalse);
      expect(bare['payments'], <Map<String, dynamic>>[
        <String, dynamic>{
          'payment_mode': 'custom_phonepe',
          'reference_number': '77',
          'mode_reason': 'staff party',
        },
      ]);
      expect(bare['expected_total'], 1108);
      expect((bare['client_request_id'] as String).startsWith('req_'), isTrue);
    });

    test('a new total the usher accepted is a new attempt, same sale', () {
      final first = sale();
      final second = first.withExpectedTotal(const Money.rupees(4200));
      expect(second.clientRequestId, isNot(first.clientRequestId));
      expect(second.toPayload()['expected_total'], 4200);
      expect(second.toPayload()['lines'], first.toPayload()['lines']);
      expect(second.toPayload()['payments'], first.toPayload()['payments']);
    });

    group('refusals', () {
      Future<TicketIssueRejected> refusedWith(Map<String, dynamic> ack) async {
        answer = (_, __) => ack;
        return await service.issue(sale()) as TicketIssueRejected;
      }

      test('price_changed carries the desk\'s new total', () async {
        final r = await refusedWith(<String, dynamic>{
          'kind': 'error',
          'code': 'price_changed',
          'message': 'Total is now ₹4,200.00',
        });
        expect(r.priceChanged, isTrue);
        expect(r.newTotal, const Money.rupees(4200));
        expect(r.message,
            'Ticket prices changed on the desk — check the new total');
      });

      test('each §2.10 code reads as staff words', () async {
        final copy = <String, String>{
          'payment_short': "The payments don't cover the tickets",
          'payment_over': 'The payments are more than the tickets cost',
          'payment_invalid': "The desk can't take that payment for tickets",
          'type_unavailable':
              'A ticket type is no longer on sale — check the tickets',
          'limit_exceeded': 'Too many tickets in one sale — split it in two',
          'permission_denied': "You can't sell entry tickets — ask the desk",
          'ticket_not_found': 'No ticket matches that code',
          'ticket_cancelled': 'This ticket was cancelled',
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
          expect(r.needsPin, isFalse);
        }
      });

      test('a code this app does not word shows the desk\'s message', () async {
        final r = await refusedWith(<String, dynamic>{
          'kind': 'error',
          'code': 'gate_closed',
          'message': 'Gate closed for the night',
        });
        expect(r.message, 'Gate closed for the night');
      });
    });

    group('an answer that never came', () {
      for (final (name, reply) in <(String, Object)>[
        ('a timeout', TimeoutException('ack timed out')),
        ('a dropped link', const SocketException('reset')),
        ('a garbled reply', 'not a map'),
      ]) {
        test('$name is unconfirmed, and the retry is the same request',
            () async {
          final req = sale(id: 'req_kept');
          answer = (_, __) => reply;
          expect(await service.issue(req), isA<TicketIssueUnconfirmed>());

          answer = (_, __) => fixture('ticket_issue_ack.json');
          expect(await service.issue(req), isA<TicketIssueOk>());

          expect(sent, hasLength(2));
          expect(sent[1].data, sent[0].data,
              reason: 'same payload, so the desk replays instead of selling '
                  'twice');
          expect(sent[1].data['client_request_id'], 'req_kept');
        });
      }
    });

    test('a lapsed PIN is asked for once, then the SAME request goes again',
        () async {
      var calls = 0;
      answer = (_, __) =>
          ++calls == 1 ? reauth : fixture('ticket_issue_ack.json');
      expect(await service.issue(sale(id: 'req_pin')), isA<TicketIssueOk>());
      expect(pinPrompts, 1);
      expect(sent, hasLength(2));
      expect(sent[1].data, sent[0].data);
      expect(sent[1].data['client_request_id'], 'req_pin');
    });

    test('a PIN not entered again is a refusal that keeps a kept try kept',
        () async {
      pinEntered = false;
      answer = (_, __) => reauth;
      final r = await service.issue(sale()) as TicketIssueRejected;
      expect(r.needsPin, isTrue);
      expect(r.message, 'Enter your PIN again, then retry');
      expect(pinPrompts, 1);
      expect(sent, hasLength(1));
    });

    test('without the desk nothing is sent: money never queues', () async {
      socket.debugSetState(SocketState.disconnected);
      expect(await service.issue(sale()), isA<TicketIssueOffline>());
      socket.debugSetState(SocketState.connected);
      expect(await service.issue(sale()), isA<TicketIssueOffline>(),
          reason: 'connected but not yet re-verified is not the desk');
      expect(sent, isEmpty);
    });

    group('a sale is shown only when it adds up', () {
      Future<TicketIssueOutcome> issuedWith(
          void Function(Map<String, dynamic> ack) change) {
        final ack = fixture('ticket_issue_ack.json');
        change(ack);
        answer = (_, __) => ack;
        return service.issue(sale());
      }

      List<Object?> payments(Map<String, dynamic> ack) =>
          (ack['sale'] as Map<String, dynamic>)['payments'] as List<Object?>;

      test('a payment row read leniently away leaves it short: not shown',
          () async {
        // TicketSale.fromMap drops an unreadable payment row, so the sale
        // would show ₹1,000 paid of ₹4,000.
        final outcome = await issuedWith((ack) =>
            (payments(ack)[1]! as Map<String, dynamic>)['amount'] = 'lots');
        expect(outcome, isA<TicketIssueUnreadable>());
      });

      test('payments that are more than the total: not shown', () async {
        final outcome = await issuedWith((ack) =>
            (payments(ack)[0]! as Map<String, dynamic>)['amount'] = 1500);
        expect(outcome, isA<TicketIssueUnreadable>());
      });

      test('fewer slips than were sold: not shown', () async {
        final outcome =
            await issuedWith((ack) => (ack['tickets'] as List).removeLast());
        expect(outcome, isA<TicketIssueUnreadable>());
      });

      test('no tickets at all: not shown, never a crash', () async {
        final outcome =
            await issuedWith((ack) => ack['tickets'] = <Object?>[]);
        expect(outcome, isA<TicketIssueUnreadable>());
      });

      test('a paisa apart is the desk\'s own tolerance: shown', () async {
        final outcome = await issuedWith((ack) =>
            (payments(ack)[0]! as Map<String, dynamic>)['amount'] = 1000.01);
        expect(outcome, isA<TicketIssueOk>());
      });
    });
  });

  group('a kept (unanswered) sale', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(overrides: [
        entryTicketServiceProvider.overrideWithValue(service),
      ]);
      addTearDown(container.dispose);
    });

    PendingTicketIssue keep() {
      final form = container.read(ticketIssueFormProvider);
      final pending = PendingTicketIssue(
          request: sale(), summary: '2× Couple Pass', form: form);
      container.read(pendingTicketIssueProvider.notifier).state = pending;
      return pending;
    }

    test('only a business refusal proves nothing was sold', () {
      TicketIssueRejected r(String? code) =>
          TicketIssueRejected(code: code, message: 'M');
      for (final code in <String>[
        'price_changed',
        'type_unavailable',
        'limit_exceeded',
        'payment_short',
        'payment_over',
        'payment_invalid',
        'ticket_not_found',
      ]) {
        expect(r(code).isBusinessRefusal, isTrue, reason: code);
      }
      for (final code in <String?>[
        'reauth_required',
        'permission_denied',
        'something_new',
        null,
      ]) {
        expect(r(code).isBusinessRefusal, isFalse, reason: '$code');
      }
      expect(retryIssueRefusalCopy(r('payment_short')),
          'M. Nothing was charged.');
      expect(retryIssueRefusalCopy(r(null)), kIssueNoAnswer);
      expect(
          retryIssueRefusalCopy(
              const TicketIssueRejected(code: 'reauth_required', message: 'P')),
          'P');
    });

    test('a retry the desk answers shows the sale and clears the form',
        () async {
      container.read(ticketIssueFormProvider.notifier).setQty('ett_couple', 2);
      final pending = keep();
      final outcome = await retryPendingIssue(container, pending);
      expect(outcome, isA<TicketIssueOk>());
      expect(sent.single.data['client_request_id'],
          pending.request.clientRequestId);
      expect(container.read(pendingTicketIssueProvider), isNull);
      expect(container.read(ticketIssueResultProvider), isNotNull);
      expect(container.read(ticketIssueFormProvider).hasTickets, isFalse);
    });

    test('a business refusal drops it; anything else keeps it', () async {
      final pending = keep();
      for (final ack in <Map<String, dynamic>>[
        <String, dynamic>{'kind': 'error', 'message': 'Internal error'},
        <String, dynamic>{'kind': 'error', 'code': 'permission_denied'},
      ]) {
        answer = (_, __) => ack;
        await retryPendingIssue(container, pending);
        expect(container.read(pendingTicketIssueProvider), same(pending),
            reason: '$ack might follow a sale that went through');
      }
      pinEntered = false;
      answer = (_, __) => reauth;
      await retryPendingIssue(container, pending);
      expect(container.read(pendingTicketIssueProvider), same(pending));
      answer = (_, __) => TimeoutException('ack timed out');
      await retryPendingIssue(container, pending);
      expect(container.read(pendingTicketIssueProvider), same(pending));

      answer = (_, __) => <String, dynamic>{
            'kind': 'error',
            'code': 'payment_invalid',
            'message': 'nope',
          };
      await retryPendingIssue(container, pending);
      expect(container.read(pendingTicketIssueProvider), isNull);
      expect(sent.map((s) => s.data['client_request_id']).toSet(),
          <String>{pending.request.clientRequestId},
          reason: 'every retry is the same request');
    });
  });

  test('both are money events: no default timeout allowed', () {
    expect(() => socket.emitAck('ticket:issue', <String, dynamic>{}),
        throwsArgumentError);
    expect(() => socket.emitAck('ticket:check_in', <String, dynamic>{}),
        throwsArgumentError);
  });

  group('ticket:check_in', () {
    TicketCheckInRequest scan({String id = 'req_scan'}) =>
        TicketCheckInRequest(code: ' CDT:P3VJ5LDY2GQA7FEC ', clientRequestId: id);

    test('sends {code, method, client_request_id}, trimmed, as a money event',
        () async {
      answer = (_, __) => fixture('ticket_check_in_valid.json');
      await service.checkIn(scan());
      final manual = TicketCheckInRequest(
          code: ' et-42 ', method: CheckInMethod.manual, clientRequestId: 'm');
      await service.checkIn(manual);
      expect(sent[0].event, 'ticket:check_in');
      expect(sent[0].timeout, const Duration(seconds: 15));
      expect(sent[0].data, <String, dynamic>{
        'code': 'CDT:P3VJ5LDY2GQA7FEC',
        'method': 'scan',
        'client_request_id': 'req_scan',
      });
      expect(sent[1].data, <String, dynamic>{
        'code': 'et-42',
        'method': 'manual',
        'client_request_id': 'm',
      });
    });

    test('each outcome fixture is an answer', () async {
      final expected = <String, CheckInOutcome>{
        'ticket_check_in_valid.json': CheckInOutcome.valid,
        'ticket_check_in_already_used.json': CheckInOutcome.alreadyUsed,
        'ticket_check_in_expired.json': CheckInOutcome.expired,
        'ticket_check_in_cancelled.json': CheckInOutcome.cancelled,
        'ticket_check_in_not_found.json': CheckInOutcome.notFound,
      };
      for (final entry in expected.entries) {
        answer = (_, __) => fixture(entry.key);
        final outcome = await service.checkIn(scan()) as CheckInAnswered;
        expect(outcome.result.outcome, entry.value, reason: entry.key);
      }
    });

    test('no answer is unconfirmed; the retry is the same request', () async {
      final req = scan(id: 'req_door');
      answer = (_, __) => TimeoutException('ack timed out');
      expect(await service.checkIn(req), isA<CheckInUnconfirmed>());
      answer = (_, __) => fixture('ticket_check_in_valid.json');
      expect(await service.checkIn(req), isA<CheckInAnswered>());
      expect(sent[1].data, sent[0].data,
          reason: 'the desk replays its "valid" instead of "already used"');
    });

    test('a lapsed PIN is asked for once and the same check-in resent',
        () async {
      var calls = 0;
      answer = (_, __) =>
          ++calls == 1 ? reauth : fixture('ticket_check_in_valid.json');
      expect(await service.checkIn(scan()), isA<CheckInAnswered>());
      expect(pinPrompts, 1);
      expect(sent[1].data, sent[0].data);
    });

    test('refusals are in staff words', () async {
      answer = (_, __) => <String, dynamic>{
            'kind': 'error',
            'code': 'permission_denied',
            'message': 'DESK TEXT',
          };
      final r = await service.checkIn(scan()) as CheckInRefused;
      expect(r.message, "You can't check guests in — ask the desk");
    });

    test('without the desk nothing is sent: no offline check-in', () async {
      socket.debugSetState(SocketState.connected);
      expect(await service.checkIn(scan()), isA<CheckInOffline>());
      expect(sent, isEmpty);
    });
  });

  group('ticket:recent', () {
    test('sends the search trimmed and the limit; reads rows and counters',
        () async {
      answer = (_, __) => fixture('ticket_recent_ack.json');
      final loaded =
          await service.recent(query: '  3210 ') as RecentTicketsLoaded;
      expect(sent.single.event, 'ticket:recent');
      expect(sent.single.data, <String, dynamic>{'q': '3210', 'limit': 100});
      expect(loaded.recent.tickets, hasLength(4));
      expect(loaded.recent.tickets[1].guestPhoneLast4, '3210');
      expect(loaded.recent.stats.paxInside, 2);
    });

    test('no search sends none; a long one is cut to 40', () async {
      answer = (_, __) => fixture('ticket_recent_ack.json');
      await service.recent();
      await service.recent(query: 'x' * 60);
      expect(sent[0].data, <String, dynamic>{'limit': 100});
      expect((sent[1].data['q'] as String).length, 40);
    });

    test('a dropped link says so', () async {
      answer = (_, __) => const SocketException('reset');
      final failed = await service.recent() as RecentTicketsFailed;
      expect(failed.message, "Couldn't reach the desk — try again");
    });
  });

  test('a ticket is paid in cash, UPI, card or a revenue mode — never comp, '
      'credit, company, a non-revenue mode or cover', () {
    const staffMeal = PayMode(
        code: 'custom_staff', label: 'Staff meal', printName: 'Staff', isRevenue: false);
    const phonePe = PayMode(
        code: 'custom_phonepe', label: 'PhonePe', printName: 'PhonePe');
    const cover = PayMode(
        code: 'cover_ticket', label: 'Cover', printName: 'Cover');
    final catalog = payModeCatalog(
      flags: const FeatureFlags(complimentary: true, customers: true),
      listed: const <PayMode>[phonePe, staffMeal, cover],
    );
    expect(catalog.map((m) => m.code), contains('complimentary'));
    expect(
        ticketPayModes(catalog, coverMode: 'cover_ticket').map((m) => m.code),
        <String>['cash', 'upi', 'card', 'custom_phonepe']);
  });

  test('logs carry no ticket code, number, guest, phone or search', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = original);

    await service.issue(sale());
    answer = (_, __) => <String, dynamic>{
          'kind': 'error',
          'code': 'price_changed',
          'message': 'Total is now ₹4,200.00',
        };
    await service.issue(sale());
    answer = (_, __) => fixture('ticket_check_in_already_used.json');
    await service.checkIn(TicketCheckInRequest(code: 'CDT:P3VJ5LDY2GQA7FEC'));
    await service.checkIn(
        TicketCheckInRequest(code: 'ET-042', method: CheckInMethod.manual));
    answer = (_, __) => fixture('ticket_recent_ack.json');
    await service.recent(query: 'Ravi 3210');

    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, isNot(contains('CDT:')));
      expect(line, isNot(contains('ET-04')));
      expect(line, isNot(contains('Ravi')));
      expect(line, isNot(contains('9876543210')));
      expect(line, isNot(contains('3210')));
    }
  });
}
