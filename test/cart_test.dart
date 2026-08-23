import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';

MenuItem _item({
  String id = 'itm_1',
  Money price = const Money(32000),
  String? measureUnit,
}) =>
    MenuItem(
      id: id,
      name: 'Paneer Tikka',
      section: 'Starters',
      kitchenSection: 'tandoor',
      price: price,
      isVeg: true,
      measureUnit: measureUnit,
    );

SelectedAddonGroup _cheese() => const SelectedAddonGroup(
      groupId: 'g1',
      groupName: 'Add-ons',
      choices: <SelectedAddonChoice>[
        SelectedAddonChoice(
          choiceId: 'c_cheese',
          name: 'Extra Cheese',
          price: Money(6000),
        ),
      ],
    );

void main() {
  group('AUDIT #8 — add-on lines must not absorb plain taps', () {
    test('a plain tap does not merge into an add-on line', () {
      final cart = CartNotifier();
      cart.addCustom(
        item: _item(),
        qty: 1,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
        selectedAddons: <SelectedAddonGroup>[_cheese()],
      );
      cart.addSimple(_item());

      expect(cart.state.length, 2);
      expect(cart.state[0].qty, 1);
      expect(cart.state[1].qty, 1);
      expect(cart.total, const Money(32000 + 6000 + 32000));
    });

    test('identical configurations do merge', () {
      final cart = CartNotifier();
      cart.addSimple(_item());
      cart.addSimple(_item());
      expect(cart.state.length, 1);
      expect(cart.state.single.qty, 2);
    });

    test('different notes stay separate', () {
      final cart = CartNotifier();
      cart.addCustom(
        item: _item(),
        qty: 1,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: 'extra crispy',
      );
      cart.addSimple(_item());
      expect(cart.state.length, 2);
    });

    test('add-on ordering does not affect the merge key', () {
      final cart = CartNotifier();
      const groupA = SelectedAddonGroup(
        groupId: 'g1',
        groupName: 'Add-ons',
        choices: <SelectedAddonChoice>[
          SelectedAddonChoice(choiceId: 'a', name: 'A', price: Money(1000)),
          SelectedAddonChoice(choiceId: 'b', name: 'B', price: Money(2000)),
        ],
      );
      const groupB = SelectedAddonGroup(
        groupId: 'g1',
        groupName: 'Add-ons',
        choices: <SelectedAddonChoice>[
          SelectedAddonChoice(choiceId: 'b', name: 'B', price: Money(2000)),
          SelectedAddonChoice(choiceId: 'a', name: 'A', price: Money(1000)),
        ],
      );
      cart.addCustom(
        item: _item(),
        qty: 1,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
        selectedAddons: <SelectedAddonGroup>[groupA],
      );
      cart.addCustom(
        item: _item(),
        qty: 1,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
        selectedAddons: <SelectedAddonGroup>[groupB],
      );
      expect(cart.state.length, 1);
      expect(cart.state.single.qty, 2);
    });
  });

  group('AUDIT #8 — the tile decrement only touches plain lines', () {
    test('decrementing does not rewrite a configured line', () {
      final cart = CartNotifier();
      cart.addCustom(
        item: _item(),
        qty: 5,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
        selectedAddons: <SelectedAddonGroup>[_cheese()],
      );
      cart.addSimple(_item());
      cart.addSimple(_item());

      cart.decrementPlainLine('itm_1');

      final configured = cart.state.firstWhere((l) => !l.isPlain);
      final plain = cart.state.firstWhere((l) => l.isPlain);

      expect(configured.qty, 5);
      expect(plain.qty, 1);
    });

    test('the badge counts only plain lines', () {
      final cart = CartNotifier();
      cart.addCustom(
        item: _item(),
        qty: 3,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
        selectedAddons: <SelectedAddonGroup>[_cheese()],
      );
      cart.addSimple(_item());
      expect(cart.plainQtyByItemId['itm_1'], 1);
    });

    test('decrementing to zero removes the line', () {
      final cart = CartNotifier();
      cart.addSimple(_item());
      cart.decrementPlainLine('itm_1');
      expect(cart.state, isEmpty);
    });
  });

  group('AUDIT #8 — weighed items', () {
    test('addSimple refuses a weighed item instead of adding it at zero', () {
      final cart = CartNotifier();

      expect(
        () => cart.addSimple(_item(measureUnit: 'kg')),
        throwsA(isA<AssertionError>()),
      );
    });

    test('addCustom requires a positive weight', () {
      final cart = CartNotifier();
      cart.addCustom(
        item: _item(measureUnit: 'kg'),
        qty: 1,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
      );
      expect(cart.state, isEmpty);
    });

    test('two weighings never merge', () {
      final cart = CartNotifier();
      for (final w in <double>[1.4, 1.4]) {
        cart.addCustom(
          item: _item(measureUnit: 'kg', price: const Money(44999)),
          qty: 1,
          mods: const <String>[],
          modsExtra: Money.zero,
          itemNote: '',
          weight: w,
        );
      }
      expect(cart.state.length, 2);
      expect(cart.total, const Money(62999 * 2));
    });
  });

  group('uid addressing', () {
    test('removeByUid removes exactly one line', () {
      final cart = CartNotifier();
      cart.addSimple(_item(id: 'a'));
      cart.addSimple(_item(id: 'b'));
      final targetUid = cart.state.first.uid;
      cart.removeByUid(targetUid);
      expect(cart.state.length, 1);
      expect(cart.state.single.item.id, 'b');
    });

    test('an unknown uid is a no-op', () {
      final cart = CartNotifier();
      cart.addSimple(_item());
      cart.setQtyByUid(-1, 99);
      expect(cart.state.single.qty, 1);
    });
  });

  test('cart total is exact across many lines', () {
    final cart = CartNotifier();
    for (var i = 0; i < 200; i++) {
      cart.addCustom(
        item: _item(id: 'itm_$i', price: const Money(3333)),
        qty: 3,
        mods: const <String>[],
        modsExtra: Money.zero,
        itemNote: '',
      );
    }
    expect(cart.total, const Money(3333 * 3 * 200));
  });
}
