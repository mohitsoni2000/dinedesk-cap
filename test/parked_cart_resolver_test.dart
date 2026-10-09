import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/models/token.dart';
import 'package:restro/services/parked_cart_resolver.dart';

import 'support/parked_fixtures.dart';

/// A parked cart is days-old data: when it comes back the menu may have
/// moved on. The resolver puts it back against TODAY's menu (or ticket
/// types): what is gone is dropped, what costs differently is kept at the
/// price now, and both are reported so the cashier hears about them.
void main() {
  Money cartTotal(ResolvedCart resolved) =>
      resolved.lines.map((line) => line.lineTotal).sumMoney();
  Money saleTotal(ResolvedTicketDraft resolved) => resolved.lines
      .map((line) => line.type.unitTotal.times(line.qty))
      .sumMoney();

  ResolvedCart resolve(List<CartLine> parked, List<MenuItem> menu,
          {String notes = '', FulfillmentType? fulfillment}) =>
      resolveCounterCart(
        CounterCartDraft.fromCart(parked,
            notes: notes, fulfillment: fulfillment),
        menu,
      );

  group('a menu that did not change', () {
    test('gives the same cart back with nothing to report', () {
      final menu = <MenuItem>[menuItem(), coffee()];
      final resolved =
          resolve(<CartLine>[dosaLine(qty: 3), coffeeLine()], menu);

      expect(resolved.needsAttention, isFalse);
      expect(resolved.dropped, isEmpty);
      expect(resolved.repriced, isEmpty);
      expect(resolved.isEmpty, isFalse);

      final dosa = resolved.lines[0];
      expect(dosa.item.id, 'dosa');
      expect(dosa.qty, 3);
      expect(dosa.unitPrice, const Money.rupees(100));

      final cold = resolved.lines[1];
      expect(cold.item.id, 'coffee');
      expect(cold.qty, 2);
      expect(cold.itemNote, 'less ice');
      expect(cold.variationId, 'v-lrg');
      expect(cold.variationName, 'Large');
      expect(cold.mods, <String>['Large', 'Extra shot', 'Ice cream']);
      expect(cold.selectedOptions.single.optionName, 'Extra shot');
      expect(cold.selectedOptions.single.priceModifier, const Money.rupees(30));
      expect(cold.selectedAddons.single.groupId, 'ag-top');
      expect(cold.selectedAddons.single.choices.single.choiceId, 'c-ice');
      expect(cold.modsExtra, const Money.rupees(70));
      expect(cold.unitPrice, const Money.rupees(230));
      expect(cold.lineTotal, const Money.rupees(460));
      expect(cartTotal(resolved), const Money.rupees(300 + 460));
    });

    test('hands back lines built on the menu\'s own items', () {
      final live = menuItem();
      final resolved = resolve(<CartLine>[dosaLine()], <MenuItem>[live]);
      expect(identical(resolved.lines.single.item, live), isTrue,
          reason: 'the cart is priced from today\'s item, not a stale copy');
    });

    test('keeps the order notes and how the order leaves the counter', () {
      final resolved = resolve(<CartLine>[dosaLine()], <MenuItem>[menuItem()],
          notes: 'birthday', fulfillment: FulfillmentType.standing);
      expect(resolved.notes, 'birthday');
      expect(resolved.fulfillment, FulfillmentType.standing);
    });

    test('keeps a weighed line\'s weight and prices it by weight', () {
      final loose = menuItem(
          id: 'paneer', name: 'Loose Paneer', rupees: 400, measureUnit: 'kg');
      final resolved = resolve(
        <CartLine>[CartLine(item: loose, qty: 1, weight: 0.5)],
        <MenuItem>[loose],
      );
      expect(resolved.lines.single.weight, 0.5);
      expect(resolved.lines.single.lineTotal, const Money.rupees(200));
    });
  });

  group('an item that is gone', () {
    test('a removed item is dropped and reported', () {
      final resolved = resolve(
        <CartLine>[dosaLine(qty: 2), coffeeLine()],
        <MenuItem>[coffee()],
      );

      expect(resolved.lines.map((l) => l.item.id), <String>['coffee']);
      final gone = resolved.dropped.single;
      expect(gone.issue, DropIssue.itemRemoved);
      expect(gone.itemName, 'Masala Dosa');
      expect(gone.qty, 2);
      expect(gone.detail, isNull);
      expect(gone.message, 'Masala Dosa ×2 — no longer on the menu');
      expect(resolved.needsAttention, isTrue);
    });

    test('an unavailable item is dropped and reported', () {
      final resolved = resolve(
        <CartLine>[dosaLine(), coffeeLine()],
        <MenuItem>[menuItem(available: false), coffee()],
      );

      expect(resolved.lines.map((l) => l.item.id), <String>['coffee']);
      final gone = resolved.dropped.single;
      expect(gone.issue, DropIssue.itemUnavailable);
      expect(gone.itemName, 'Masala Dosa');
      expect(gone.message, 'Masala Dosa — not available right now');
    });

    test('with every item gone nothing is left and the draft says so', () {
      final resolved = resolve(<CartLine>[dosaLine(), coffeeLine()], const []);
      expect(resolved.lines, isEmpty);
      expect(resolved.isEmpty, isTrue);
      expect(resolved.dropped, hasLength(2));
      expect(resolved.needsAttention, isTrue);
    });

    test('an item that is now sold by weight (or no longer) is dropped', () {
      final nowLoose = menuItem(rupees: 100, measureUnit: 'kg');
      var resolved = resolve(<CartLine>[dosaLine()], <MenuItem>[nowLoose]);
      expect(resolved.lines, isEmpty,
          reason: 'a count-priced line would price a weighed item at nothing');
      expect(resolved.dropped.single.issue, DropIssue.itemChanged);

      final loose = menuItem(rupees: 100, measureUnit: 'kg');
      resolved = resolve(
        <CartLine>[CartLine(item: loose, qty: 1, weight: 2)],
        <MenuItem>[menuItem()],
      );
      expect(resolved.lines, isEmpty);
      expect(resolved.dropped.single.issue, DropIssue.itemChanged);
    });
  });

  group('a price that moved', () {
    test('a repriced item is kept at the current price and reported', () {
      final resolved = resolve(
          <CartLine>[dosaLine(qty: 2)], <MenuItem>[menuItem(rupees: 120)]);

      final line = resolved.lines.single;
      expect(line.qty, 2);
      expect(line.unitPrice, const Money.rupees(120));
      expect(line.lineTotal, const Money.rupees(240));
      expect(resolved.dropped, isEmpty);

      final moved = resolved.repriced.single;
      expect(moved.itemName, 'Masala Dosa');
      expect(moved.was, const Money.rupees(100));
      expect(moved.now, const Money.rupees(120));
      expect(moved.message, 'Masala Dosa — ₹100 → ₹120 each');
      expect(resolved.needsAttention, isTrue);
    });

    test('a cheaper item is reported too', () {
      final resolved =
          resolve(<CartLine>[dosaLine()], <MenuItem>[menuItem(rupees: 80)]);
      expect(resolved.lines.single.unitPrice, const Money.rupees(80));
      expect(resolved.repriced.single.was, const Money.rupees(100));
      expect(resolved.repriced.single.now, const Money.rupees(80));
    });

    test('a changed variation price follows the variation', () {
      final resolved =
          resolve(<CartLine>[coffeeLine()], <MenuItem>[coffee(large: 170)]);

      final line = resolved.lines.single;
      expect(line.variationId, 'v-lrg');
      expect(line.unitPrice, const Money.rupees(240),
          reason: '120 + 50 + 30 + 40');
      expect(resolved.repriced.single.was, const Money.rupees(230));
      expect(resolved.repriced.single.now, const Money.rupees(240));
    });

    test('a moved base price carries the variation with it', () {
      final resolved = resolve(<CartLine>[coffeeLine()],
          <MenuItem>[coffee(regular: 130, large: 170)]);
      expect(resolved.lines.single.unitPrice, const Money.rupees(240));
      expect(resolved.repriced.single.now, const Money.rupees(240));
    });

    test('changed option and add-on prices are kept at the current price', () {
      final resolved = resolve(<CartLine>[coffeeLine()],
          <MenuItem>[coffee(extraShot: 35, iceCream: 45)]);

      final line = resolved.lines.single;
      expect(line.selectedOptions.single.priceModifier, const Money.rupees(35));
      expect(line.selectedAddons.single.choices.single.price,
          const Money.rupees(45));
      expect(line.unitPrice, const Money.rupees(240),
          reason: '120 + 40 + 35 + 45');
      expect(resolved.dropped, isEmpty);
      final moved = resolved.repriced.single;
      expect(moved.was, const Money.rupees(230));
      expect(moved.now, const Money.rupees(240));
    });

    test('a price that moved is measured against what stayed on the line', () {
      // The ice cream (₹40) is gone and the Extra shot went from ₹30 to ₹35:
      // the rest of the cup cost ₹190 when parked and costs ₹195 now.
      final resolved = resolve(<CartLine>[coffeeLine()],
          <MenuItem>[coffee(withIceCream: false, extraShot: 35)]);

      expect(resolved.dropped.single.issue, DropIssue.addonRemoved);
      expect(resolved.lines.single.unitPrice, const Money.rupees(195));
      expect(resolved.repriced.single.was, const Money.rupees(190));
      expect(resolved.repriced.single.now, const Money.rupees(195));
    });

    test('two moves that cancel out are not worth a warning', () {
      // Base +10, the Large premium -10: the Large coffee still costs 160.
      final resolved = resolve(<CartLine>[coffeeLine()],
          <MenuItem>[coffee(regular: 130, large: 160)]);
      expect(resolved.lines.single.unitPrice, const Money.rupees(230));
      expect(resolved.repriced, isEmpty);
    });
  });

  group('a choice that vanished', () {
    test('a vanished add-on is dropped; the rest of the line stays', () {
      final resolved = resolve(
          <CartLine>[coffeeLine()], <MenuItem>[coffee(withIceCream: false)]);

      final line = resolved.lines.single;
      expect(line.qty, 2);
      expect(line.selectedAddons, isEmpty);
      expect(line.variationId, 'v-lrg');
      expect(line.selectedOptions.single.optionName, 'Extra shot');
      expect(line.mods, <String>['Large', 'Extra shot']);
      expect(line.itemNote, 'less ice');
      expect(line.unitPrice, const Money.rupees(190));

      final gone = resolved.dropped.single;
      expect(gone.issue, DropIssue.addonRemoved);
      expect(gone.itemName, 'Cold Coffee');
      expect(gone.detail, 'Ice cream');
      expect(gone.message, 'Cold Coffee — Ice cream is no longer offered');
      expect(resolved.repriced, isEmpty,
          reason: 'the price fell because of the drop, not a price change');
    });

    test('an add-on group that vanished drops every choice taken from it', () {
      final resolved = resolve(<CartLine>[coffeeLine()],
          <MenuItem>[coffee(addonGroupId: 'ag-renamed')]);
      expect(resolved.lines.single.selectedAddons, isEmpty);
      expect(resolved.dropped.single.issue, DropIssue.addonRemoved);
    });

    test('a vanished option is dropped', () {
      final resolved = resolve(
          <CartLine>[coffeeLine()], <MenuItem>[coffee(withExtraShot: false)]);

      final line = resolved.lines.single;
      expect(line.selectedOptions, isEmpty);
      expect(line.mods, <String>['Large', 'Ice cream']);
      expect(line.modsExtra, const Money.rupees(40));
      expect(line.unitPrice, const Money.rupees(200));
      final gone = resolved.dropped.single;
      expect(gone.issue, DropIssue.optionRemoved);
      expect(gone.detail, 'Extra shot');
    });

    test('a vanished variation is dropped; the line falls back to the base',
        () {
      final resolved = resolve(
          <CartLine>[coffeeLine()], <MenuItem>[coffee(withLarge: false)]);

      final line = resolved.lines.single;
      expect(line.variationId, isNull);
      expect(line.variationName, isNull);
      expect(line.mods, <String>['Extra shot', 'Ice cream']);
      expect(line.modsExtra, const Money.rupees(30));
      expect(line.unitPrice, const Money.rupees(190));
      final gone = resolved.dropped.single;
      expect(gone.issue, DropIssue.variationRemoved);
      expect(gone.detail, 'Large');
      expect(gone.message, 'Cold Coffee — Large is no longer offered');
    });

    test('several things vanishing at once are each reported', () {
      final resolved = resolve(<CartLine>[coffeeLine()],
          <MenuItem>[coffee(withLarge: false, withIceCream: false)]);
      expect(resolved.dropped.map((d) => d.issue).toSet(), <DropIssue>{
        DropIssue.variationRemoved,
        DropIssue.addonRemoved,
      });
      expect(resolved.lines.single.unitPrice, const Money.rupees(150));
    });

    test('a renamed variation is not a vanished one', () {
      final resolved = resolve(
          <CartLine>[coffeeLine()], <MenuItem>[coffee(largeName: 'Jumbo')]);
      expect(resolved.lines.single.variationName, 'Jumbo');
      expect(resolved.lines.single.mods,
          <String>['Jumbo', 'Extra shot', 'Ice cream']);
      expect(resolved.dropped, isEmpty);
      expect(resolved.repriced, isEmpty);
    });

    test('a renamed add-on keeps its place in the list under its new name', () {
      final renamed = menuItem(
        id: 'coffee',
        name: 'Cold Coffee',
        rupees: 120,
        addonGroups: <AddonGroup>[
          const AddonGroup(
            id: 'ag-top',
            itemId: 'coffee',
            name: 'Toppings',
            choices: <AddonChoice>[
              AddonChoice(
                  id: 'c-ice',
                  groupId: 'ag-top',
                  name: 'Gelato',
                  price: Money.rupees(40)),
            ],
          ),
        ],
      );
      final line = CartLine(
        item: coffee(),
        qty: 1,
        mods: const <String>['Ice cream'],
        selectedAddons: <SelectedAddonGroup>[
          const SelectedAddonGroup(
            groupId: 'ag-top',
            groupName: 'Toppings',
            choices: <SelectedAddonChoice>[
              SelectedAddonChoice(
                  choiceId: 'c-ice',
                  name: 'Ice cream',
                  price: Money.rupees(40)),
            ],
          ),
        ],
      );
      final resolved = resolve(<CartLine>[line], <MenuItem>[renamed]);
      expect(resolved.lines.single.mods, <String>['Gelato']);
      expect(resolved.lines.single.selectedAddons.single.choices.single.name,
          'Gelato');
      expect(resolved.dropped, isEmpty);
    });

    test('lines that become identical after a drop merge into one', () {
      final plain = CartLine(item: coffee(), qty: 1);
      final withIce = CartLine(
        item: coffee(),
        qty: 2,
        mods: const <String>['Ice cream'],
        selectedAddons: <SelectedAddonGroup>[
          const SelectedAddonGroup(
            groupId: 'ag-top',
            groupName: 'Toppings',
            choices: <SelectedAddonChoice>[
              SelectedAddonChoice(
                  choiceId: 'c-ice',
                  name: 'Ice cream',
                  price: Money.rupees(40)),
            ],
          ),
        ],
      );
      final resolved = resolve(
          <CartLine>[plain, withIce], <MenuItem>[coffee(withIceCream: false)]);

      expect(resolved.lines, hasLength(1));
      expect(resolved.lines.single.qty, 3);
    });
  });

  group('a parked ticket sale', () {
    final couple = ticketType();
    final stag =
        ticketType(id: 'tt-stag', name: 'Stag Entry', rupees: 600, pax: 1);

    TicketIssueDraft parked({
      String? guestName,
      String? guestPhone,
    }) =>
        TicketIssueDraft(
          lines: <ParkedTicketLine>[
            ParkedTicketLine.of(couple, 2),
            ParkedTicketLine.of(stag, 1),
          ],
          guestName: guestName,
          guestPhone: guestPhone,
        );

    test('comes back against the ticket types on sale', () {
      final resolved = resolveTicketIssue(
          parked(guestName: 'Meera', guestPhone: '9876500000'),
          <TicketType>[couple, stag]);

      expect(resolved.lines.map((l) => (l.type.id, l.qty)),
          <(String, int)>[('tt-couple', 2), ('tt-stag', 1)]);
      expect(resolved.guestName, 'Meera');
      expect(resolved.guestPhone, '9876500000');
      expect(saleTotal(resolved), const Money.rupees(2 * 1000 + 600));
      expect(resolved.needsAttention, isFalse);
    });

    test('a ticket type that is no longer on sale is dropped and reported', () {
      final resolved = resolveTicketIssue(parked(), <TicketType>[stag]);

      expect(resolved.lines.map((l) => l.type.id), <String>['tt-stag']);
      final gone = resolved.dropped.single;
      expect(gone.issue, DropIssue.typeRemoved);
      expect(gone.itemName, 'Couple Entry');
      expect(gone.qty, 2);
      expect(gone.message, 'Couple Entry ×2 — no longer on sale');
    });

    test('a repriced ticket type is kept at the current price and reported',
        () {
      final dearer = ticketType(rupees: 1200);
      final resolved = resolveTicketIssue(parked(), <TicketType>[dearer, stag]);

      expect(resolved.lines.first.type.unitTotal, const Money.rupees(1200));
      expect(saleTotal(resolved), const Money.rupees(2 * 1200 + 600));
      final moved = resolved.repriced.single;
      expect(moved.itemName, 'Couple Entry');
      expect(moved.was, const Money.rupees(1000));
      expect(moved.now, const Money.rupees(1200));
      expect(resolved.dropped, isEmpty);
    });

    test('a draft saved without prices cannot be called repriced', () {
      final resolved = resolveTicketIssue(
        const TicketIssueDraft(lines: <ParkedTicketLine>[
          ParkedTicketLine(ticketTypeId: 'tt-couple', qty: 2),
        ]),
        <TicketType>[ticketType(rupees: 1500)],
      );
      expect(resolved.lines.single.qty, 2);
      expect(resolved.repriced, isEmpty);
      expect(saleTotal(resolved), const Money.rupees(3000));
    });

    test('with no types on sale nothing is left', () {
      final resolved = resolveTicketIssue(parked(), const <TicketType>[]);
      expect(resolved.isEmpty, isTrue);
      expect(resolved.dropped, hasLength(2));
    });
  });

  group('resolveDraft', () {
    test('picks the resolver by what was parked', () {
      final cart = resolveDraft(cartDraft(),
          menu: <MenuItem>[menuItem()], ticketTypes: const <TicketType>[]);
      expect(cart, isA<ResolvedCart>());

      final tickets = resolveDraft(ticketDraft(),
          menu: const <MenuItem>[], ticketTypes: <TicketType>[ticketType()]);
      expect(tickets, isA<ResolvedTicketDraft>());
    });
  });
}
