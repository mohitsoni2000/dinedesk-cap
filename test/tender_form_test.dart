import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/utils/request_id.dart';
import 'package:restro/widgets/tender_form.dart';

import 'support/payment_sheet_harness.dart';

const _phonepe = PayMode(
  code: 'custom_phonepe',
  label: 'PhonePe QR',
  printName: 'PhonePe',
  reference: PayModeReference.mandatory,
  sortOrder: 10,
);
const _staffMeal = PayMode(
  code: 'custom_staff',
  label: 'Staff meal',
  printName: 'Staff meal',
  isRevenue: false,
  requiresReason: true,
  sortOrder: 11,
);

/// The tender form pulled out of the payment sheet. The sheet uses it for a
/// bill; the counter (no bill yet, the desk fills the balance) and the ticket
/// sale step (no cover, fewer modes) use it the same way.
void main() {
  setUp(resetRequestIds);

  Future<TenderFormController> pumpForm(
    WidgetTester tester, {
    required List<PayMode> modes,
    Money due = const Money.rupees(500),
    bool allowSplit = false,
    bool hasCustomer = false,
  }) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TenderFormController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: TenderForm(
            controller: controller,
            modes: modes,
            due: due,
            allowSplit: allowSplit,
            hasCustomer: hasCustomer,
          ),
        ),
      ),
    ));
    return controller;
  }

  group('TenderForm without a bill', () {
    testWidgets('one mode for the balance: a fill line the desk completes',
        (tester) async {
      final c = await pumpForm(tester, modes: PayMode.builtIns.sublist(0, 3));
      expect(c.lines(due: const Money.rupees(500), splitMode: false), isNull,
          reason: 'no mode picked yet');
      await tester.tap(find.text('UPI'));
      await tester.pump();
      await tester.enterText(fieldWithHint('UPI transaction ID'), 'UTR9');

      final fill =
          c.lines(due: const Money.rupees(500), splitMode: false, fill: true)!;
      expect(fill.single.toWire(), <String, dynamic>{
        'payment_mode': 'upi',
        'reference_number': 'UTR9',
      });
      final billLine = c.lines(due: const Money.rupees(500), splitMode: false)!;
      expect(billLine.single.amount, const Money.rupees(500));
    });

    testWidgets('a ticket sale offers only the modes it is handed',
        (tester) async {
      await pumpForm(tester,
          modes: <PayMode>[PayMode.cash, PayMode.upi, PayMode.card, _phonepe]);
      for (final shown in <String>['Cash', 'UPI', 'Card', 'PhonePe QR']) {
        expect(find.text(shown), findsOneWidget, reason: shown);
      }
      for (final hidden in <String>['Comp', 'Credit', 'Company']) {
        expect(find.text(hidden), findsNothing, reason: hidden);
      }
    });

    testWidgets('nothing due: no lines at all', (tester) async {
      final c = await pumpForm(tester, modes: <PayMode>[PayMode.cash]);
      expect(c.lines(due: Money.zero, splitMode: false), isEmpty);
    });

    testWidgets('splits are the lines, in the order added', (tester) async {
      final c = await pumpForm(tester,
          modes: <PayMode>[PayMode.cash, PayMode.upi], allowSplit: true);
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹500').last, '200');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.text('UPI'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹300'), '900');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(c.splitTotal, const Money.rupees(500),
          reason: 'a split is capped at what is left');
      expect(
          c
              .lines(due: const Money.rupees(500), splitMode: true)!
              .map((l) => (l.mode, l.amount)),
          [
            ('cash', const Money.rupees(200)),
            ('upi', const Money.rupees(300))
          ]);
      c.removeSplitAt(0);
      expect(c.splitTotal, const Money.rupees(300));
    });

    testWidgets('reset clears the pick, the fields and the splits',
        (tester) async {
      final c = await pumpForm(tester,
          modes: <PayMode>[PayMode.cash, PayMode.upi], allowSplit: true);
      await tester.tap(find.text('Cash'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹500').last, '200');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.tap(find.text('UPI'));
      await tester.pump();
      await tester.enterText(fieldWithHint('UPI transaction ID'), 'UTR9');
      c.reset();
      await tester.pump();
      expect(c.selected, isNull);
      expect(c.splits, isEmpty);
      expect(c.reference.text, isEmpty);
      expect(find.text('UPI transaction ID'), findsNothing);
    });
  });

  group("a desk mode's own rules", () {
    testWidgets('a mandatory reference: not ready until it is typed',
        (tester) async {
      final c =
          await pumpForm(tester, modes: <PayMode>[PayMode.cash, _phonepe]);
      await tester.tap(find.text('PhonePe QR'));
      await tester.pump();
      expect(find.text('REFERENCE NUMBER (REQUIRED)'), findsOneWidget);
      expect(c.selectedComplete, isFalse);
      expect(c.lines(due: const Money.rupees(500), splitMode: false), isNull);
      await tester.enterText(fieldWithHint('Reference number'), ' PP-77 ');
      expect(c.selectedComplete, isTrue);
      expect(
          c
              .lines(due: const Money.rupees(500), splitMode: false)!
              .single
              .toWire(),
          <String, dynamic>{
            'payment_mode': 'custom_phonepe',
            'amount': 500.0,
            'reference_number': 'PP-77',
          });
    });

    testWidgets('a mode that asks why sends mode_reason, not notes',
        (tester) async {
      final c =
          await pumpForm(tester, modes: <PayMode>[PayMode.cash, _staffMeal]);
      await tester.tap(find.text('Staff meal'));
      await tester.pump();
      expect(c.selectedComplete, isFalse);
      expect(find.text('Authorized by (name)'), findsNothing,
          reason: 'that pair is for Comp and Company');
      await tester.enterText(fieldWithHint('Reason'), 'Owner guest');
      expect(
          c
              .lines(due: const Money.rupees(500), splitMode: false)!
              .single
              .toWire(),
          <String, dynamic>{
            'payment_mode': 'custom_staff',
            'amount': 500.0,
            'mode_reason': 'Owner guest',
          });
    });

    testWidgets('a split for such a mode waits for its reference',
        (tester) async {
      final c = await pumpForm(tester,
          modes: <PayMode>[PayMode.cash, _phonepe], allowSplit: true);
      await tester.tap(find.text('PhonePe QR'));
      await tester.pump();
      await tester.enterText(fieldWithHint('₹500'), '100');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(c.splits, isEmpty);
      await tester.enterText(fieldWithHint('Reference number'), 'PP-1');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(c.splits.single.line.reference, 'PP-1');
    });

    testWidgets('Credit without a linked customer is blocked', (tester) async {
      final c = await pumpForm(tester, modes: <PayMode>[PayMode.credit]);
      await tester.tap(find.text('Credit'));
      await tester.pump();
      expect(c.creditBlocked(hasCustomer: false), isTrue);
      expect(c.creditBlocked(hasCustomer: true), isFalse);
      expect(find.text('Link a customer to use Credit'), findsOneWidget);
    });
  });

  group('the payment sheet with desk modes that ask for more', () {
    const bill = ServerBill(
        id: 'bill_one',
        billNumber: 'INV/003',
        totalAmount: Money.rupees(945),
        billType: 'food',
        isPaid: false);

    testWidgets('Pay waits for a mandatory reference', (tester) async {
      final h = await PaymentSheetHarness.open(tester,
          bills: [bill], listedModes: <PayMode>[_phonepe]);
      await tester.tap(find.text('PhonePe QR'));
      await tester.pump();
      expect(h.payButton(tester).onPressed, isNull);
      await tester.enterText(fieldWithHint('Reference number'), 'PP-5521');
      await tester.pump();
      expect(h.payButton(tester).onPressed, isNotNull);
    });

    testWidgets('a reason the desk asks for goes out as mode_reason',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester,
          bills: [bill],
          flags: const FeatureFlags(),
          listedModes: <PayMode>[_staffMeal]);
      await tester.tap(find.text('Staff meal'));
      await tester.pump();
      await tester.enterText(fieldWithHint('Reason'), 'Owner guest');
      await h.pay(tester);
      expect(h.payloads().single['payments'], <Map<String, dynamic>>[
        <String, dynamic>{
          'payment_mode': 'custom_staff',
          'amount': 945.0,
          'mode_reason': 'Owner guest',
        },
      ]);
    });
  });
}
