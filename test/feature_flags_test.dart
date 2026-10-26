import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/feature_flags.dart';

void main() {
  group('FeatureFlags.tableUnlink', () {
    test('follows the desk\'s own Unlink tables permission', () {
      final off = FeatureFlags.fromMap(
          {'flag_table_link': 1, 'flag_table_unlink': 0});
      final on = FeatureFlags.fromMap(
          {'flag_table_link': 0, 'flag_table_unlink': 1});

      expect(off.tableUnlink, isFalse);
      expect(on.tableUnlink, isTrue);
    });

    test('falls back to Link tables on a desk that predates the permission',
        () {
      expect(FeatureFlags.fromMap({'flag_table_link': 0}).tableUnlink, isFalse);
      expect(FeatureFlags.fromMap({'flag_table_link': 1}).tableUnlink, isTrue);
      expect(FeatureFlags.fromMap({}).tableUnlink, isTrue);
    });
  });

  group('counter and gate flags', () {
    test('are off by default and on an older desk that never sends them', () {
      for (final flags in <FeatureFlags>[
        const FeatureFlags(),
        FeatureFlags.fromMap(const <String, dynamic>{}),
      ]) {
        expect(flags.orderTokens, isFalse);
        expect(flags.entryTickets, isFalse);
        expect(flags.ticketIssue, isFalse);
        expect(flags.ticketCheckin, isFalse);
        expect(flags.hasGate, isFalse);
      }
    });

    test('read the desk\'s flag columns in every wire form', () {
      final flags = FeatureFlags.fromMap(<String, dynamic>{
        'flag_order_tokens': 1,
        'flag_entry_tickets': true,
        'flag_ticket_issue': '1',
        'flag_ticket_checkin': 'true',
      });
      expect(flags.orderTokens, isTrue);
      expect(flags.entryTickets, isTrue);
      expect(flags.ticketIssue, isTrue);
      expect(flags.ticketCheckin, isTrue);
    });

    test('the gate needs entry tickets plus issue or check-in rights', () {
      FeatureFlags f(int parent, int issue, int checkin) =>
          FeatureFlags.fromMap(<String, dynamic>{
            'flag_entry_tickets': parent,
            'flag_ticket_issue': issue,
            'flag_ticket_checkin': checkin,
          });
      expect(f(1, 1, 0).hasGate, isTrue, reason: 'issue only');
      expect(f(1, 0, 1).hasGate, isTrue, reason: 'check-in only');
      expect(f(1, 1, 1).hasGate, isTrue);
      expect(f(1, 0, 0).hasGate, isFalse, reason: 'module on, no rights');
      expect(f(0, 1, 1).hasGate, isFalse,
          reason: 'rights without the module never open the gate');
    });
  });

  group('billing actions on the order screens', () {
    FeatureFlags f(Map<String, int> flags) => FeatureFlags.fromMap(
        <String, dynamic>{for (final e in flags.entries) e.key: e.value});

    test('Print Bill follows bill printing, not the reprint permission', () {
      expect(
          f({'flag_bill_printing': 1, 'flag_bill_reprint': 0}).canPrintBill,
          isTrue,
          reason: 'the first copy is not a reprint');
      expect(
          f({'flag_bill_printing': 0, 'flag_bill_reprint': 1}).canPrintBill,
          isFalse);
    });

    test('Quick Settle needs generate bill and collect payment', () {
      const on = {
        'flag_quick_settle': 1,
        'flag_generate_bill': 1,
        'flag_collect_payment': 1,
      };
      expect(f(on).canQuickSettle, isTrue);
      expect(f({...on, 'flag_generate_bill': 0}).canQuickSettle, isFalse,
          reason: 'it makes the bill first; without that right it dies after '
              'the order and KOT are already sent');
      expect(f({...on, 'flag_collect_payment': 0}).canQuickSettle, isFalse);
      expect(f({...on, 'flag_quick_settle': 0}).canQuickSettle, isFalse);
    });
  });

  group('cancelOrder on a desk that predates the permission', () {
    test('follows void bills, which used to decide Cancel', () {
      expect(FeatureFlags.fromMap({'flag_void_bills': 0}).cancelOrder, isFalse);
      expect(FeatureFlags.fromMap({'flag_void_bills': 1}).cancelOrder, isTrue);
    });

    test('the desk\'s own Cancel order permission wins when it is sent', () {
      expect(
          FeatureFlags.fromMap({'flag_cancel_order': 1, 'flag_void_bills': 0})
              .cancelOrder,
          isTrue);
      expect(
          FeatureFlags.fromMap({'flag_cancel_order': 0, 'flag_void_bills': 1})
              .cancelOrder,
          isFalse);
    });
  });

  test('Hold is not offered once the order is billed (the desk refuses it)',
      () {
    final on = FeatureFlags.fromMap({'flag_hold_order': 1});
    expect(on.canHold(billed: false), isTrue);
    expect(on.canHold(billed: true), isFalse);
    expect(FeatureFlags.fromMap({'flag_hold_order': 0}).canHold(billed: false),
        isFalse);
  });
}
