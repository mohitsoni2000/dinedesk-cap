import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/utils/request_id.dart';

import 'support/payment_sheet_harness.dart';

PayMode _custom(String code, String name, int sortOrder,
        {PayModeReference reference = PayModeReference.off,
        bool reason = false}) =>
    PayMode(
      code: code,
      label: name,
      printName: name,
      reference: reference,
      requiresReason: reason,
      sortOrder: sortOrder,
    );

/// The payment sheet's modes come from data now: the built-in modes this
/// user's flags allow, where they always were, then the desk's own modes.
void main() {
  setUp(resetRequestIds);

  group('payModeCatalog', () {
    List<String> codes(List<PayMode> modes) =>
        modes.map((m) => m.code).toList();

    test('with no flags: Cash, UPI, Card, the old three in the old order', () {
      final modes = payModeCatalog(
          flags: const FeatureFlags(), listed: const <PayMode>[]);
      expect(codes(modes), <String>['cash', 'upi', 'card']);
      expect(modes.map((m) => m.label), <String>['Cash', 'UPI', 'Card']);
    });

    test('complimentary adds Comp and Company, customers adds Credit', () {
      expect(
          codes(payModeCatalog(
              flags: const FeatureFlags(complimentary: true, customers: true),
              listed: const <PayMode>[])),
          <String>[
            'cash',
            'upi',
            'card',
            'complimentary',
            'credit',
            'company'
          ]);
      expect(
          codes(payModeCatalog(
              flags: const FeatureFlags(customers: true),
              listed: const <PayMode>[])),
          <String>['cash', 'upi', 'card', 'credit']);
    });

    test("the desk's own modes follow the built-ins, in its sort order", () {
      final modes = payModeCatalog(
        flags: const FeatureFlags(),
        listed: <PayMode>[
          _custom('custom_swiggy', 'Swiggy Dineout', 20),
          _custom('custom_phonepe', 'PhonePe QR', 10),
        ],
      );
      expect(codes(modes),
          <String>['cash', 'upi', 'card', 'custom_phonepe', 'custom_swiggy']);
    });

    test('a desk row with a built-in code shows once, as the built-in', () {
      final modes = payModeCatalog(
        flags: const FeatureFlags(),
        listed: <PayMode>[
          _custom('cash', 'Cash Drawer', 0),
          _custom('complimentary', 'Staff meal', 1),
          _custom('custom_phonepe', 'PhonePe QR', 10),
          _custom('custom_phonepe', 'PhonePe QR again', 11),
        ],
      );
      expect(codes(modes), <String>['cash', 'upi', 'card', 'custom_phonepe'],
          reason: 'Comp stays a flag decision; nothing shows twice');
      expect(modes.first.label, 'Cash');
      expect(modes.last.label, 'PhonePe QR');
    });

    test('the cover mode never becomes a chip, even if the desk lists it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(listedPayModesProvider.notifier).state = <PayMode>[
        _custom('custom_phonepe', 'PhonePe QR', 10),
        _custom('cover_ticket', 'Cover Ticket', 11),
      ];
      container.read(ticketConfigProvider.notifier).state =
          const TicketConfig(coverPaymentMode: 'cover_ticket');
      expect(
          codes(payModeCatalog(
              flags: const FeatureFlags(),
              listed: container.read(payModesProvider))),
          <String>['cash', 'upi', 'card', 'custom_phonepe']);
    });

    test("the sync fixture's list: its built-in rows fold in, PhonePe follows",
        () {
      final sync = jsonDecode(File('test/fixtures/crew-qsr/sync_qsr_keys.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final modes = payModeCatalog(
          flags: const FeatureFlags(),
          listed: PayMode.listFrom(sync['payment_modes']));
      expect(codes(modes), <String>['cash', 'upi', 'card', 'custom_phonepe']);
      expect(modes.last.reference, PayModeReference.mandatory);
    });
  });

  group('the built-in modes', () {
    test('keep the labels and icons the sheet always showed', () {
      expect(
          PayMode.builtIns.map((m) => (m.code, m.label, m.icon)),
          <(String, String, IconData)>[
            ('cash', 'Cash', Icons.payments_outlined),
            ('upi', 'UPI', Icons.phone_android_outlined),
            ('card', 'Card', Icons.credit_card_outlined),
            ('complimentary', 'Comp', Icons.card_giftcard_outlined),
            ('credit', 'Credit', Icons.account_balance_outlined),
            ('company', 'Company', Icons.business_outlined),
          ]);
    });

    test('ask what they always asked', () {
      expect(PayMode.cash.takesCashTendered, isTrue);
      expect(PayMode.upi.showsReference, isTrue);
      expect(PayMode.card.showsReference, isTrue);
      expect(PayMode.cash.showsReference, isFalse);
      expect(PayMode.complimentary.asksCompReason, isTrue);
      expect(PayMode.company.asksCompReason, isTrue);
      expect(PayMode.credit.needsCustomer, isTrue);
      for (final m in PayMode.builtIns) {
        expect(m.asksModeReason, isFalse, reason: m.code);
        expect(m.isBuiltIn, isTrue, reason: m.code);
      }
    });

    test("a desk mode asks for what the desk's settings say", () {
      final phonepe = _custom('custom_phonepe', 'PhonePe QR', 10,
          reference: PayModeReference.mandatory);
      final staff = _custom('custom_staff', 'Staff meal', 11, reason: true);
      expect(phonepe.showsReference, isTrue);
      expect(phonepe.needsReference, isTrue);
      expect(phonepe.isBuiltIn, isFalse);
      expect(staff.asksModeReason, isTrue);
      expect(staff.asksCompReason, isFalse);
      expect(staff.takesCashTendered, isFalse);
    });
  });

  group('the payment sheet with desk modes', () {
    const bill = ServerBill(
        id: 'bill_one',
        billNumber: 'INV/003',
        totalAmount: Money.rupees(945),
        billType: 'food',
        isPaid: false);

    testWidgets('offers them after the built-ins and pays with their code',
        (tester) async {
      final h = await PaymentSheetHarness.open(tester, bills: [
        bill
      ], listedModes: <PayMode>[
        _custom('custom_phonepe', 'PhonePe QR', 10,
            reference: PayModeReference.optional),
      ]);
      final cash = tester.getTopLeft(find.text('Cash'));
      final phonepe = tester.getTopLeft(find.text('PhonePe QR'));
      expect(phonepe.dx > cash.dx || phonepe.dy > cash.dy, isTrue);

      await tester.tap(find.text('PhonePe QR'));
      await tester.pump();
      await tester.enterText(fieldWithHint('Reference number'), 'PP-5521');
      await h.pay(tester);

      expect(h.payloads().single['payments'], <Map<String, dynamic>>[
        <String, dynamic>{
          'payment_mode': 'custom_phonepe',
          'amount': 945.0,
          'reference_number': 'PP-5521',
        },
      ]);
      expect(h.result, isTrue);
    });
  });
}
