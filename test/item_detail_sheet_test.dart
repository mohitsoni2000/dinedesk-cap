import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/item_detail_sheet.dart';

/// The item sheet opened from the menu adds; opened on a cart line it edits
/// that line and keeps everything the line already had.
void main() {
  const pizza = MenuItem(
    id: 'itm_pizza',
    name: 'Margherita',
    section: 'Pizza',
    kitchenSection: 'curry',
    price: Money.rupees(200),
    isVeg: true,
    variations: <MenuItemVariation>[
      MenuItemVariation(id: 'v_small', name: 'Small', price: Money.rupees(200)),
      MenuItemVariation(id: 'v_large', name: 'Large', price: Money.rupees(300)),
    ],
  );

  const burger = MenuItem(
    id: 'itm_burger',
    name: 'Veg Burger',
    section: 'Burgers',
    kitchenSection: 'curry',
    price: Money.rupees(120),
    isVeg: true,
    addonGroups: <AddonGroup>[
      AddonGroup(
        id: 'g_addons',
        itemId: 'itm_burger',
        name: 'Add-ons',
        selectionType: 'M',
        maxSelect: 3,
        choices: <AddonChoice>[
          AddonChoice(
              id: 'c_cheese',
              groupId: 'g_addons',
              name: 'Extra Cheese',
              price: Money.rupees(30)),
        ],
      ),
    ],
  );

  const paneer = MenuItem(
    id: 'itm_paneer',
    name: 'Paneer',
    section: 'Dairy',
    kitchenSection: 'curry',
    price: Money.rupees(400),
    isVeg: true,
    measureUnit: 'kg',
  );

  late ProviderContainer container;

  Future<void> openSheet(WidgetTester tester, MenuItem item,
      {CartLine? editing}) async {
    tester.view.physicalSize = const Size(1024, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                  ItemDetailSheet.show(context, item, editing: editing)),
              child: const Text('open sheet'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    container = ProviderContainer();
    container.read(flagsProvider.notifier).state =
        FeatureFlags.fromMap(const <String, dynamic>{'flag_item_variations': 1});
  });
  tearDown(() => container.dispose());

  List<CartLine> cart() => container.read(cartProvider);

  testWidgets('from the menu, a second size is added as its own line',
      (tester) async {
    container.read(cartProvider.notifier).addCustom(
          item: pizza,
          qty: 1,
          mods: const <String>['Small'],
          modsExtra: Money.zero,
          itemNote: '',
          variationId: 'v_small',
          variationName: 'Small',
        );
    await openSheet(tester, pizza);

    expect(find.text('Add to Order'), findsOneWidget);
    await tester.tap(find.text('Large'));
    await tester.pump();
    await tester.tap(find.text('Add to Order'));
    await tester.pumpAndSettle();

    expect(cart().map((l) => l.variationId).toList(),
        containsAll(<String>['v_small', 'v_large']));
    expect(cart().length, 2);
  });

  testWidgets('editing a cart line keeps the add-ons it already had',
      (tester) async {
    container.read(cartProvider.notifier).addCustom(
          item: burger,
          qty: 2,
          mods: const <String>['Extra Cheese'],
          modsExtra: Money.zero,
          itemNote: '',
          selectedAddons: const <SelectedAddonGroup>[
            SelectedAddonGroup(
              groupId: 'g_addons',
              groupName: 'Add-ons',
              choices: <SelectedAddonChoice>[
                SelectedAddonChoice(
                    choiceId: 'c_cheese',
                    name: 'Extra Cheese',
                    price: Money.rupees(30)),
              ],
            ),
          ],
        );
    await openSheet(tester, burger, editing: cart().single);

    await tester.tap(find.text('Update Item'));
    await tester.pumpAndSettle();

    final line = cart().single;
    expect(line.qty, 2);
    expect(line.selectedAddons.single.choices.single.choiceId, 'c_cheese');
  });

  testWidgets('editing a weighed line starts from its weight',
      (tester) async {
    container.read(cartProvider.notifier).addCustom(
          item: paneer,
          qty: 1,
          mods: const <String>[],
          modsExtra: Money.zero,
          itemNote: '',
          weight: 0.5,
        );
    await openSheet(tester, paneer, editing: cart().single);

    expect(find.text('Update Item'), findsOneWidget,
        reason: 'the weight is already there, so nothing is missing');
    await tester.tap(find.text('Update Item'));
    await tester.pumpAndSettle();

    expect(cart().single.weight, 0.5);
  });

  testWidgets('from the menu, a weighed item adds a second portion',
      (tester) async {
    container.read(cartProvider.notifier).addCustom(
          item: paneer,
          qty: 1,
          mods: const <String>[],
          modsExtra: Money.zero,
          itemNote: '',
          weight: 0.5,
        );
    await openSheet(tester, paneer);

    await tester.enterText(find.byType(TextField).first, '0.3');
    await tester.pump();
    await tester.tap(find.text('Add to Order'));
    await tester.pumpAndSettle();

    expect(cart().map((l) => l.weight).toList(),
        containsAll(<double>[0.5, 0.3]));
  });
}
