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
}
