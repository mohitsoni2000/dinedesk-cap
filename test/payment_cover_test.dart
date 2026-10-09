import 'dart:async';
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
import 'package:restro/utils/payment_run.dart';
import 'package:restro/utils/tender_allocation.dart';
import 'package:restro/widgets/cover_redeem_section.dart';
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:restro/widgets/payment_sheet.dart';
import 'package:restro/widgets/tender_form.dart';

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
      // Sent in cover order, the cover-free room bill last.
      expect(_shape(calls), [
        [
          'food',
          [(_cover, const Money.rupees(300), code)]
        ],
        [
          'bev',
          [(_cover, const Money.rupees(200), code)]
        ],
        [
          'liquor',
          [(_cover, const Money.rupees(700), code)]
        ],
        [
          'combined',
          [
            (_cover, const Money.rupees(300), code),
            ('cash', const Money.rupees(200), null),
          ]
        ],
        [
          'room',
          [('cash', const Money.rupees(1000), null)]
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
          'food',
          [(_cover, const Money.rupees(300), code)]
        ],
        [
          'liquor',
          [
            (_cover, const Money.rupees(500), code),
            ('upi', const Money.rupees(200), null),
          ]
        ],
      ]);
      expect(calls.last.lines.last.reference, 'U1');
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
      final room = calls.singleWhere((c) => c.billId == 'room');
      expect(room.lines.any((l) => l.isCover), isFalse);
      expect(room.lines.single.amount, const Money.rupees(1000));
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

    test('calls carrying cover go first in cover order, the rest in bill order',
        () {
      final calls = planBillPayments(
        bills: <PlanBill>[
          _bill('liquor', 'liquor', 300),
          _bill('room', 'room', 100, eligible: false),
          _bill('food', 'food', 200),
          _bill('combined', 'combined', 100),
        ],
        covers: <AppliedCover>[_applied('et-042', 500, balance: 800)],
        coverMode: _cover,
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(200)),
        ],
      );
      // If the desk caps the ticket, the shortfall lands on liquor, not food.
      expect(calls.map((c) => c.billId),
          <String>['food', 'liquor', 'room', 'combined']);
    });

    test("tenders that don't add up to what is owed after cover are a bug", () {
      expect(
          () => planBillPayments(
                bills: <PlanBill>[_bill('food', 'food', 500)],
                covers: <AppliedCover>[_applied('et-042', 100)],
                coverMode: _cover,
                tenders: const <TenderLine>[
                  TenderLine(mode: 'cash', amount: Money.rupees(300)),
                ],
              ),
          throwsStateError);
      expect(
          () => planBillPayments(
                bills: <PlanBill>[_bill('food', 'food', 500)],
                covers: const <AppliedCover>[],
                coverMode: null,
                tenders: const <TenderLine>[TenderLine(mode: 'cash')],
              ),
          throwsArgumentError,
          reason: 'a fill line is for the desk to place');
      expect(
          planBillPayments(
            bills: <PlanBill>[_bill('food', 'food', 0)],
            covers: const <AppliedCover>[],
            coverMode: null,
            tenders: const <TenderLine>[],
          ),
          isEmpty,
          reason: 'nothing owed, nothing tendered');
    });
  });

  group('planCovers: what each staged ticket pays now', () {
    List<int> paid(List<AppliedCover> planned) =>
        <int>[for (final c in planned) c.amount.paise ~/ 100];

    test('in the order added: each its balance, up to what is left', () {
      final staged = <AppliedCover>[
        _applied('et-041', 800),
        _applied('et-043', 400),
      ];
      expect(paid(planCovers(staged, const Money.rupees(1050))), <int>[800, 250]);
      expect(paid(planCovers(staged, const Money.rupees(1500))), <int>[800, 400],
          reason: 'never more than a ticket has');
      expect(paid(planCovers(staged, const Money.rupees(500))), <int>[500, 0],
          reason: 'the first one added pays first; the second pays nothing');
      expect(paid(planCovers(staged, Money.zero)), <int>[0, 0]);
    });

    test('a ticket keeps what it is; only the amount follows the estimate', () {
      final staged = _applied('et-041', 800, balance: 800);
      final planned = planCovers(<AppliedCover>[staged], const Money.rupees(300))
          .single;
      expect(planned.amount, const Money.rupees(300));
      expect(planned.balance, const Money.rupees(800));
      expect(planned.key, staged.key);
      expect(planned.code, staged.code);
      expect(planned.toLine(_cover).toWire()['amount'], 300.0);
    });
  });

  group('refusedCovers: which ticket a refusal was about', () {
    final et41 = _applied('et-041', 800);
    final et43 = _applied('et-043', 400);

    test('one ticket sent: that one', () {
      expect(
          refusedCovers(
              code: 'cover_changed',
              refusal: coverErrorCopy('cover_changed')!,
              sent: <AppliedCover>[et41]),
          <AppliedCover>[et41]);
    });

    test('several: the one the desk names, by number or by code', () {
      expect(
          refusedCovers(
              code: 'cover_changed',
              refusal: 'Cover on ET-043 changed — now ₹300. Scan the ticket '
                  'again.',
              sent: <AppliedCover>[et41, et43]),
          <AppliedCover>[et43]);
      expect(
          refusedCovers(
              code: 'ticket_not_found',
              refusal: 'No ticket matches ${et41.code.toLowerCase()}',
              sent: <AppliedCover>[et41, et43]),
          <AppliedCover>[et41]);
    });

    test('a number is matched whole: ET-04 is not ET-041', () {
      final et04 = _applied('et-04', 100);
      expect(
          refusedCovers(
              code: 'cover_empty',
              refusal: 'No cover left on ET-041',
              sent: <AppliedCover>[et04, et41]),
          <AppliedCover>[et41]);
    });

    test('words that name none: all of them, to be scanned again', () {
      expect(
          refusedCovers(
              code: 'cover_changed',
              refusal: "This ticket's cover changed",
              sent: <AppliedCover>[et41, et43]),
          <AppliedCover>[et41, et43]);
    });

    test('a refusal not about a ticket takes none off', () {
      for (final code in <String?>[
        'cover_not_applicable',
        'payment_short',
        'price_changed',
        null,
      ]) {
        expect(
            refusedCovers(
                code: code,
                refusal: 'No cover left on ET-041',
                sent: <AppliedCover>[et41]),
            isEmpty,
            reason: '$code');
      }
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
      }, reason: 'always the amount shown: never left for the desk to fill');
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
      expect(coverErrorCopy('cover_changed'),
          "This ticket's cover changed since it was scanned — scan it again");
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

      // Food goes first: if the desk caps the ticket, liquor is short.
      expect(h.payloads(), <Map<String, dynamic>>[
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

    testWidgets('two tickets on one bill, one refused: the refusal names it',
        (tester) async {
      final h = await openWithCover(tester);
      final et41 = _fixture('ticket_lookup_ack.json');
      (et41['ticket'] as Map<String, dynamic>)
        ..['id'] = 'et_41a'
        ..['ticket_number'] = 'ET-041'
        ..['qr_code'] = 'CDT:7QKX2MZ4HB6TNW3R';
      et41['cover_balance'] = 400;
      h.answer = (event, data) => switch (event) {
            'ticket:lookup' => data['code'] == 'ET-041'
                ? et41
                : _fixture('ticket_lookup_ack.json'),
            _ => <String, dynamic>{
                'kind': 'error',
                'code': 'cover_empty',
                'message': 'No cover left on ET-041',
              },
          };
      await addTicket(tester, 'ET-042');
      await addTicket(tester, 'ET-041');
      expect(find.text('Cover pays it all'), findsOneWidget);
      await h.pay(tester);

      expect(h.payloads().single['payments'], hasLength(2));
      expect(find.text('No cover left on ET-041'), findsOneWidget,
          reason: 'the desk\'s words say which ticket');
      expect(find.text("This ticket's cover is used up"), findsNothing);
      await h.drainToasts(tester);
    });

    test('a refused cover is named only when two or more ride together', () {
      expect(
          namedTicketRefusal('cover_empty', 'No cover left on ET-041',
              tickets: 2),
          'No cover left on ET-041');
      expect(
          namedTicketRefusal('cover_empty', 'No cover left on ET-041',
              tickets: 1),
          isNull,
          reason: 'one ticket: the usual words are clear');
      expect(namedTicketRefusal('payment_short', 'Short', tickets: 2), isNull);
      expect(namedTicketRefusal('cover_empty', '  ', tickets: 2), isNull);
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

    group('when a payment goes through in part', () {
      const food300 = ServerBill(
          id: 'bill_food',
          billNumber: 'INV/001',
          totalAmount: Money.rupees(300),
          billType: 'food',
          isPaid: false);
      const liquor700 = ServerBill(
          id: 'bill_liquor',
          billNumber: 'INV/002',
          totalAmount: Money.rupees(700),
          billType: 'liquor',
          isPaid: false);
      Map<String, dynamic> lost() => <String, dynamic>{
            'kind': 'error',
            'code': AckCode.timeout,
            'message': "The desk didn't respond",
          };

      bool formEnabled(WidgetTester tester) =>
          tester.widget<TenderForm>(find.byType(TenderForm)).enabled;
      bool coverEnabled(WidgetTester tester) => tester
          .widget<CoverRedeemSection>(find.byType(CoverRedeemSection))
          .enabled;
      List<({String event, Map<String, dynamic> data})> billPayments(
              PaymentSheetHarness h) =>
          h.sent.where((s) => s.event == 'bill:payment').toList();

      testWidgets(
          '(a) refused after a bill went through: spent entries cleared, '
          'the rest planned at what it owes', (tester) async {
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
        h.answer = (event, data) =>
            data['bill_id'] == 'bill_liquor' && liquorTries++ == 0
                ? <String, dynamic>{
                    'kind': 'error',
                    'message': 'Payment amount ₹400 exceeds remaining ₹0.00',
                  }
                : <String, dynamic>{'kind': 'success'};
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(
            find.text('Settled 1 of 2. Take payment for the remaining ₹400.'),
            findsOneWidget);
        expect(
            find.text('₹400 still due — part of the payment went through. '
                'Take another payment for the rest.'),
            findsOneWidget);
        expect(find.text('CASH TENDERED'), findsNothing,
            reason: 'the spent cash is cleared');
        expect(h.payButton(tester).onPressed, isNull);
        expect(h.closed, isFalse);

        await tester.tap(find.text('UPI'));
        await tester.pump();
        await h.pay(tester);
        expect(h.payloads().last, <String, dynamic>{
          'bill_id': 'bill_liquor',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'upi', 'amount': 400.0},
          ],
        });
        expect(h.payloads().where((p) => p['bill_id'] == 'bill_food'),
            hasLength(1),
            reason: 'the settled bill is never sent again');
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets(
          '(b) a bill through, the next unanswered: form and cover lock, '
          'Pay finishes the rest', (tester) async {
        var liquorTries = 0;
        final h = await openWithCover(tester,
            bills: const <ServerBill>[liquor700, food300],
            payment: (data) =>
                data['bill_id'] == 'bill_liquor' && liquorTries++ == 0
                    ? lost()
                    : <String, dynamic>{'kind': 'success'});
        await addTicket(tester, 'ET-042');
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(h.closed, isFalse);
        expect(formEnabled(tester), isFalse);
        expect(coverEnabled(tester), isFalse);
        expect(
            find.text('Part of this payment went through. Pay retries the '
                'rest exactly as entered.'),
            findsOneWidget);
        expect(find.text('Settled 1 of 2. Retry sends only the remaining 1.'),
            findsOneWidget);
        await tester.tap(find.text('Add cover ticket'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Use'), findsNothing,
            reason: 'no ticket while locked');

        await h.pay(tester);
        final payments = billPayments(h);
        expect(payments.map((s) => s.data['bill_id']),
            <String>['bill_food', 'bill_liquor', 'bill_liquor']);
        expect(payments[2].data, payments[1].data,
            reason: 'the same payload and client_request_id');
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets('(c) a garbled answer counts as no answer: kept and locked',
          (tester) async {
        var tries = 0;
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        h.answer = (event, data) => tries++ == 0
            ? <String, dynamic>{
                'kind': 'error',
                'code': AckCode.badResponse,
                'message': 'Invalid server response',
              }
            : <String, dynamic>{'kind': 'success'};
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(h.closed, isFalse);
        expect(formEnabled(tester), isFalse);
        expect(find.text(kPaymentNoAnswer), findsWidgets);
        expect(find.textContaining('nothing was charged'), findsNothing);

        await h.pay(tester);
        expect(h.sent, hasLength(2));
        expect(h.sent[1].data, h.sent[0].data);
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets(
          '(d) cover refused on the second bill after the first went through',
          (tester) async {
        final h = await openWithCover(tester,
            bills: const <ServerBill>[liquor700, food300],
            payment: (data) => data['bill_id'] == 'bill_liquor'
                ? _fixture('bill_payment_cover_error_ack.json')
                : <String, dynamic>{'kind': 'success'});
        await addTicket(tester, 'ET-042');
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(billPayments(h).map((s) => s.data['bill_id']),
            <String>['bill_food', 'bill_liquor']);
        expect(find.text("This ticket's cover is used up"), findsOneWidget);
        expect(
            find.text('₹700 still due — part of the payment went through. '
                'Take another payment for the rest.'),
            findsOneWidget);
        expect(find.text('ET-042 · Couple Pass'), findsNothing,
            reason: 'the spent cover is cleared');
        expect(formEnabled(tester), isTrue);

        h.answer = (event, data) => <String, dynamic>{'kind': 'success'};
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);
        expect(h.payloads().last, <String, dynamic>{
          'bill_id': 'bill_liquor',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'cash', 'amount': 700.0},
          ],
        });
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets('(e) the first answer lost: kept, locked, resent identically',
          (tester) async {
        var tries = 0;
        final h = await openWithCover(tester,
            payment: (_) => tries++ == 0 ? lost() : paidAck());
        await addTicket(tester, 'ET-042');
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(h.closed, isFalse);
        expect(find.text(kPaymentNoAnswer), findsWidgets);
        expect(find.textContaining('nothing was charged'), findsNothing);
        expect(formEnabled(tester), isFalse);
        expect(coverEnabled(tester), isFalse);
        expect(find.text('ET-042 · Couple Pass'), findsOneWidget,
            reason: 'kept as planned');
        expect(h.payButton(tester).onPressed, isNotNull);

        await h.pay(tester);
        final payments = billPayments(h);
        expect(payments, hasLength(2));
        expect(payments[1].data, payments[0].data,
            reason: 'the same payload and client_request_id');
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets(
          'no answer, then the same resend refused: the sheet remembers — '
          'Close asks first and nothing says "nothing was charged"',
          (tester) async {
        var tries = 0;
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        h.answer = (event, data) => tries++ == 0
            ? lost()
            : <String, dynamic>{'kind': 'error', 'message': 'Internal error'};
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester); // no answer: kept
        await h.pay(tester); // the identical resend, refused
        expect(billPayments(h)[1].data, billPayments(h)[0].data);
        expect(
            find.text('Internal error. An earlier try got no answer — check '
                'the bill on the order screen.'),
            findsOneWidget);
        expect(
            find.text('An earlier try got no answer — check the bill on the '
                'order screen: it may have gone through. Check it before '
                'taking the money again.'),
            findsOneWidget);
        expect(formEnabled(tester), isTrue, reason: 'the run is let go');
        await h.drainToasts(tester);

        // A new try, refused too: still no "nothing was charged".
        await tester.tap(find.text('UPI'));
        await tester.pump();
        await h.pay(tester);
        expect(find.textContaining('nothing was charged'), findsNothing);
        await h.drainToasts(tester);

        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(h.closed, isFalse);
        expect(find.text('Close the payment?'), findsOneWidget,
            reason: 'money may have moved: closing asks first');
      });

      testWidgets('a resend long after the first try is still the same request',
          (tester) async {
        var now = DateTime(2026, 10, 9, 21);
        requestIdClock = () => now;
        addTearDown(() => requestIdClock = DateTime.now);
        var tries = 0;
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        h.answer = (event, data) =>
            tries++ == 0 ? lost() : <String, dynamic>{'kind': 'success'};
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        // Past the 15-minute intent ids; the desk replays for 48 hours.
        now = now.add(const Duration(minutes: 40));
        await h.pay(tester);
        final payments = billPayments(h);
        expect(payments, hasLength(2));
        expect(payments[1].data['client_request_id'],
            payments[0].data['client_request_id']);
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets(
          'a ticket looked up while Pay went ahead is not added under it',
          (tester) async {
        final lookup = Completer<Map<String, dynamic>>();
        final h = await openWithCover(tester);
        h.answer =
            (event, data) => event == 'ticket:lookup' ? lookup.future : lost();
        await tester.tap(find.text('Cash'));
        await tester.pump();
        final add = find.text('Add cover ticket');
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        await tester.enterText(
            fieldWithHint('Ticket number or QR code'), 'ET-042');
        await tester.tap(find.text('Use'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Checking the ticket…'), findsOneWidget);

        // Pressed where it is: scrolling to it could take the cover section
        // (still looking) out of the list.
        h.payButton(tester).onPressed!();
        await tester.pump(const Duration(milliseconds: 400));
        expect(formEnabled(tester), isFalse, reason: 'kept: no answer');

        lookup.complete(_fixture('ticket_lookup_ack.json'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('ET-042 · Couple Pass'), findsNothing);
        expect(find.text('Not added: the payment had already gone ahead'),
            findsOneWidget);
        await h.pay(tester);
        expect(billPayments(h)[1].data, billPayments(h)[0].data,
            reason: 'the resend is still the payment as planned');
        await h.drainToasts(tester);
      });

      testWidgets(
          'while a call is in flight: form and cover locked, back and a tap '
          'outside refused, Close off', (tester) async {
        final payment = Completer<Map<String, dynamic>>();
        final h = await openWithCover(tester);
        h.answer = (event, data) => event == 'ticket:lookup'
            ? _fixture('ticket_lookup_ack.json')
            : payment.future;
        await tester.tap(find.text('Cash'));
        await tester.pump();
        final pay = find.widgetWithText(LiquidPrimaryButton, 'Pay');
        await tester.ensureVisible(pay);
        await tester.tap(pay);
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Processing...'), findsOneWidget);
        expect(formEnabled(tester), isFalse);
        expect(coverEnabled(tester), isFalse);
        expect(
            tester
                .widget<LiquidSecondaryButton>(
                    find.widgetWithText(LiquidSecondaryButton, 'Cancel'))
                .onPressed,
            isNull,
            reason: 'Close is off while the desk is answering');

        await tester.binding.handlePopRoute(); // system back
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tapAt(const Offset(20, 20)); // the barrier
        await tester.pump(const Duration(milliseconds: 400));
        expect(h.closed, isFalse);
        expect(find.text('Close the payment?'), findsNothing,
            reason: 'nothing to confirm mid-flight: it just stays');

        payment.complete(paidAck());
        await tester.pumpAndSettle();
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets(
          'part paid: the header says what is still due, the rows which '
          'bill is paid; opened again, it starts from there', (tester) async {
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
        final dues = BillDues();
        final h = await PaymentSheetHarness.open(tester,
            bills: [food, liquor], dues: dues);
        expect(find.text('₹1,000'), findsOneWidget);
        var liquorTries = 0;
        h.answer = (event, data) =>
            data['bill_id'] == 'bill_liquor' && liquorTries++ == 0
                ? <String, dynamic>{'kind': 'error', 'message': 'Not now'}
                : <String, dynamic>{'kind': 'success'};
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(find.text('₹400 due'), findsOneWidget);
        expect(find.text('of ₹1,000'), findsOneWidget);
        expect(find.text('Paid'), findsOneWidget, reason: 'the food bill');
        await h.drainToasts(tester);

        // Closed with the rest still due, then opened again on the same
        // (stale) generated bills.
        final close = find.widgetWithText(LiquidSecondaryButton, 'Close');
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
        expect(h.closed, isTrue);
        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();

        expect(find.text('₹400 due'), findsOneWidget);
        expect(find.text('Paid'), findsOneWidget);
        await tester.tap(find.text('UPI'));
        await tester.pump();
        await h.pay(tester);
        expect(h.payloads().last, <String, dynamic>{
          'bill_id': 'bill_liquor',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'upi', 'amount': 400.0},
          ],
        });
        expect(h.payloads().where((p) => p['bill_id'] == 'bill_food'),
            hasLength(1),
            reason: 'the settled bill is never offered again');
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets('a short bill without cover is named plainly',
          (tester) async {
        var tries = 0;
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        h.answer = (event, data) {
          final ack = paidAck();
          if (tries++ == 0) {
            final bill = ack['bill'] as Map<String, dynamic>;
            bill['payment_status'] = 'partial';
            bill['payments'] = <Map<String, dynamic>>[
              <String, dynamic>{'payment_mode': 'cash', 'amount': 940},
            ];
          }
          return ack;
        };
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(
            find.text('₹10 is still due on Food · INV/26-27/001236. '
                'Take another payment for it.'),
            findsOneWidget);
        expect(find.textContaining('cover'), findsNothing);

        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);
        expect(h.payloads().last['payments'], <Map<String, dynamic>>[
          <String, dynamic>{'payment_mode': 'cash', 'amount': 10.0},
        ]);
        expect(h.result, isTrue);
        await h.drainToasts(tester);
      });

      testWidgets('a bill nothing landed on: the spent cover is cleared',
          (tester) async {
        const zero = ServerBill(
            id: 'bill_zero',
            billNumber: 'INV/000',
            totalAmount: Money.zero,
            billType: 'food',
            isPaid: false);
        final h = await openWithCover(tester,
            bills: const <ServerBill>[foodBill, zero]);
        await addTicket(tester, 'ET-042');
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);

        expect(
            h.payloads().map((p) => p['bill_id']), <String>['bill_b7e2_food']);
        expect(find.text('ET-042 · Couple Pass'), findsNothing);
        expect(find.text('Settled 1 of 2. Retry sends only the remaining 1.'),
            findsOneWidget);
        await h.drainToasts(tester);
      });

      testWidgets(
          'while money may have moved, a tap outside or a swipe keeps it '
          'open, and Close asks first', (tester) async {
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        h.answer = (event, data) => lost();
        await tester.tap(find.text('Cash'));
        await tester.pump();
        await h.pay(tester);
        await h.drainToasts(tester);

        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(h.closed, isFalse);
        expect(find.text('Close the payment?'), findsOneWidget);
        await tester.tap(find.text('Keep paying'));
        await tester.pumpAndSettle();
        expect(h.closed, isFalse);

        await tester.drag(find.text('Collect Payment'), const Offset(0, 1200));
        await tester.pumpAndSettle();
        expect(h.closed, isFalse, reason: 'a swipe does not close it');

        final close = find.widgetWithText(LiquidSecondaryButton, 'Close');
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(
            find.text('A payment may have gone through or part is still due '
                '— check the bill on the order screen.'),
            findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
        expect(h.closed, isTrue);
        expect(h.result, isNull);
      });

      testWidgets('an idle sheet still closes with a tap outside, as before',
          (tester) async {
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(h.closed, isTrue);
        expect(find.text('Close the payment?'), findsNothing);
      });

      testWidgets('an idle sheet still closes with a swipe, as before',
          (tester) async {
        final h = await PaymentSheetHarness.open(tester, bills: [foodBill]);
        await tester.drag(find.text('Collect Payment'), const Offset(0, 1200));
        await tester.pumpAndSettle();
        expect(h.closed, isTrue);
      });
    });
  });
}
