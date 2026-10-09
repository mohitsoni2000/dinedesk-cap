import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/utils/request_id.dart';
import 'package:restro/utils/tender_allocation.dart';

import 'support/payment_sheet_harness.dart';

/// One payment entry as the sheet's old `_PaymentEntry` held it.
typedef _OldEntry = ({
  String mode,
  Money amount,
  String? reference,
  String? notes
});

/// The tender split exactly as payment_sheet.dart `_pay` did it inline before
/// it was pulled out (the loop body and `_PaymentEntry.toMap`, verbatim):
/// the oracle [allocateTenders] must match.
Map<String, List<Map<String, dynamic>>> _oldInlineLoop(
  List<({String id, Money total})> outstanding,
  List<_OldEntry> entries,
) {
  final billWeights = outstanding.map((b) => b.total).toList(growable: false);
  final perBillPayments = <String, List<Map<String, dynamic>>>{
    for (final bill in outstanding) bill.id: <Map<String, dynamic>>[],
  };
  for (final entry in entries) {
    final shares = allocateProportionally(entry.amount, billWeights);
    for (var i = 0; i < outstanding.length; i++) {
      final share = shares[i];
      if (share.isZero) continue;
      perBillPayments[outstanding[i].id]!.add(<String, dynamic>{
        'payment_mode': entry.mode,
        'amount': share.toWire(),
        if (entry.reference != null && entry.reference!.isNotEmpty)
          'reference_number': entry.reference,
        if (entry.notes != null && entry.notes!.isNotEmpty)
          'notes': entry.notes,
      });
    }
  }
  return perBillPayments;
}

Map<String, List<Map<String, dynamic>>> _extracted(
  List<({String id, Money total})> outstanding,
  List<_OldEntry> entries,
) {
  final split = allocateTenders(
    bills: <BillWeight>[
      for (final b in outstanding) (billId: b.id, weight: b.total),
    ],
    tenders: <TenderLine>[
      for (final e in entries)
        TenderLine(
            mode: e.mode,
            amount: e.amount,
            reference: e.reference,
            notes: e.notes),
    ],
  );
  return <String, List<Map<String, dynamic>>>{
    for (final entry in split.entries)
      entry.key: <Map<String, dynamic>>[
        for (final line in entry.value) line.toWire(),
      ],
  };
}

/// What the payment sheet sends, pinned before the cover work: the split of
/// tenders across bills, the modes it offers, the `bill:payment` payloads and
/// the toasts. The sheet tests ran green against the sheet as it was, and
/// must stay green with every new flag off.
void main() {
  setUp(resetRequestIds);

  group('allocateTenders (the split pulled out of the sheet, unchanged)', () {
    test('one bill takes every tender whole', () {
      expect(
          _extracted(<({String id, Money total})>[
            (id: 'a', total: const Money.rupees(945)),
          ], <_OldEntry>[
            (
              mode: 'cash',
              amount: const Money.rupees(945),
              reference: null,
              notes: null
            ),
          ]),
          <String, List<Map<String, dynamic>>>{
            'a': <Map<String, dynamic>>[
              <String, dynamic>{'payment_mode': 'cash', 'amount': 945.0},
            ],
          });
    });

    test('the grand total over several bills lands on each bill exactly', () {
      final split = allocateTenders(
        bills: const <BillWeight>[
          (billId: 'food', weight: Money(33333)),
          (billId: 'liquor', weight: Money(16667)),
        ],
        tenders: const <TenderLine>[
          TenderLine(mode: 'upi', amount: Money(50000), reference: 'UTR1'),
        ],
      );
      expect(split['food']!.single.amount, const Money(33333));
      expect(split['liquor']!.single.amount, const Money(16667));
      expect(split['food']!.single.reference, 'UTR1');
    });

    test('each tender is split in proportion, in tender order per bill', () {
      final split = allocateTenders(
        bills: const <BillWeight>[
          (billId: 'food', weight: Money.rupees(600)),
          (billId: 'liquor', weight: Money.rupees(400)),
        ],
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(300)),
          TenderLine(mode: 'upi', amount: Money.rupees(700)),
        ],
      );
      expect(split['food']!.map((l) => (l.mode, l.amount)), [
        ('cash', const Money.rupees(180)),
        ('upi', const Money.rupees(420)),
      ]);
      expect(split['liquor']!.map((l) => (l.mode, l.amount)), [
        ('cash', const Money.rupees(120)),
        ('upi', const Money.rupees(280)),
      ]);
    });

    test(
        'left-over paise go to the largest remainder, ties to the earlier bill',
        () {
      final split = allocateTenders(
        bills: const <BillWeight>[
          (billId: 'a', weight: Money.rupees(1)),
          (billId: 'b', weight: Money.rupees(1)),
          (billId: 'c', weight: Money.rupees(1)),
        ],
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(100)),
        ],
      );
      expect(split.values.map((lines) => lines.single.amount),
          const <Money>[Money(3334), Money(3333), Money(3333)]);
    });

    test('a bill whose share rounds to nothing gets no line at all', () {
      final split = allocateTenders(
        bills: const <BillWeight>[
          (billId: 'big', weight: Money.rupees(900)),
          (billId: 'small', weight: Money.rupees(100)),
        ],
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money(1)),
        ],
      );
      expect(split['big']!.single.amount, const Money(1));
      expect(split['small'], isEmpty);
      expect(split.keys, <String>['big', 'small'],
          reason: 'every bill keeps its (possibly empty) list, in order');
    });

    test('bills that weigh nothing take nothing', () {
      final split = allocateTenders(
        bills: const <BillWeight>[
          (billId: 'a', weight: Money.zero),
          (billId: 'b', weight: Money.zero),
        ],
        tenders: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(10)),
        ],
      );
      expect(split['a'], isEmpty);
      expect(split['b'], isEmpty);
    });

    test('reference and notes ride on every share; blank ones are left out',
        () {
      final wire = _extracted(<({String id, Money total})>[
        (id: 'a', total: const Money.rupees(60)),
        (id: 'b', total: const Money.rupees(40)),
      ], <_OldEntry>[
        (
          mode: 'complimentary',
          amount: const Money.rupees(100),
          reference: '',
          notes: 'Birthday | Auth: Manager'
        ),
      ]);
      expect(wire['a'], <Map<String, dynamic>>[
        <String, dynamic>{
          'payment_mode': 'complimentary',
          'amount': 60.0,
          'notes': 'Birthday | Auth: Manager',
        },
      ]);
      expect(wire['b']!.single['notes'], 'Birthday | Auth: Manager');
    });

    test('matches the inline loop it replaced on 500 random orders', () {
      final random = Random(20261009);
      const modes = <String>['cash', 'upi', 'card', 'custom_phonepe'];
      for (var round = 0; round < 500; round++) {
        final bills = <({String id, Money total})>[
          for (var i = 0; i < 1 + random.nextInt(4); i++)
            (id: 'bill_$i', total: Money(random.nextInt(500000))),
        ];
        final grand = bills.map((b) => b.total).sumMoney();
        // Up to four tenders that add up to the grand total, like a split.
        final entries = <_OldEntry>[];
        var left = grand.paise;
        final count = 1 + random.nextInt(4);
        for (var i = 0; i < count; i++) {
          final amount =
              i == count - 1 ? left : (left == 0 ? 0 : random.nextInt(left));
          left -= amount;
          entries.add((
            mode: modes[random.nextInt(modes.length)],
            amount: Money(amount),
            reference: random.nextBool() ? 'REF$i' : null,
            notes: random.nextBool() ? 'note $i' : null,
          ));
        }
        expect(_extracted(bills, entries), _oldInlineLoop(bills, entries),
            reason: 'round $round');
      }
    });
  });

  group('the payment sheet, all new flags off', () {
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
    const single = ServerBill(
        id: 'bill_one',
        billNumber: 'INV/003',
        totalAmount: Money.rupees(945),
        billType: 'food',
        isPaid: false);

    testWidgets('offers Cash, UPI and Card only', (tester) async {
      final h = await PaymentSheetHarness.open(tester, bills: [single]);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('UPI'), findsOneWidget);
      expect(find.text('Card'), findsOneWidget);
      expect(find.text('Comp'), findsNothing);
      expect(find.text('Credit'), findsNothing);
      expect(find.text('Company'), findsNothing);
      expect(h.payButton(tester).onPressed, isNull,
          reason: 'nothing to pay with yet');
    });

    testWidgets('one bill, Cash: the whole total in one bill:payment, closed',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester, bills: [single]);
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(h.payloads(), <Map<String, dynamic>>[
        <String, dynamic>{
          'bill_id': 'bill_one',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'cash', 'amount': 945.0},
          ],
        },
      ]);
      expect(h.sent.single.data['client_request_id'], isA<String>());
      expect(h.result, isTrue);
    });

    testWidgets('two bills, UPI: the total split by bill, reference on both',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester, bills: [food, liquor]);
      await tester.tap(find.text('UPI'));
      await tester.pump();
      await tester.enterText(fieldWithHint('UPI transaction ID'), 'UTR778');
      await h.pay(tester);

      expect(h.payloads(), <Map<String, dynamic>>[
        <String, dynamic>{
          'bill_id': 'bill_food',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{
              'payment_mode': 'upi',
              'amount': 600.0,
              'reference_number': 'UTR778',
            },
          ],
        },
        <String, dynamic>{
          'bill_id': 'bill_liquor',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{
              'payment_mode': 'upi',
              'amount': 400.0,
              'reference_number': 'UTR778',
            },
          ],
        },
      ]);
      expect(h.result, isTrue);
    });

    testWidgets('Comp asks why and who allowed it, sent as notes',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester,
          bills: [single],
          flags: const FeatureFlags(complimentary: true, customers: true));
      expect(find.text('Comp'), findsOneWidget);
      expect(find.text('Credit'), findsOneWidget);
      expect(find.text('Company'), findsOneWidget);
      await tester.tap(find.text('Comp'));
      await tester.pump();
      await tester.enterText(
          fieldWithHint('Reason for comp / company bill'), 'Birthday');
      await tester.enterText(fieldWithHint('Authorized by (name)'), 'Manager');
      await h.pay(tester);

      expect(h.payloads().single['payments'], <Map<String, dynamic>>[
        <String, dynamic>{
          'payment_mode': 'complimentary',
          'amount': 945.0,
          'notes': 'Birthday | Auth: Manager',
        },
      ]);
    });

    testWidgets('Credit needs a linked customer', (tester) async {
      final h = await PaymentSheetHarness.open(tester,
          bills: [single], flags: const FeatureFlags(customers: true));
      await tester.tap(find.text('Credit'));
      await tester.pump();
      expect(find.text('Link a customer to use Credit'), findsOneWidget);
      expect(h.payButton(tester).onPressed, isNull);
    });

    testWidgets('Cash shows the change for what was tendered', (tester) async {
      await PaymentSheetHarness.open(tester, bills: [single]);
      await tester.tap(find.text('Cash'));
      await tester.pump();
      expect(find.text('CASH TENDERED'), findsOneWidget);
      expect(find.text('₹500'), findsNothing,
          reason: 'only notes that cover the bill are offered');
      await tester.tap(find.text('₹1000'));
      await tester.pump();
      expect(find.text('Change:'), findsOneWidget);
      expect(find.text('₹55'), findsOneWidget);
    });

    testWidgets('split payment: each tender split across the bills by total',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester,
          bills: [food, liquor], flags: const FeatureFlags(splitPayment: true));
      expect(find.text('Remaining: ₹1,000'), findsOneWidget);

      await tester.tap(find.text('Cash'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹1,000').last, '300');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('Remaining: ₹700'), findsOneWidget);

      await tester.tap(find.text('UPI'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹700'), '700');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('Remaining: ₹0'), findsOneWidget);

      await h.pay(tester);
      expect(h.payloads(), <Map<String, dynamic>>[
        <String, dynamic>{
          'bill_id': 'bill_food',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'cash', 'amount': 180.0},
            <String, dynamic>{'payment_mode': 'upi', 'amount': 420.0},
          ],
        },
        <String, dynamic>{
          'bill_id': 'bill_liquor',
          'payments': <Map<String, dynamic>>[
            <String, dynamic>{'payment_mode': 'cash', 'amount': 120.0},
            <String, dynamic>{'payment_mode': 'upi', 'amount': 280.0},
          ],
        },
      ]);
      expect(h.result, isTrue);
    });

    testWidgets('split payment: a shortfall under ₹1 settles as round-off',
        (tester) async {
      const odd = ServerBill(
          id: 'bill_odd',
          billNumber: 'INV/009',
          totalAmount: Money(10050),
          billType: 'food',
          isPaid: false);
      final h = await PaymentSheetHarness.open(tester,
          bills: [odd], flags: const FeatureFlags(splitPayment: true));
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹100.50').last, '100');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.text('Settle ₹0.50 shortfall (round-off)'));
      await tester.pump();
      await h.pay(tester);

      expect(h.payloads().single['payments'], <Map<String, dynamic>>[
        <String, dynamic>{'payment_mode': 'cash', 'amount': 100.0},
        <String, dynamic>{
          'payment_mode': 'cash',
          'amount': 0.5,
          'notes': 'Round-off',
        },
      ]);
    });

    testWidgets('the first bill refused: nothing charged, and it says so',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester, bills: [food, liquor]);
      h.answer = (event, data) =>
          <String, dynamic>{'kind': 'error', 'message': 'Bill not found'};
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(h.sent, hasLength(1), reason: 'it stops at the first failure');
      expect(find.text('Payment failed — nothing was charged. Retry.'),
          findsOneWidget);
      expect(h.result, isNull, reason: 'the sheet stays open');
      await h.drainToasts(tester);
    });

    testWidgets('the second bill lost: the toast counts what settled',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester, bills: [food, liquor]);
      h.answer = (event, data) => data['bill_id'] == 'bill_food'
          ? <String, dynamic>{'kind': 'success'}
          : <String, dynamic>{
              'kind': 'error',
              'code': AckCode.timeout,
              'message': "The desk didn't respond",
            };
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await h.pay(tester);

      expect(find.text('Settled 1 of 2. Retry sends only the remaining 1.'),
          findsOneWidget);
      expect(h.result, isNull);
      await h.drainToasts(tester);
    });
  });
}
