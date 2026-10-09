import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/ist_time.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/models/token.dart';
import 'package:restro/models/wire.dart';

/// The JSON under test/fixtures/crew-qsr/ is the Crew <-> desk contract for
/// counter tokens, entry tickets and cover: the desk gateway copies these
/// files and makes its acks match them. Every one of them must parse here.
void main() {
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;

  group('the fixture set', () {
    final names = Directory(dir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toSet();

    test('is complete', () {
      expect(
          names,
          containsAll(<String>[
            'sync_qsr_keys.json',
            'ticket_issue_ack.json',
            'ticket_lookup_ack.json',
            'ticket_check_in_valid.json',
            'ticket_check_in_already_used.json',
            'ticket_check_in_expired.json',
            'ticket_check_in_cancelled.json',
            'ticket_check_in_not_found.json',
            'ticket_recent_ack.json',
            'order_with_token.json',
            'order_ready_token.json',
            'qsr_checkout_ack.json',
          ]));
    });

    // guest-id-masking.ts nulls these keys in every ack and broadcast to Crew,
    // so a ticket DTO that used one would arrive blank.
    const maskedKeys = <String>{
      'id_number',
      'guest_id_number',
      'guest_id_proof',
      'form_c',
      'guest_form_c',
    };
    final qr = RegExp(r'^CDT:[A-Z2-7]{16}$');

    void walk(Object? node, void Function(String key, Object? value) visit) {
      if (node is Map) {
        node.forEach((k, v) {
          visit(k.toString(), v);
          walk(v, visit);
        });
      } else if (node is List) {
        for (final e in node) {
          walk(e, visit);
        }
      }
    }

    test('never uses a key the desk masks, and every QR is CDT: + base32', () {
      for (final name in names) {
        walk(fixture(name), (key, value) {
          expect(maskedKeys.contains(key), isFalse, reason: '$name: $key');
          if ((key == 'qr_code' || key == 'qr_data' || key == 'ticket_code') &&
              value != null) {
            expect(qr.hasMatch(value as String), isTrue,
                reason: '$name: $value');
          }
        });
      }
    });

    test('sends money as JSON numbers (rupees), never strings', () {
      const moneyKeys = <String>{
        'price',
        'unit_total',
        'cover_amount',
        'cover_balance',
        'cover_balance_after',
        'taxable_amount',
        'gst_amount',
        'amount',
        'total',
        'subtotal',
        'gst',
        'round_off',
        'cover_total',
        'total_amount',
        'unit_price',
        'total_price',
      };
      for (final name in names) {
        walk(fixture(name), (key, value) {
          if (moneyKeys.contains(key) && value != null) {
            expect(value, isA<num>(), reason: '$name: $key');
          }
        });
      }
    });
  });

  group('sync keys', () {
    final sync = fixture('sync_qsr_keys.json');

    test('qsr_config', () {
      final cfg = QsrConfig.tryParse(sync['qsr_config'])!;
      expect(cfg.isQsr, isTrue);
      expect(cfg.tokenStrategy, TokenStrategy.prefixed);
    });

    test('entry_ticket_types', () {
      final types = TicketType.listFrom(sync['entry_ticket_types']);
      expect(types.map((t) => t.id), <String>['ett_couple', 'ett_stag']);
      final couple = types.first;
      expect(couple.name, 'Couple Pass');
      expect(couple.price, const Money.rupees(2000));
      expect(couple.gstRate, 18);
      expect(couple.gstInclusive, isTrue);
      expect(couple.coverAmount, const Money.rupees(800));
      expect(couple.hasCover, isTrue);
      expect(couple.pax, 2);
      expect(couple.color, '#C2410C');
      expect(couple.unitTotal, const Money.rupees(2000));
      final stag = types.last;
      expect(stag.gstInclusive, isFalse);
      expect(stag.color, isNull);
      expect(stag.unitTotal, const Money.rupees(1108),
          reason: 'GST-exclusive: the phone charges unit_total, not price');
    });

    test('entry_ticket_config', () {
      final cfg = TicketConfig.tryParse(sync['entry_ticket_config'])!;
      expect(cfg.coverPaymentMode, 'cover_ticket');
      expect(cfg.qrPrefix, 'CDT:');
      expect(cfg.matchesQr('CDT:7QKX2MZ4HB6TNW3R'), isTrue);
      expect(cfg.matchesQr(' CDT:7QKX2MZ4HB6TNW3R '), isTrue);
      expect(cfg.matchesQr('CDT:7QKX2MZ4HB6TNW3'), isFalse, reason: '15 chars');
      expect(cfg.matchesQr('CDT:7QKX2MZ4HB6TNW31'), isFalse, reason: '1');
      expect(cfg.matchesQr('restroapp://pair?host=x'), isFalse);
      expect(cfg.matchesQr('ET-042'), isFalse);
    });

    test('payment_modes', () {
      final modes = PayMode.listFrom(sync['payment_modes']);
      expect(modes.map((m) => m.code),
          <String>['cash', 'upi', 'card', 'custom_phonepe']);
      final cash = modes.first;
      expect(cash.label, 'Cash');
      expect(cash.isCash, isTrue);
      expect(cash.isCustom, isFalse);
      expect(cash.reference, PayModeReference.off);
      final phonepe = modes.last;
      expect(phonepe.label, 'PhonePe QR');
      expect(phonepe.printName, 'PhonePe');
      expect(phonepe.isCustom, isTrue);
      expect(phonepe.isRevenue, isTrue);
      expect(phonepe.reference, PayModeReference.mandatory);
      expect(phonepe.needsReference, isTrue);
      expect(phonepe.requiresReason, isFalse);
    });
  });

  group('ticket:issue ack', () {
    final ack = TicketIssueResult.fromAck(fixture('ticket_issue_ack.json'));

    test('the sale', () {
      final sale = ack.sale;
      expect(sale.id, 'ets_7f3a9c');
      expect(sale.saleNumber, 'ET/26-27/000037');
      expect(sale.businessDate, '2026-10-09');
      expect(sale.issuedAt, DateTime.utc(2026, 10, 9, 14, 40, 12));
      expect(sale.guestName, 'Ravi Sharma');
      expect(sale.guestPhoneLast4, '3210');
      expect(sale.issuedByName, 'Asha');
      expect(sale.status, 'active');
      expect(sale.issuedFrom, 'crew');
      final t = sale.totals;
      expect(t.total, const Money.rupees(4000));
      expect(t.coverTotal, const Money.rupees(1600));
      expect(t.subtotal + t.gst + t.coverTotal + t.roundOff, t.total,
          reason: 'entry taxable + GST + cover advance + round-off');
      expect(sale.payments.map((p) => p.mode), <String>['cash', 'upi']);
      expect(sale.payments.map((p) => p.amount).sumMoney(), t.total);
      expect(sale.payments.last.referenceNumber, '628311904417');
    });

    test('one ticket per unit, each with its own QR and slip', () {
      expect(ack.tickets, hasLength(2));
      expect(ack.tickets.map((t) => t.qrCode).toSet(), hasLength(2));
      final first = ack.tickets.first;
      expect(first.id, 'et_41a');
      expect(first.ticketNumber, 'ET-041');
      expect(first.qrCode, 'CDT:7QKX2MZ4HB6TNW3R');
      expect(first.typeId, 'ett_couple');
      expect(first.typeName, 'Couple Pass');
      expect(first.pax, 2);
      expect(first.price, const Money.rupees(2000));
      expect(first.taxableAmount, const Money(101695));
      expect(first.gstAmount, const Money(18305));
      expect(first.coverAmount, const Money.rupees(800));
      expect(first.coverBalance, const Money.rupees(800));
      expect(first.status, TicketStatus.issued);
      expect(first.validDate, '2026-10-09');
      final slip = first.slip!;
      expect(slip.header.first, 'Spice Hub');
      expect(slip.ticketNo, 'ET-041');
      expect(slip.title, 'COUPLE PASS');
      expect(slip.highlight, 'ADMITS 2 PAX');
      expect(slip.lines, contains('COVER ₹800 — use on food & drinks today'));
      expect(slip.qrData, first.qrCode);
      expect(slip.footer, hasLength(2));
    });

    test('an ack with no tickets is a wire error: a paid sale needs its slips',
        () {
      final ack = fixture('ticket_issue_ack.json');
      expect(
          () => TicketIssueResult.fromAck(
              <String, dynamic>{...ack, 'tickets': <Object>[]}),
          throwsA(isA<WireFormatException>()));
      expect(
          () => TicketIssueResult.fromAck(
              <String, dynamic>{...ack}..remove('tickets')),
          throwsA(isA<WireFormatException>()));
    });

    test('one unreadable ticket fails the whole ack instead of a missing slip',
        () {
      final ack = fixture('ticket_issue_ack.json');
      final tickets = <Object?>[
        for (final t in ack['tickets'] as List<dynamic>)
          Map<String, dynamic>.from(t as Map),
      ];
      (tickets.first! as Map<String, dynamic>).remove('ticket_number');
      expect(
          () => TicketIssueResult.fromAck(
              <String, dynamic>{...ack, 'tickets': tickets}),
          throwsA(isA<WireFormatException>()));
      expect(
          () => TicketIssueResult.fromAck(<String, dynamic>{
                ...ack,
                'tickets': <Object?>[...(ack['tickets'] as List<dynamic>), 'x'],
              }),
          throwsA(isA<WireFormatException>()));
    });

    test('an ack without a sale is a wire error, not a half sale', () {
      expect(
          () => TicketIssueResult.fromAck(<String, dynamic>{'kind': 'success'}),
          throwsA(isA<WireFormatException>()));
    });
  });

  group('the fixtures follow the spec 2.5 ticket pricing', () {
    // Paise, so every comparison is exact.
    int paise(Object? v) => Money.fromWire(v)!.paise;

    /// Per unit: E = price - cover. Inclusive: taxable = round2(E*100/(100+r)),
    /// gst = E - taxable, unit_total = price. Exclusive: taxable = E,
    /// gst = round2(E*r/100), unit_total = E + gst + cover.
    ({int taxable, int gst, int unitTotal}) unit(Map<String, dynamic> type) {
      final price = paise(type['price']);
      final cover = paise(type['cover_amount']);
      final rate = (type['gst_rate'] as num).toDouble();
      final inclusive =
          type['gst_inclusive'] == 1 || type['gst_inclusive'] == true;
      final entry = price - cover;
      if (inclusive) {
        final taxable = (entry * 100 / (100 + rate)).round();
        return (taxable: taxable, gst: entry - taxable, unitTotal: price);
      }
      final gst = (entry * rate / 100).round();
      return (taxable: entry, gst: gst, unitTotal: entry + gst + cover);
    }

    final types = <String, Map<String, dynamic>>{
      for (final t in fixture('sync_qsr_keys.json')['entry_ticket_types']
          as List<dynamic>)
        (t as Map<String, dynamic>)['id'] as String: t,
    };

    test('every type\'s unit_total', () {
      expect(types.keys, <String>['ett_couple', 'ett_stag']);
      for (final type in types.values) {
        expect(paise(type['unit_total']), unit(type).unitTotal,
            reason: type['id'] as String);
      }
      expect(unit(types['ett_couple']!).taxable, 101695);
      expect(unit(types['ett_stag']!).unitTotal, 110800);
    });

    test('every issued ticket matches its type', () {
      final tickets = <Map<String, dynamic>>[
        for (final t
            in fixture('ticket_issue_ack.json')['tickets'] as List<dynamic>)
          t as Map<String, dynamic>,
        fixture('ticket_lookup_ack.json')['ticket'] as Map<String, dynamic>,
      ];
      for (final ticket in tickets) {
        final type = types[ticket['type_id']]!;
        final want = unit(type);
        final no = ticket['ticket_number'] as String;
        expect(paise(ticket['price']), paise(type['price']), reason: no);
        expect(paise(ticket['taxable_amount']), want.taxable, reason: no);
        expect(paise(ticket['gst_amount']), want.gst, reason: no);
        expect(paise(ticket['cover_amount']), paise(type['cover_amount']),
            reason: no);
      }
    });

    test('the sale adds up, and the payments cover it exactly', () {
      final ack = fixture('ticket_issue_ack.json');
      final sale = ack['sale'] as Map<String, dynamic>;
      final totals = sale['totals'] as Map<String, dynamic>;
      final tickets =
          (ack['tickets'] as List<dynamic>).cast<Map<String, dynamic>>();
      int sum(String key) =>
          tickets.fold<int>(0, (acc, t) => acc + paise(t[key]));
      expect(paise(totals['subtotal']), sum('taxable_amount'));
      expect(paise(totals['gst']), sum('gst_amount'));
      expect(paise(totals['cover_total']), sum('cover_amount'));
      final total = paise(totals['total']);
      expect(
          paise(totals['subtotal']) +
              paise(totals['gst']) +
              paise(totals['cover_total']) +
              paise(totals['round_off']),
          total);
      expect(
          (sale['payments'] as List<dynamic>).fold<int>(0,
              (acc, p) => acc + paise((p as Map<String, dynamic>)['amount'])),
          total);
    });
  });

  group('ticket:lookup ack', () {
    test('a redeemable ticket', () {
      final r = LookupResult.fromAck(fixture('ticket_lookup_ack.json'));
      expect(r.canRedeem, isTrue);
      expect(r.reason, isNull);
      expect(r.coverBalance, const Money.rupees(800));
      expect(r.ticket!.ticketNumber, 'ET-042');
      expect(r.ticket!.status, TicketStatus.checkedIn);
      expect(r.ticket!.slip!.qrData, 'CDT:P3VJ5LDY2GQA7FEC');
    });

    test('an unknown code is a success ack with no ticket', () {
      final r = LookupResult.fromAck(<String, dynamic>{
        'kind': 'success',
        'ticket': null,
        'cover_balance': 0,
        'can_redeem': false,
        'reason': 'not_found',
      });
      expect(r.ticket, isNull);
      expect(r.canRedeem, isFalse);
      expect(r.reason, LookupReason.notFound);
      expect(r.coverBalance, Money.zero);
    });

    test('reasons map, and an unknown one is kept as other', () {
      LookupReason? reason(String raw) => LookupResult.fromAck(
          <String, dynamic>{'can_redeem': false, 'reason': raw}).reason;
      expect(reason('cancelled'), LookupReason.cancelled);
      expect(reason('expired'), LookupReason.expired);
      expect(reason('no_cover'), LookupReason.noCover);
      expect(reason('used_up'), LookupReason.usedUp);
      expect(reason('moon_phase'), LookupReason.other);
    });
  });

  group('ticket:check_in acks', () {
    test('valid', () {
      final r = CheckInResult.fromAck(fixture('ticket_check_in_valid.json'));
      expect(r.outcome, CheckInOutcome.valid);
      expect(r.ticket!.ticketNumber, 'ET-042');
      expect(r.ticket!.pax, 2);
      expect(r.ticket!.typeName, 'Couple Pass');
      expect(r.ticket!.guestName, 'Ravi Sharma');
      expect(r.ticket!.status, TicketStatus.checkedIn);
      expect(r.ticket!.coverBalance, const Money.rupees(800));
      expect(r.checkedInByName, 'Asha');
      expect(r.checkedInAt, DateTime.utc(2026, 10, 9, 14, 45, 30));
    });

    test('already used: when and by whom, for "Already used at 08:15 PM"', () {
      final r =
          CheckInResult.fromAck(fixture('ticket_check_in_already_used.json'));
      expect(r.outcome, CheckInOutcome.alreadyUsed);
      expect(formatIstClock12(r.checkedInAt!), '08:15 PM');
      expect(r.checkedInByName, 'Asha');
    });

    test('expired carries the day it was valid for', () {
      final r = CheckInResult.fromAck(fixture('ticket_check_in_expired.json'));
      expect(r.outcome, CheckInOutcome.expired);
      expect(r.ticket!.coverBalance, Money.zero,
          reason: 'usable balance: the cover was forfeited at the cutover');
      expect(r.ticket!.validDate, '2026-10-08');
      expect(r.ticket!.guestName, isNull);
      expect(r.checkedInAt, isNull);
    });

    test('cancelled', () {
      final r =
          CheckInResult.fromAck(fixture('ticket_check_in_cancelled.json'));
      expect(r.outcome, CheckInOutcome.cancelled);
      expect(r.ticket!.status, TicketStatus.cancelled);
      expect(r.ticket!.coverBalance, Money.zero);
    });

    test('not found has no ticket', () {
      final r =
          CheckInResult.fromAck(fixture('ticket_check_in_not_found.json'));
      expect(r.outcome, CheckInOutcome.notFound);
      expect(r.ticket, isNull);
    });

    test('the outcome words are the desk\'s, and "ok" is not one of them', () {
      expect(CheckInOutcome.fromWire('valid'), CheckInOutcome.valid);
      expect(
          CheckInOutcome.fromWire('already_used'), CheckInOutcome.alreadyUsed);
      expect(CheckInOutcome.fromWire('expired'), CheckInOutcome.expired);
      expect(CheckInOutcome.fromWire('cancelled'), CheckInOutcome.cancelled);
      expect(CheckInOutcome.fromWire('not_found'), CheckInOutcome.notFound);
      expect(CheckInOutcome.fromWire('ok'), CheckInOutcome.unknown);
      expect(CheckInOutcome.fromWire(null), CheckInOutcome.unknown);
    });
  });

  group('ticket:recent ack', () {
    test('rows newest first, phone masked, and the gate counters', () {
      final r = RecentTickets.fromAck(fixture('ticket_recent_ack.json'));
      expect(r.businessDate, '2026-10-09');
      expect(r.tickets.map((t) => t.ticketNumber),
          <String>['ET-043', 'ET-042', 'ET-041', 'ET-040']);
      expect(r.tickets.map((t) => t.status), <TicketStatus>[
        TicketStatus.issued,
        TicketStatus.checkedIn,
        TicketStatus.issued,
        TicketStatus.cancelled,
      ]);
      final entered = r.tickets[1];
      expect(entered.guestPhoneLast4, '3210');
      expect(entered.coverAmount, const Money.rupees(800));
      expect(entered.issuedAt, DateTime.utc(2026, 10, 9, 14, 40, 12));
      expect(entered.checkedInAt, DateTime.utc(2026, 10, 9, 14, 45, 30));
      expect(r.stats.issued, 3);
      expect(r.stats.paxIssued, 5);
      expect(r.stats.checkedIn, 1);
      expect(r.stats.paxInside, 2);
    });
  });

  group('orders with tokens', () {
    test('an order row carries its token and fulfillment', () {
      final order = ServerOrder.fromMap(fixture('order_with_token.json'));
      expect(order.isTableLess, isTrue);
      expect(order.orderType, 'takeaway');
      expect(order.fulfillmentType, FulfillmentType.takeaway);
      final token = order.token!;
      expect(token.number, 7);
      expect(token.label, 'T-07');
      expect(token.title, 'Token T-07');
      expect(token.date, '2026-10-09');
      expect(token.status, TokenStatus.preparing);
      expect(token.readyAt, isNull);
      expect(token.collectedAt, isNull);
    });

    test('an order without token columns has no token (older desk)', () {
      final order = ServerOrder.fromMap(<String, dynamic>{
        'id': 'o1',
        'table_id': 't1',
        'total': 100,
      });
      expect(order.token, isNull);
      expect(order.fulfillmentType, isNull);
      expect(order.orderType, isNull);
      expect(order.isTableLess, isFalse);
    });

    test('ready and collected times are desk UTC stamps', () {
      final token = TokenInfo.fromOrderMap(<String, dynamic>{
        'token_label': '42',
        'token_number': 42,
        'token_status': 'collected',
        'token_ready_at': '2026-10-09 15:10:00',
        'token_collected_at': '2026-10-09 15:12:30',
      })!;
      expect(token.status, TokenStatus.collected);
      expect(token.title, 'Token 42');
      expect(token.readyAt, DateTime.utc(2026, 10, 9, 15, 10));
      expect(token.collectedAt, DateTime.utc(2026, 10, 9, 15, 12, 30));
      expect(TokenStatus.fromWire('ready'), TokenStatus.ready);
      expect(TokenStatus.fromWire('served'), TokenStatus.unknown);
      expect(FulfillmentType.fromWire('standing'), FulfillmentType.standing);
      expect(FulfillmentType.fromWire('dine_in'), isNull);
    });

    test('order:ready names a token order by its token', () {
      final ticket =
          ReadyTicket.fromPayload(fixture('order_ready_token.json'))!;
      expect(ticket.orderId, 'ord_9c21');
      expect(ticket.tokenLabel, 'T-07');
      expect(ticket.tableName, 'Token T-07');
      expect(ticket.tableId, isNull);
      expect(ticket.kotNumber, 'KOT-0129');
      expect(ticket.itemLabels,
          <String>['2× Paneer Tikka Roll', '2× Masala Chai']);
    });

    test('order:ready without a token keeps the old names', () {
      ReadyTicket ready(Map<String, dynamic> m) =>
          ReadyTicket.fromPayload(<String, dynamic>{'order_id': 'o1', ...m})!;
      expect(ready(<String, dynamic>{'table_name': 'T4'}).tableName, 'T4');
      expect(ready(<String, dynamic>{'order_type': 'takeaway'}).tableName,
          'Takeaway');
      expect(ready(<String, dynamic>{}).tableName, 'Order');
      expect(ReadyTicket.fromPayload(<String, dynamic>{'table_name': 'T4'}),
          isNull,
          reason: 'no order id, nothing to show');
    });
  });

  group('qsr:checkout ack', () {
    final ack = fixture('qsr_checkout_ack.json');

    test('order, KOT, bills, payments and the token all parse', () {
      final order = ServerOrder.fromMap(ack['order'] as Map<String, dynamic>);
      expect(order.status, 'paid');
      expect(order.fulfillmentType, FulfillmentType.standing);
      expect(order.token!.label, 'S-03');

      final token = TokenInfo.tryParse(ack['token'])!;
      expect(token.number, 3);
      expect(token.label, ack['token_label']);
      expect(token.date, '2026-10-09');
      expect(token.status, TokenStatus.preparing);

      final kot = ack['kot'] as Map<String, dynamic>;
      expect(kot['kot_number'], 'KOT-0130');
      expect(kot['token_label'], 'S-03');
      expect(kot['payment_tag'], 'PRE-PAID');

      final bills = (ack['bills'] as List<dynamic>)
          .map((b) => ServerBill.fromMap(b as Map<String, dynamic>))
          .toList();
      expect(bills.single.billType, 'food');
      expect(bills.single.totalAmount, const Money.rupees(1050));

      final payments =
          (ack['payments'] as List<dynamic>).cast<Map<String, dynamic>>();
      final paid =
          payments.map((p) => Money.fromWire(p['amount'])!).toList().sumMoney();
      expect(paid, bills.single.totalAmount);
      final cover = payments.first;
      expect(cover['payment_mode'], 'cover_ticket');
      expect(cover['reference_number'], 'ET-041');
      final coverInfo = cover['cover'] as Map<String, dynamic>;
      expect(coverInfo['ticket_number'], 'ET-041');
      expect(Money.fromWire(coverInfo['cover_balance_after']), Money.zero);
      expect(ack['order_settled'], isTrue);
    });
  });

  group('cover gating (no separate redeem permission)', () {
    const on = TicketConfig(coverPaymentMode: 'cover_ticket');
    FeatureFlags f({bool tickets = true, bool collect = true}) =>
        FeatureFlags.fromMap(<String, dynamic>{
          'flag_entry_tickets': tickets,
          'flag_collect_payment': collect,
        });

    test('needs entry tickets, collect payment and a cover mode', () {
      expect(canRedeemCover(f(), on), isTrue);
      expect(canRedeemCover(f(tickets: false), on), isFalse);
      expect(canRedeemCover(f(collect: false), on), isFalse);
      expect(canRedeemCover(f(), TicketConfig.none), isFalse);
    });
  });

  group('lenient parsing', () {
    test('a ticket type with no unit_total is dropped, the rest kept', () {
      final types = TicketType.listFrom(<Object>[
        <String, dynamic>{'id': 'a', 'name': 'A', 'price': 100},
        <String, dynamic>{'id': 'b', 'name': 'B', 'unit_total': 100},
        'junk',
      ]);
      expect(types.map((t) => t.id), <String>['b']);
      expect(types.single.price, const Money.rupees(100),
          reason: 'price falls back to the charged total');
      expect(types.single.pax, 1);
      expect(types.single.gstInclusive, isTrue, reason: 'spec default');
    });

    test('ticket types and pay modes come back in sort order', () {
      final types = TicketType.listFrom(<Object>[
        <String, dynamic>{'id': 'b', 'unit_total': 1, 'sort_order': 2},
        <String, dynamic>{'id': 'a', 'unit_total': 1, 'sort_order': 1},
        <String, dynamic>{'id': 'c', 'unit_total': 1, 'sort_order': 2},
      ]);
      expect(types.map((t) => t.id), <String>['a', 'b', 'c']);
      final modes = PayMode.listFrom(<Object>[
        <String, dynamic>{'code': 'custom_b', 'sort_order': 5},
        <String, dynamic>{'code': 'custom_a', 'sort_order': 1},
      ]);
      expect(modes.map((m) => m.code), <String>['custom_a', 'custom_b']);
    });

    test('system modes and rows without a code never become pay modes', () {
      final modes = PayMode.listFrom(<Object>[
        <String, dynamic>{'code': 'complimentary', 'is_system': 1},
        <String, dynamic>{'code': 'custom_swiggy', 'name': 'Swiggy'},
        <String, dynamic>{'name': 'no code'},
      ]);
      expect(modes.map((m) => m.code), <String>['custom_swiggy']);
      expect(PayMode.listFrom(null), isEmpty);
    });

    test('ticket config defaults when parts are missing', () {
      final cfg = TicketConfig.tryParse(<String, dynamic>{})!;
      expect(cfg.coverPaymentMode, isNull);
      expect(cfg.qrPrefix, 'CDT:');
      expect(TicketConfig.tryParse(null), isNull);
      expect(TicketConfig.none.coverPaymentMode, isNull);
    });
  });

  group('TenderLine.toWire', () {
    test('a paid line with an amount and reference', () {
      const line =
          TenderLine(mode: 'upi', amount: Money(25050), reference: 'UTR123');
      expect(line.toWire(), <String, dynamic>{
        'payment_mode': 'upi',
        'amount': 250.5,
        'reference_number': 'UTR123',
      });
    });

    test('the fill line leaves the amount out (the desk fills the balance)',
        () {
      expect(const TenderLine(mode: 'cash').toWire(),
          <String, dynamic>{'payment_mode': 'cash'});
    });

    test('a cover line carries its ticket code and may omit the amount', () {
      const line =
          TenderLine(mode: 'cover_ticket', ticketCode: 'CDT:7QKX2MZ4HB6TNW3R');
      expect(line.isCover, isTrue);
      expect(line.toWire(), <String, dynamic>{
        'payment_mode': 'cover_ticket',
        'ticket_code': 'CDT:7QKX2MZ4HB6TNW3R',
      });
    });

    test('a custom mode that asks why sends mode_reason', () {
      const line = TenderLine(
          mode: 'custom_staff', amount: Money(10000), reason: 'Owner guest');
      expect(line.toWire()['mode_reason'], 'Owner guest');
      expect(line.isCover, isFalse);
    });
  });
}
