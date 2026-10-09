import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/models/token.dart';
import 'package:restro/models/wire.dart';

import 'support/parked_fixtures.dart';

/// What a parked draft is made of, and how it is written down: the app's own
/// cart lines and `Money`, in the rupee numbers the wire speaks.
void main() {
  /// Through real JSON text, as it sits in SharedPreferences.
  Map<String, dynamic> viaDisk(Map<String, dynamic> json) =>
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

  group('a parked cart', () {
    test('survives JSON with every choice on its lines', () {
      final draft = CounterCartDraft.fromCart(
        <CartLine>[
          coffeeLine(),
          dosaLine(qty: 3),
          CartLine(
            item: menuItem(
                id: 'paneer',
                name: 'Loose Paneer',
                rupees: 400,
                measureUnit: 'kg'),
            qty: 1,
            weight: 0.35,
          ),
        ],
        notes: 'birthday table',
        fulfillment: FulfillmentType.standing,
      );

      final back = CounterCartDraft.fromJson(viaDisk(draft.toJson()));

      expect(back.toJson(), draft.toJson());
      expect(back.notes, 'birthday table');
      expect(back.fulfillment, FulfillmentType.standing);
      final cold = back.lines.first;
      expect(cold.itemId, 'coffee');
      expect(cold.variationId, 'v-lrg');
      expect(cold.variationPrice, const Money.rupees(160));
      expect(cold.options.single.optionName, 'Extra shot');
      expect(cold.addons.single.choices.single.choiceId, 'c-ice');
      expect(cold.mods, <String>['Large', 'Extra shot', 'Ice cream']);
      expect(cold.note, 'less ice');
      expect(back.lines.last.weight, 0.35);
    });

    test('keeps money exact to the paisa, as rupees on the wire', () {
      final line = CartLine(
        item: const MenuItem(
          id: 'tea',
          name: 'Cutting Chai',
          section: 'Drinks',
          kitchenSection: 'beverages',
          price: Money(9950),
          isVeg: true,
        ),
        qty: 3,
        modsExtra: const Money(333),
      );

      final draft = CounterCartDraft.fromCart(<CartLine>[line]);
      final stored = _line(viaDisk(draft.toJson()));
      expect(stored['item_price'], 99.5);
      expect(stored['mods_extra'], 3.33);

      final back = CounterCartDraft.fromJson(viaDisk(draft.toJson()));
      expect(back.lines.single.itemPrice, const Money(9950));
      expect(back.lines.single.modsExtra, const Money(333));
      expect(back.lines.single.unitPrice, const Money(10283));
      expect(back.total, const Money(30849));
    });

    test('adds up what it came to when parked', () {
      final draft = CounterCartDraft.fromCart(<CartLine>[
        dosaLine(qty: 2),
        coffeeLine(),
        CartLine(
          item: menuItem(
              id: 'paneer',
              name: 'Loose Paneer',
              rupees: 400,
              measureUnit: 'kg'),
          qty: 1,
          weight: 0.5,
        ),
      ]);
      expect(draft.total, const Money.rupees(200 + 460 + 200));
      expect(draft.isEmpty, isFalse);
    });

    test('is listed by name and count, a weighed line by its weight', () {
      final draft = CounterCartDraft.fromCart(<CartLine>[
        dosaLine(qty: 2),
        CartLine(
          item: menuItem(
              id: 'paneer',
              name: 'Loose Paneer',
              rupees: 400,
              measureUnit: 'kg'),
          qty: 1,
          weight: 2,
        ),
        CartLine(
          item: menuItem(
              id: 'paneer',
              name: 'Loose Paneer',
              rupees: 400,
              measureUnit: 'kg'),
          qty: 1,
          weight: 0.5,
        ),
      ]);
      expect(draft.summary,
          '2× Masala Dosa, Loose Paneer (2), Loose Paneer (0.5)');
    });

    test('a long cart is listed by its first few lines and a count of the rest',
        () {
      final draft = CounterCartDraft.fromCart(<CartLine>[
        for (var i = 1; i <= 5; i++)
          CartLine(item: menuItem(id: 'i$i', name: 'Item $i'), qty: 1),
      ]);
      expect(draft.summary, '1× Item 1, 1× Item 2, 1× Item 3 +2 more');
    });

    test('a cart with nothing in it is empty', () {
      expect(const CounterCartDraft(lines: <ParkedCartLine>[]).isEmpty, isTrue);
    });

    for (final (name, change)
        in <(String, void Function(Map<String, dynamic>))>[
      ('no lines', (m) => m['lines'] = <Object?>[]),
      ('a line that is not an object', (m) => m['lines'] = <Object?>['x']),
      ('a line without its item', (m) => _line(m).remove('item_id')),
      ('a line without its price', (m) => _line(m).remove('item_price')),
      ('a quantity of zero', (m) => _line(m)['quantity'] = 0),
      ('a weight of nothing', (m) => _line(m)['weight'] = 0),
      ('a weight that is text', (m) => _line(m)['weight'] = 'heavy'),
      (
        'an option without its name',
        (m) => _line(m)['selected_options'] = <Object?>[
              <String, Object?>{'group_name': 'Sugar'}
            ]
      ),
    ]) {
      test('is unreadable with $name', () {
        final json = viaDisk(cartDraft().toJson());
        change(json);
        expect(() => CounterCartDraft.fromJson(json),
            throwsA(isA<WireFormatException>()));
      });
    }
  });

  group('a parked ticket sale', () {
    final couple = ticketType();
    final stag =
        ticketType(id: 'tt-stag', name: 'Stag Entry', rupees: 600, pax: 1);

    test('survives JSON with the guest', () {
      final draft = TicketIssueDraft(
        lines: <ParkedTicketLine>[
          ParkedTicketLine.of(couple, 2),
          ParkedTicketLine.of(stag, 1),
        ],
        guestName: 'Meera',
        guestPhone: '9876500000',
      );
      final back = TicketIssueDraft.fromJson(viaDisk(draft.toJson()));
      expect(back.toJson(), draft.toJson());
      expect(back.lines.map((l) => (l.ticketTypeId, l.qty)),
          <(String, int)>[('tt-couple', 2), ('tt-stag', 1)]);
      expect(back.guestName, 'Meera');
      expect(back.guestPhone, '9876500000');
    });

    test('needs only the type and the count', () {
      final json = viaDisk(<String, dynamic>{
        'lines': <Object?>[
          <String, Object?>{'ticket_type_id': 'tt-couple', 'qty': 2},
        ],
      });
      final draft = TicketIssueDraft.fromJson(json);
      expect(draft.lines.single.name, isNull);
      expect(draft.lines.single.unitTotal, isNull);
      expect(draft.guestName, isNull);
      expect(draft.total, isNull, reason: 'no prices were saved');
      expect(draft.summary, '2× Ticket');
    });

    test('adds up what it came to, and says what it is', () {
      final draft = TicketIssueDraft(lines: <ParkedTicketLine>[
        ParkedTicketLine.of(couple, 2),
        ParkedTicketLine.of(stag, 1),
      ]);
      expect(draft.total, const Money.rupees(2600));
      expect(draft.summary, '2× Couple Entry, 1× Stag Entry');
      expect(draft.kind, ParkedKind.ticketIssue);
    });

    test('leaves out a guest that was left blank', () {
      final json = TicketIssueDraft(
        lines: <ParkedTicketLine>[ParkedTicketLine.of(couple, 1)],
        guestName: '  ',
        guestPhone: '',
      ).toJson();
      expect(json.containsKey('guest_name'), isFalse);
      expect(json.containsKey('guest_phone'), isFalse);
    });

    for (final (name, change)
        in <(String, void Function(Map<String, dynamic>))>[
      ('no lines', (m) => m['lines'] = <Object?>[]),
      (
        'a line without its type',
        (m) => _ticketLine(m).remove('ticket_type_id')
      ),
      ('a count of zero', (m) => _ticketLine(m)['qty'] = 0),
    ]) {
      test('is unreadable with $name', () {
        final json = viaDisk(ticketDraft().toJson());
        change(json);
        expect(() => TicketIssueDraft.fromJson(json),
            throwsA(isA<WireFormatException>()));
      });
    }
  });

  group('a draft', () {
    ParkedDraft sample() => draftOf(
          cartDraft(),
          createdAt: DateTime.utc(2026, 10, 9, 10, 15, 30, 250),
          seq: 4,
        );

    test('is labelled P and its number', () {
      expect(sample().label, 'P4');
    });

    test('is written with its stamp and read back the same', () {
      final back = ParkedDraft.fromJson(viaDisk(sample().toJson()));
      expect(back.id, sample().id);
      expect(back.scope, asha);
      expect(back.seq, 4);
      expect(back.createdAt, DateTime.utc(2026, 10, 9, 10, 15, 30, 250));
      expect(back.createdAt.isUtc, isTrue);
      expect(back.kind, ParkedKind.counterCart);
      expect(back.payload.toJson(), sample().payload.toJson());
    });

    test('is stored in UTC whatever the phone\'s clock zone', () {
      final local = DateTime.utc(2026, 10, 9, 10, 15).toLocal();
      final json = draftOf(cartDraft(), createdAt: local).toJson();
      expect(json['created_at'], '2026-10-09T10:15:00.000Z');
    });

    test('an unknown kind is unreadable here, not a different kind', () {
      final json = viaDisk(sample().toJson())..['kind'] = 'banquetHold';
      expect(() => ParkedDraft.fromJson(json),
          throwsA(isA<WireFormatException>()));
      expect(ParkedKind.fromName('banquetHold'), isNull);
      expect(ParkedKind.fromName('counterCart'), ParkedKind.counterCart);
      expect(ParkedKind.fromName('ticketIssue'), ParkedKind.ticketIssue);
      expect(ParkedKind.fromName(null), isNull);
    });

    for (final (name, change)
        in <(String, void Function(Map<String, dynamic>))>[
      ('no id', (m) => m.remove('id')),
      ('no operator', (m) => m.remove('operator_id')),
      ('no desk', (m) => m.remove('desk_instance_id')),
      ('a time that is not a time', (m) => m['created_at'] = 'later'),
      ('no number', (m) => m.remove('seq')),
      ('a number of zero', (m) => m['seq'] = 0),
      ('no payload', (m) => m.remove('payload')),
      ('a payload that is text', (m) => m['payload'] = 'x'),
    ]) {
      test('is unreadable with $name', () {
        final json = viaDisk(sample().toJson());
        change(json);
        expect(() => ParkedDraft.fromJson(json),
            throwsA(isA<WireFormatException>()));
      });
    }
  });

  group('a scope', () {
    test('is the pair of operator and desk, compared by value', () {
      expect(const ParkedScope(operatorId: 'a', deskInstanceId: 'd'),
          const ParkedScope(operatorId: 'a', deskInstanceId: 'd'));
      expect(const ParkedScope(operatorId: 'a', deskInstanceId: 'd'),
          isNot(const ParkedScope(operatorId: 'a', deskInstanceId: 'e')));
      expect(const ParkedScope(operatorId: 'a', deskInstanceId: 'd').hashCode,
          const ParkedScope(operatorId: 'a', deskInstanceId: 'd').hashCode);
    });
  });

  test('a ticket line made from a type carries its name and price', () {
    final line = ParkedTicketLine.of(ticketType(rupees: 750), 3);
    expect(line.ticketTypeId, 'tt-couple');
    expect(line.qty, 3);
    expect(line.name, 'Couple Entry');
    expect(line.unitTotal, const Money.rupees(750));
  });
}

Map<String, dynamic> _line(Map<String, dynamic> cart) =>
    (cart['lines'] as List<Object?>).first as Map<String, dynamic>;

Map<String, dynamic> _ticketLine(Map<String, dynamic> sale) =>
    (sale['lines'] as List<Object?>).first as Map<String, dynamic>;
