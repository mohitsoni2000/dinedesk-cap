import 'dart:convert';

import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/parked_draft.dart';

/// Who parks in the parked-drafts tests: two operators on one desk, and the
/// first operator on a second desk.
const ParkedScope asha =
    ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-1');
const ParkedScope ravi =
    ParkedScope(operatorId: 'op-ravi', deskInstanceId: 'desk-1');
const ParkedScope ashaElsewhere =
    ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-2');

MenuItem menuItem({
  String id = 'dosa',
  String name = 'Masala Dosa',
  int rupees = 100,
  bool available = true,
  String? measureUnit,
  List<MenuItemVariation> variations = const <MenuItemVariation>[],
  List<MenuOptionGroup> optionGroups = const <MenuOptionGroup>[],
  List<AddonGroup> addonGroups = const <AddonGroup>[],
}) =>
    MenuItem(
      id: id,
      name: name,
      section: 'Mains',
      kitchenSection: 'south',
      price: Money.rupees(rupees),
      isVeg: true,
      available: available,
      measureUnit: measureUnit,
      variations: variations,
      optionGroups: optionGroups,
      addonGroups: addonGroups,
    );

/// An item with every kind of choice the item sheet offers: a Regular/Large
/// variation, a Sugar option group with a priced option, and a Toppings
/// add-on group with two priced choices.
MenuItem coffee({
  int regular = 120,
  int large = 160,
  String largeName = 'Large',
  bool withLarge = true,
  bool withExtraShot = true,
  int extraShot = 30,
  bool withIceCream = true,
  int iceCream = 40,
  String addonGroupId = 'ag-top',
  bool available = true,
}) =>
    menuItem(
      id: 'coffee',
      name: 'Cold Coffee',
      rupees: regular,
      available: available,
      variations: <MenuItemVariation>[
        MenuItemVariation(
            id: 'v-reg', name: 'Regular', price: Money.rupees(regular)),
        if (withLarge)
          MenuItemVariation(
              id: 'v-lrg', name: largeName, price: Money.rupees(large)),
      ],
      optionGroups: <MenuOptionGroup>[
        MenuOptionGroup(
          id: 'g-sugar',
          itemId: 'coffee',
          name: 'Sugar',
          options: <MenuOption>[
            const MenuOption(
                id: 'o-less', groupId: 'g-sugar', name: 'Less sugar'),
            if (withExtraShot)
              MenuOption(
                  id: 'o-shot',
                  groupId: 'g-sugar',
                  name: 'Extra shot',
                  priceModifier: Money.rupees(extraShot)),
          ],
        ),
      ],
      addonGroups: <AddonGroup>[
        AddonGroup(
          id: addonGroupId,
          itemId: 'coffee',
          name: 'Toppings',
          choices: <AddonChoice>[
            if (withIceCream)
              AddonChoice(
                  id: 'c-ice',
                  groupId: addonGroupId,
                  name: 'Ice cream',
                  price: Money.rupees(iceCream)),
            AddonChoice(
                id: 'c-choc',
                groupId: addonGroupId,
                name: 'Choco chips',
                price: const Money.rupees(25)),
          ],
        ),
      ],
    );

/// A cart line built the way the item sheet builds one: a Large variation
/// (+₹40 over the base), the Extra shot option (+₹30) and the Ice cream
/// add-on (+₹40). With [coffee]'s defaults one unit is ₹120 + ₹70 + ₹40 = ₹230.
CartLine coffeeLine({MenuItem? item, int qty = 2}) => CartLine(
      item: item ?? coffee(),
      qty: qty,
      mods: const <String>['Large', 'Extra shot', 'Ice cream'],
      selectedOptions: <SelectedOption>[
        const SelectedOption(
            groupName: 'Sugar',
            optionName: 'Extra shot',
            priceModifier: Money.rupees(30)),
      ],
      selectedAddons: <SelectedAddonGroup>[
        const SelectedAddonGroup(
          groupId: 'ag-top',
          groupName: 'Toppings',
          choices: <SelectedAddonChoice>[
            SelectedAddonChoice(
                choiceId: 'c-ice', name: 'Ice cream', price: Money.rupees(40)),
          ],
        ),
      ],
      modsExtra: const Money.rupees(70),
      itemNote: 'less ice',
      variationId: 'v-lrg',
      variationName: 'Large',
    );

CartLine dosaLine({MenuItem? item, int qty = 1}) =>
    CartLine(item: item ?? menuItem(), qty: qty);

CounterCartDraft cartDraft([List<CartLine>? lines]) =>
    CounterCartDraft.fromCart(lines ?? <CartLine>[dosaLine()]);

TicketType ticketType({
  String id = 'tt-couple',
  String name = 'Couple Entry',
  int rupees = 1000,
  int pax = 2,
}) =>
    TicketType(
      id: id,
      name: name,
      price: Money.rupees(rupees),
      gstRate: 0,
      gstInclusive: true,
      coverAmount: Money.zero,
      pax: pax,
      sortOrder: 0,
      unitTotal: Money.rupees(rupees),
    );

TicketIssueDraft ticketDraft({
  List<ParkedTicketLine>? lines,
  String? guestName,
  String? guestPhone,
}) =>
    TicketIssueDraft(
      lines: lines ?? <ParkedTicketLine>[ParkedTicketLine.of(ticketType(), 2)],
      guestName: guestName,
      guestPhone: guestPhone,
    );

/// The text SharedPreferences holds under `parked_drafts_v1`.
String envelopeJson(List<Object?> entries, {Object? schema = 1}) =>
    jsonEncode(<String, Object?>{'schema': schema, 'drafts': entries});

/// A draft as it sits on disk, for seeding SharedPreferences directly.
ParkedDraft draftOf(
  ParkedPayload payload, {
  ParkedScope scope = asha,
  required DateTime createdAt,
  int seq = 1,
  String? id,
}) =>
    ParkedDraft(
      id: id ?? 'pk-${scope.operatorId}-${payload.kind.name}-$seq',
      scope: scope,
      createdAt: createdAt,
      seq: seq,
      payload: payload,
    );
