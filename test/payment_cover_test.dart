import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/bill_payment.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/services/entry_ticket_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/utils/request_id.dart';
import 'package:restro/utils/tender_allocation.dart';

import 'support/payment_sheet_harness.dart';

const _dir = 'test/fixtures/crew-qsr';
Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, dynamic>;

const _cover = 'cover_ticket';
const _et42Qr = 'CDT:P3VJ5LDY2GQA7FEC';

PlanBill _bill(String id, String type, int rupees, {bool eligible = true}) =>
    PlanBill(
        id: id,
        billType: type,
        due: Money.rupees(rupees),
        coverEligible: eligible);

AppliedCover _applied(String key, int rupees, {int? balance}) => AppliedCover(
      key: key,
      code: 'CDT:${key.toUpperCase().padRight(16, 'A')}',
      ticketNumber: key.toUpperCase(),
      typeName: 'Couple Pass',
      balance: Money.rupees(balance ?? rupees),
      amount: Money.rupees(rupees),
    );

/// Each call as [bill, [(mode, amount, ticket?)...]] (lists, so `expect`
/// compares them deeply; a record holding a list compares it by identity).
List<List<Object?>> _shape(List<BillPaymentCall> calls) => <List<Object?>>[
      for (final c in calls)
        <Object?>[
          c.billId,
          <(String, Money, String?)>[
            for (final l in c.lines) (l.mode, l.amount!, l.ticketCode),
          ],
        ],
    ];

/// A guest's entry-ticket cover, taken as payment on a food or drink bill:
/// food first, then beverages, liquor and a combined bill; never a room bill.
void main() {
  setUp(resetRequestIds);

  group('ServerBill.isPaid reads the desk', () {
    // A desk bill as bill:payment and bill:generate send it: `status` is the
    // bill's life (active / voided), `payment_status` says whether it is paid.
    Map<String, dynamic> deskBill() => Map<String, dynamic>.from(
        _fixture('bill_payment_cover_ack.json')['bill'] as Map);

    test('payment_status paid on an active bill is paid', () {
      final bill = ServerBill.fromMap(deskBill());
      expect(bill.isPaid, isTrue);
    });

    test('credit counts as settled; unpaid and partial do not', () {
      ServerBill withStatus(String s) =>
          ServerBill.fromMap(deskBill()..['payment_status'] = s);
      expect(withStatus('credit').isPaid, isTrue);
      expect(withStatus('unpaid').isPaid, isFalse);
      expect(withStatus('partial').isPaid, isFalse);
    });

    test('the older shapes still read as before', () {
      Map<String, dynamic> bare(Map<String, dynamic> extra) =>
          <String, dynamic>{
            'id': 'b',
            'total_amount': 100,
            ...extra,
          };
      expect(ServerBill.fromMap(bare(<String, dynamic>{'is_paid': 1})).isPaid,
          isTrue);
      expect(
          ServerBill.fromMap(bare(<String, dynamic>{'status': 'settled'}))
              .isPaid,
          isTrue);
      expect(ServerBill.fromMap(bare(<String, dynamic>{})).isPaid, isFalse);
    });

    test('a voided or comp bill says so', () {
      final voided = ServerBill.fromMap(deskBill()..['status'] = 'voided');
      expect(voided.isVoided, isTrue);
      final comp = ServerBill.fromMap(deskBill()..['comp_reason'] = 'Owner');
      expect(comp.isComp, isTrue);
      final plain = ServerBill.fromMap(deskBill());
      expect(plain.isVoided, isFalse);
      expect(plain.isComp, isFalse);
    });
  });

  group('which bills cover may pay', () {
    ServerBill bill(String type,
            {bool paid = false, bool voided = false, bool comp = false}) =>
        ServerBill(
            id: type,
            billNumber: '',
            totalAmount: const Money.rupees(100),
            billType: type,
            isPaid: paid,
            isVoided: voided,
            isComp: comp);

    test('any open food or drink bill; never room or banquet', () {
      for (final type in <String>['food', 'beverages', 'liquor', 'combined']) {
        expect(isCoverEligible(bill(type)), isTrue, reason: type);
      }
      expect(isCoverEligible(bill('room')), isFalse);
      expect(isCoverEligible(bill('banquet')), isFalse);
    });

    test('not one already paid or on credit, voided, or given away', () {
      expect(isCoverEligible(bill('food', paid: true)), isFalse);
      expect(isCoverEligible(bill('food', voided: true)), isFalse);
      expect(isCoverEligible(bill('food', comp: true)), isFalse);
    });
  });

  group('planBillPayments', () {
    test('cover goes food, beverages, liquor, combined, and never room', () {
      final calls = planBillPayments(
        bills: <PlanBill>[
          _bill('liquor', 'liquor', 700),
          _bill('room', 'room', 1000, eligible: false),
          _bill('combined', 'combined', 500),
          _bill('food', 'food', 300),
          _bill('bev', 'beverages', 200),
        ],
        covers: <AppliedCover>[_applied('et-041', 1500)],
        coverMode: _cover,
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(1200)),
        ],
      );
      final code = _applied('et-041', 1500).code;
      expect(_shape(calls), [
        [
          'liquor',
          [(_cover, const Money.rupees(700), code)]
        ],
        [
          'room',
          [('cash', const Money.rupees(1000), null)]
        ],
        [
          'combined',
          [
            (_cover, const Money.rupees(300), code),
            ('cash', const Money.rupees(200), null),
          ]
        ],
        [
          'food',
          [(_cover, const Money.rupees(300), code)]
        ],
        [
          'bev',
          [(_cover, const Money.rupees(200), code)]
        ],
      ]);
    });

    test('a liquor-only bill takes cover', () {
      final calls = planBillPayments(
        bills: <PlanBill>[_bill('liquor', 'liquor', 650)],
        covers: <AppliedCover>[_applied('et-042', 650, balance: 800)],
        coverMode: _cover,
        tenders: const <TenderLine>[],
      );
      expect(calls.single.lines.single.amount, const Money.rupees(650));
      expect(calls.single.lines.single.isCover, isTrue);
    });

    test('two tickets stack: the first fills before the second starts', () {
      final calls = planBillPayments(
        bills: <PlanBill>[_bill('food', 'food', 950)],
        covers: <AppliedCover>[
          _applied('et-041', 800),
          _applied('et-042', 150, balance: 800),
        ],
        coverMode: _cover,
        tenders: const <TenderLine>[],
      );
      expect(calls.single.lines.map((l) => (l.ticketCode, l.amount)), [
        (_applied('et-041', 0).code, const Money.rupees(800)),
        (_applied('et-042', 0).code, const Money.rupees(150)),
      ]);
    });

    test('one ticket across food and liquor: food first, the rest on liquor',
        () {
      final calls = planBillPayments(
        bills: <PlanBill>[
          _bill('liquor', 'liquor', 700),
          _bill('food', 'food', 300),
        ],
        covers: <AppliedCover>[_applied('et-042', 800)],
        coverMode: _cover,
        tenders: const <TenderLine>[
          TenderLine(mode: 'upi', amount: Money.rupees(200), reference: 'U1'),
        ],
      );
      final code = _applied('et-042', 0).code;
      expect(_shape(calls), [
        [
          'liquor',
          [
            (_cover, const Money.rupees(500), code),
            ('upi', const Money.rupees(200), null),
          ]
        ],
        [
          'food',
          [(_cover, const Money.rupees(300), code)]
        ],
      ]);
      expect(calls.first.lines.last.reference, 'U1');
    });

    test('other tenders split by what each bill still owes after cover', () {
      final calls = planBillPayments(
        bills: <PlanBill>[
          _bill('food', 'food', 600),
          _bill('liquor', 'liquor', 400),
        ],
        covers: <AppliedCover>[_applied('et-042', 400)],
        coverMode: _cover,
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(300)),
          TenderLine(mode: 'card', amount: Money.rupees(300)),
        ],
      );
      // After cover: food owes 200, liquor 400. Each tender splits 1:2.
      expect(_shape(calls), [
        [
          'food',
          [
            (_cover, const Money.rupees(400), _applied('et-042', 0).code),
            ('cash', const Money.rupees(100), null),
            ('card', const Money.rupees(100), null),
          ]
        ],
        [
          'liquor',
          [
            ('cash', const Money.rupees(200), null),
            ('card', const Money.rupees(200), null),
          ]
        ],
      ]);
    });

    test('a room bill gets no cover, even with cover left over', () {
      final calls = planBillPayments(
        bills: <PlanBill>[
          _bill('room', 'room', 1000, eligible: false),
          _bill('food', 'food', 200),
        ],
        covers: <AppliedCover>[_applied('et-042', 200, balance: 800)],
        coverMode: _cover,
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(1000)),
        ],
      );
      expect(calls.first.billId, 'room');
      expect(calls.first.lines.any((l) => l.isCover), isFalse);
      expect(calls.first.lines.single.amount, const Money.rupees(1000));
    });

    test('without cover it is the old split exactly', () {
      final bills = <PlanBill>[
        _bill('food', 'food', 600),
        _bill('liquor', 'liquor', 400),
      ];
      const tenders = <TenderLine>[
        TenderLine(mode: 'cash', amount: Money.rupees(300)),
        TenderLine(mode: 'upi', amount: Money.rupees(700)),
      ];
      final calls = planBillPayments(
          bills: bills,
          covers: const <AppliedCover>[],
          coverMode: null,
          tenders: tenders);
      final old = allocateTenders(bills: <BillWeight>[
        for (final b in bills) (billId: b.id, weight: b.due),
      ], tenders: tenders);
      expect(<String, List<Map<String, dynamic>>>{
        for (final c in calls)
          c.billId: <Map<String, dynamic>>[for (final l in c.lines) l.toWire()],
      }, <String, List<Map<String, dynamic>>>{
        for (final e in old.entries)
          e.key: <Map<String, dynamic>>[for (final l in e.value) l.toWire()],
      });
      expect(calls.first.toPayload().keys, <String>['bill_id', 'payments']);
    });

    test('more cover than the bills it may pay can take is a bug, not a split',
        () {
      expect(
          () => planBillPayments(
                bills: <PlanBill>[_bill('food', 'food', 100)],
                covers: <AppliedCover>[_applied('et-042', 800)],
                coverMode: _cover,
                tenders: const <TenderLine>[],
              ),
          throwsArgumentError);
    });
  });

  group('adding a ticket (decideCover)', () {
    LookupResult et42({Money? balance, bool canRedeem = true, String? reason}) {
      final ack = _fixture('ticket_lookup_ack.json');
      if (balance != null) ack['cover_balance'] = balance.toWire();
      ack['can_redeem'] = canRedeem;
      if (reason != null) ack['reason'] = reason;
      return LookupResult.fromAck(ack);
    }

    test('takes the smaller of its balance and what cover may still pay', () {
      final big = decideCover(
          lookup: et42(),
          entered: 'ET-042',
          existing: const <AppliedCover>[],
          coverable: const Money.rupees(950));
      expect((big as CoverAccepted).cover.amount, const Money.rupees(800));
      final small = decideCover(
          lookup: et42(),
          entered: 'ET-042',
          existing: const <AppliedCover>[],
          coverable: const Money.rupees(300));
      expect((small as CoverAccepted).cover.amount, const Money.rupees(300));
      expect(small.cover.balance, const Money.rupees(800));
    });

    test('pays by the ticket QR and shows its number', () {
      final added = decideCover(
          lookup: et42(),
          entered: ' 42 ',
          existing: const <AppliedCover>[],
          coverable: const Money.rupees(950)) as CoverAccepted;
      expect(added.cover.code, _et42Qr);
      expect(added.cover.ticketNumber, 'ET-042');
      expect(added.cover.typeName, 'Couple Pass');
      expect(added.cover.toLine(_cover).toWire(), <String, dynamic>{
        'payment_mode': _cover,
        'amount': 800.0,
        'ticket_code': _et42Qr,
      });
      expect(added.cover.toLine(_cover, fill: true).toWire(),
          <String, dynamic>{'payment_mode': _cover, 'ticket_code': _et42Qr},
          reason: 'the counter lets the desk fill it');
    });

    test('the same ticket twice is refused, however it was typed', () {
      final first = (decideCover(
              lookup: et42(),
              entered: _et42Qr,
              existing: const <AppliedCover>[],
              coverable: const Money.rupees(2000)) as CoverAccepted)
          .cover;
      final again = decideCover(
          lookup: et42(),
          entered: 'et-42',
          existing: <AppliedCover>[first],
          coverable: const Money.rupees(1200));
      expect((again as CoverRefused).message,
          'This ticket is already on this payment');
    });

    test('nothing left that cover may pay', () {
      final refused = decideCover(
          lookup: et42(),
          entered: 'ET-042',
          existing: const <AppliedCover>[],
          coverable: Money.zero);
      expect((refused as CoverRefused).message,
          'Nothing left here that cover can pay');
    });

    test('a ticket that cannot pay says why, in staff words', () {
      String why(String reason, {String? desk}) => (decideCover(
              lookup: et42(canRedeem: false, reason: reason),
              entered: 'ET-042',
              existing: const <AppliedCover>[],
              coverable: const Money.rupees(950),
              deskMessage: desk) as CoverRefused)
          .message;
      expect(why('not_found'), 'No ticket matches that code');
      expect(why('cancelled'), 'This ticket was cancelled');
      expect(why('expired'), 'This ticket was for an earlier day');
      expect(why('no_cover'), 'This ticket has no cover to spend');
      expect(why('used_up'), "This ticket's cover is used up");
      expect(
          why('blocked_by_owner', desk: 'Ask the manager'), 'Ask the manager');
      expect(why('blocked_by_owner'), "This ticket can't pay a bill");
    });

    test('a redeemable ticket with nothing left reads as used up', () {
      final refused = decideCover(
          lookup: et42(balance: Money.zero),
          entered: 'ET-042',
          existing: const <AppliedCover>[],
          coverable: const Money.rupees(950));
      expect(
          (refused as CoverRefused).message, "This ticket's cover is used up");
    });
  });

  group('desk error codes', () {
    test("the spec's cover codes in staff words; anything else is the desk's",
        () {
      expect(coverErrorCopy('cover_empty'), "This ticket's cover is used up");
      expect(coverErrorCopy('cover_expired'),
          'This ticket was for an earlier day');
      expect(coverErrorCopy('cover_not_applicable'),
          "Cover can't pay a room, comp or credit bill");
      expect(coverErrorCopy('cover_invalid'),
          "This ticket can't be used as cover");
      expect(coverErrorCopy('ticket_not_found'), 'No ticket matches that code');
      expect(coverErrorCopy('ticket_cancelled'), 'This ticket was cancelled');
      for (final code in <String>[
        'payment_invalid',
        'payment_short',
        'payment_over',
      ]) {
        expect(coverErrorCopy(code), isNotNull, reason: code);
      }
      // Dropped from blueprint 12: no check-in or redeem right, and the
      // desk caps cover instead of refusing it.
      for (final code in <String?>[
        'not_checked_in',
        'redeem_disabled',
        'cover_insufficient',
        'cover_exceeds_due',
        null,
      ]) {
        expect(coverErrorCopy(code), isNull, reason: code);
      }
    });
  });

  group('bill:payment acks (fixtures)', () {
    test('cover and cash on a food bill: the cover result and a paid bill', () {
      final ack =
          BillPaymentAck.fromAck(_fixture('bill_payment_cover_ack.json'));
      expect(ack.results, hasLength(2));
      final cover = ack.results.first.cover!;
      expect(cover.ticketCode, _et42Qr);
      expect(cover.ticketNumber, 'ET-042');
      expect(cover.balanceAfter, Money.zero);
      expect(ack.results.first.billPaymentStatus, 'partial');
      expect(ack.results.last.cover, isNull);
      expect(ack.results.last.billPaymentStatus, 'paid');
      expect(ack.bill!.id, 'bill_b7e2_food');
      expect(ack.bill!.isPaid, isTrue);
      expect(ack.recorded, const Money.rupees(950));
      expect(ack.remaining, Money.zero);
      expect(ack.orderSettled, isTrue);
    });

    test('a capped cover reads as money still due', () {
      final raw = _fixture('bill_payment_cover_ack.json');
      final bill = raw['bill'] as Map<String, dynamic>;
      bill['payment_status'] = 'partial';
      ((bill['payments'] as List<dynamic>).first
          as Map<String, dynamic>)['amount'] = 700;
      (bill['payments'] as List<dynamic>).add(<String, dynamic>{
        'id': 'pay_refund',
        'payment_mode': 'refund_due',
        'amount': 40,
      });
      final ack = BillPaymentAck.fromAck(raw);
      expect(ack.recorded, const Money.rupees(850),
          reason: 'a refund_due row is not money taken');
      expect(ack.remaining, const Money.rupees(100));
    });

    test('an ack without a readable bill counts as settled (older desk)', () {
      final ack = BillPaymentAck.fromAck(<String, dynamic>{'kind': 'success'});
      expect(ack.remaining, isNull);
      expect(ack.results, isEmpty);
    });

    test('the refused cover: its code, and the words staff see', () {
      final err =
          AckError.fromAck(_fixture('bill_payment_cover_error_ack.json'));
      expect(err.code, 'cover_empty');
      expect(err.message, 'No cover left on ET-042');
      expect(coverErrorCopy(err.code), "This ticket's cover is used up");
    });
  });

  group('EntryTicketService.lookup', () {
    late SocketService socket;
    final sent = <Map<String, dynamic>>[];

    setUp(() {
      sent.clear();
      socket = SocketService()..debugSetState(SocketState.verified);
    });
    tearDown(() => socket.dispose());

    test('asks to redeem with the code as typed, trimmed', () async {
      socket.rawEmitOverride = (event, data, timeout) async {
        sent.add(<String, dynamic>{'event': event, ...data});
        return _fixture('ticket_lookup_ack.json');
      };
      final outcome = await EntryTicketService(socket).lookup('  et-42 ');
      expect(sent.single, <String, dynamic>{
        'event': 'ticket:lookup',
        'code': 'et-42',
        'purpose': 'redeem',
      });
      final found = outcome as TicketFound;
      expect(found.result.canRedeem, isTrue);
      expect(found.result.ticket!.ticketNumber, 'ET-042');
    });

    test('a refusal is worded; a dropped link says so', () async {
      socket.rawEmitOverride = (event, data, timeout) async =>
          <String, dynamic>{
            'kind': 'error',
            'code': 'ticket_not_found',
            'message': 'TICKET_NOT_FOUND'
          };
      final refused = await EntryTicketService(socket).lookup('99');
      expect((refused as TicketLookupFailed).message,
          'No ticket matches that code');

      socket.rawEmitOverride = (event, data, timeout) async =>
          <String, dynamic>{'kind': 'error', 'message': 'Not allowed here'};
      final other = await EntryTicketService(socket).lookup('99');
      expect((other as TicketLookupFailed).message, 'Not allowed here');

      socket.debugSetState(SocketState.disconnected);
      final dropped = await EntryTicketService(socket).lookup('99');
      expect((dropped as TicketLookupFailed).message,
          "Couldn't reach the desk — try again");
    });
  });

  group('the payment sheet with cover', () {
    const coverFlags = FeatureFlags(entryTickets: true, collectPayment: true);
    const coverConfig = TicketConfig(coverPaymentMode: _cover);
    const foodBill = ServerBill(
        id: 'bill_b7e2_food',
        billNumber: 'INV/26-27/001236',
        totalAmount: Money.rupees(950),
        billType: 'food',
        isPaid: false);

    Map<String, dynamic> paidAck() => _fixture('bill_payment_cover_ack.json');

    /// Answers the lookup from the fixture and bill:payment with [payment].
    Future<PaymentSheetHarness> openWithCover(
      WidgetTester tester, {
      List<ServerBill> bills = const <ServerBill>[foodBill],
      Map<String, dynamic> Function(Map<String, dynamic> data)? payment,
      Map<String, dynamic> Function()? lookup,
    }) async {
      final h = await PaymentSheetHarness.open(tester,
          bills: bills, flags: coverFlags, ticketConfig: coverConfig);
      h.answer = (event, data) => switch (event) {
            'ticket:lookup' =>
              (lookup ?? () => _fixture('ticket_lookup_ack.json'))(),
            _ => (payment ?? (_) => paidAck())(data),
          };
      return h;
    }

    Future<void> addTicket(WidgetTester tester, String code) async {
      final button = find.text('Add cover ticket');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.enterText(fieldWithHint('Ticket number or QR code'), code);
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
    }

    testWidgets('no cover section unless tickets, payment and a cover mode',
        (tester) async {
      await PaymentSheetHarness.open(tester,
          bills: [foodBill], flags: coverFlags);
      expect(find.text('COVER TICKET'), findsNothing,
          reason: 'the desk names no cover mode');
      await tester.pumpWidget(const SizedBox());
      await PaymentSheetHarness.open(tester,
          bills: [foodBill],
          flags: const FeatureFlags(collectPayment: true),
          ticketConfig: coverConfig);
      expect(find.text('COVER TICKET'), findsNothing,
          reason: 'entry tickets are off');
      await tester.pumpWidget(const SizedBox());
      await PaymentSheetHarness.open(tester,
          bills: [foodBill],
          flags: const FeatureFlags(entryTickets: true),
          ticketConfig: coverConfig);
      expect(find.text('COVER TICKET'), findsNothing,
          reason: 'this user may not collect payment');
      await tester.pumpWidget(const SizedBox());
      await PaymentSheetHarness.open(tester,
          bills: [foodBill], flags: coverFlags, ticketConfig: coverConfig);
      expect(find.text('COVER TICKET'), findsOneWidget);
    });

    testWidgets('apply a ticket, then remove it', (tester) async {
      final h = await openWithCover(tester);
      await addTicket(tester, 'ET-042');

      expect(h.sent.single.event, 'ticket:lookup');
      expect(find.text('ET-042 · Couple Pass'), findsOneWidget);
      expect(find.text('−₹800'), findsOneWidget);
      expect(find.text('To collect'), findsOneWidget);
      expect(find.text('₹150'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove ET-042'));
      await tester.pumpAndSettle();
      expect(find.text('ET-042 · Couple Pass'), findsNothing);
      expect(find.text('To collect'), findsNothing);
      expect(h.payloads(), isEmpty, reason: 'nothing is charged until Pay');
    });

    testWidgets('cover and cash: one bill:payment, the cover first',
        (tester) async {
      final h = await openWithCover(tester);
      await addTicket(tester, 'ET-042');
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(h.payloads(), <Map<String, dynamic>>[
        <String, dynamic>{
          'bill_id': 'bill_b7e2_food',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{
              'payment_mode': _cover,
              'amount': 800.0,
              'ticket_code': _et42Qr,
            },
            <String, dynamic>{'payment_mode': 'cash', 'amount': 150.0},
          ],
        },
      ]);
      expect(h.result, isTrue);
    });

    testWidgets('cover that pays it all needs no mode', (tester) async {
      const small = ServerBill(
          id: 'bill_b7e2_food',
          billNumber: 'INV/26-27/001236',
          totalAmount: Money.rupees(600),
          billType: 'food',
          isPaid: false);
      final h = await openWithCover(tester, bills: [small]);
      await addTicket(tester, 'ET-042');
      expect(find.text('−₹600'), findsOneWidget);
      expect(find.text('Cover pays it all'), findsOneWidget);
      expect(find.text('PAYMENT MODE'), findsNothing);
      await h.pay(tester);
      expect(h.payloads().single['payments'], <Map<String, dynamic>>[
        <String, dynamic>{
          'payment_mode': _cover,
          'amount': 600.0,
          'ticket_code': _et42Qr,
        },
      ]);
    });

    testWidgets('food and liquor: cover fills food first, cash takes the rest',
        (tester) async {
      const food = ServerBill(
          id: 'bill_food',
          billNumber: 'INV/001',
          totalAmount: Money.rupees(300),
          billType: 'food',
          isPaid: false);
      const liquor = ServerBill(
          id: 'bill_liquor',
          billNumber: 'INV/002',
          totalAmount: Money.rupees(700),
          billType: 'liquor',
          isPaid: false);
      final h = await openWithCover(tester,
          bills: [liquor, food],
          payment: (_) => <String, dynamic>{'kind': 'success'});
      await addTicket(tester, 'ET-042');
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(h.payloads(), <Map<String, dynamic>>[
        <String, dynamic>{
          'bill_id': 'bill_liquor',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{
              'payment_mode': _cover,
              'amount': 500.0,
              'ticket_code': _et42Qr,
            },
            <String, dynamic>{'payment_mode': 'cash', 'amount': 200.0},
          ],
        },
        <String, dynamic>{
          'bill_id': 'bill_food',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{
              'payment_mode': _cover,
              'amount': 300.0,
              'ticket_code': _et42Qr,
            },
          ],
        },
      ]);
      expect(h.result, isTrue);
    });

    testWidgets('a capped cover keeps the sheet open on the shortfall',
        (tester) async {
      var calls = 0;
      final h = await openWithCover(tester, payment: (data) {
        calls++;
        final ack = paidAck();
        if (calls == 1) {
          // The desk had less cover left than the lookup said: ₹700 of 800.
          final bill = ack['bill'] as Map<String, dynamic>;
          bill['payment_status'] = 'partial';
          ((bill['payments'] as List<dynamic>).first
              as Map<String, dynamic>)['amount'] = 700;
        }
        return ack;
      });
      await addTicket(tester, 'ET-042');
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(h.closed, isFalse, reason: 'not reported as paid');
      expect(find.textContaining('₹100 still due'), findsWidgets);
      expect(find.text('ET-042 · Couple Pass'), findsNothing,
          reason: 'what was entered is spent');

      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);
      expect(h.payloads().last, <String, dynamic>{
        'bill_id': 'bill_b7e2_food',
        'payments': <Map<String, dynamic>>[
          <String, dynamic>{'payment_mode': 'cash', 'amount': 100.0},
        ],
      });
      expect(h.result, isTrue);
      await h.drainToasts(tester);
    });

    testWidgets('a refused cover says why and charges nothing', (tester) async {
      final h = await openWithCover(tester,
          payment: (_) => _fixture('bill_payment_cover_error_ack.json'));
      await addTicket(tester, 'ET-042');
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(find.text("This ticket's cover is used up"), findsOneWidget);
      expect(h.closed, isFalse);
      expect(find.text('ET-042 · Couple Pass'), findsOneWidget,
          reason: 'nothing went through: what was entered stays to fix');
      await h.drainToasts(tester);
    });

    testWidgets('a lost ack is retried with the same payload and id',
        (tester) async {
      var calls = 0;
      final h = await openWithCover(tester,
          payment: (_) => calls++ == 0
              ? <String, dynamic>{
                  'kind': 'error',
                  'code': AckCode.timeout,
                  'message': "The desk didn't respond",
                }
              : paidAck());
      await addTicket(tester, 'ET-042');
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);
      expect(h.closed, isFalse);
      await h.pay(tester);

      final payments = h.sent.where((s) => s.event == 'bill:payment').toList();
      expect(payments, hasLength(2));
      expect(payments[1].data, payments[0].data,
          reason: 'same allocation, same client_request_id');
      expect(h.result, isTrue);
      await h.drainToasts(tester);
    });

    testWidgets('after one bill went through, a retry resends only the rest',
        (tester) async {
      const food = ServerBill(
          id: 'bill_food',
          billNumber: 'INV/001',
          totalAmount: Money.rupees(600),
          billType: 'food',
          isPaid: false);
      const liquor = ServerBill(
          id: 'bill_liquor',
          billNumber: 'INV/002',
          totalAmount: Money.rupees(400),
          billType: 'liquor',
          isPaid: false);
      final h = await PaymentSheetHarness.open(tester, bills: [food, liquor]);
      var liquorTries = 0;
      h.answer = (event, data) {
        if (data['bill_id'] == 'bill_liquor' && liquorTries++ == 0) {
          return <String, dynamic>{
            'kind': 'error',
            'code': AckCode.timeout,
            'message': "The desk didn't respond",
          };
        }
        return <String, dynamic>{'kind': 'success'};
      };
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);
      await h.pay(tester);

      expect(h.sent.map((s) => s.data['bill_id']),
          <String>['bill_food', 'bill_liquor', 'bill_liquor']);
      expect(h.sent[2].data, h.sent[1].data,
          reason: 'the kept share and the same client_request_id');
      expect(h.result, isTrue);
      await h.drainToasts(tester);
    });

    testWidgets('a ticket that cannot pay shows why', (tester) async {
      final h = await openWithCover(tester, lookup: () {
        final ack = _fixture('ticket_lookup_ack.json');
        ack['can_redeem'] = false;
        ack['reason'] = 'expired';
        ack['cover_balance'] = 0;
        return ack;
      });
      await addTicket(tester, 'ET-042');
      expect(find.text('This ticket was for an earlier day'), findsOneWidget);
      expect(find.text('ET-042 · Couple Pass'), findsNothing);
      expect(h.payloads(), isEmpty);
    });

    testWidgets('the same ticket twice is refused', (tester) async {
      await openWithCover(tester, bills: const <ServerBill>[
        ServerBill(
            id: 'bill_big',
            billNumber: 'INV/9',
            totalAmount: Money.rupees(2000),
            billType: 'food',
            isPaid: false),
      ]);
      await addTicket(tester, 'ET-042');
      await addTicket(tester, _et42Qr);
      expect(find.text('ET-042 · Couple Pass'), findsOneWidget);
      expect(
          find.text('This ticket is already on this payment'), findsOneWidget);
    });

    testWidgets('a room bill alone leaves nothing for cover', (tester) async {
      await openWithCover(tester, bills: const <ServerBill>[
        ServerBill(
            id: 'bill_room',
            billNumber: 'RM/1',
            totalAmount: Money.rupees(3000),
            billType: 'room',
            isPaid: false),
      ]);
      await addTicket(tester, 'ET-042');
      expect(find.text('Nothing left here that cover can pay'), findsOneWidget);
    });
  });
}
