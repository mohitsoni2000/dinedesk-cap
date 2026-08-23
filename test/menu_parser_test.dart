import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/services/menu_parser.dart';

void main() {
  group('parseMenu', () {
    final payload = <String, dynamic>{
      'categories': [
        {'id': 'c2', 'name': 'Mains', 'type': 'food', 'sort_order': 2},
        {'id': 'c1', 'name': 'Starters', 'type': 'food', 'sort_order': 1},
      ],
      'items': [
        {
          'id': 'i1',
          'name': 'Paneer Tikka',
          'category_id': 'c1',
          'price': 250,
          'is_veg': 1,
          'sort_order': 5,
        },
        {
          'id': 'i2',
          'name': 'Butter Chicken',
          'category_id': 'c2',
          'price': 0,
          'is_veg': 0,
        },
      ],
      'item_option_groups': [
        {
          'id': 'g1',
          'item_id': 'i1',
          'name': 'Spice level',
          'is_required': 1,
          'min_select': 1,
          'max_select': 1,
        },
      ],
      'item_options': [
        {'id': 'o1', 'group_id': 'g1', 'name': 'Mild', 'price_modifier': 0},
        {'id': 'o2', 'group_id': 'g1', 'name': 'Hot', 'price_modifier': 10},
      ],
      'item_variations': [
        {'id': 'v1', 'item_id': 'i2', 'name': 'Half', 'price': 320},
        {'id': 'v2', 'item_id': 'i2', 'name': 'Full', 'price': 480},
      ],
      'addon_groups': [
        {'id': 'a1', 'name': 'Extras', 'selection_type': 'M'},
      ],
      'item_addon_groups': [
        {'id': 'l1', 'item_id': 'i1', 'group_id': 'a1', 'max_select': 3},
      ],
      'addon_group_choices': [
        {'id': 'ch1', 'group_id': 'a1', 'name': 'Extra cheese', 'price': 40},
      ],
    };

    test('maps items onto their category name and type', () {
      final result = parseMenu(payload);
      final byId = {for (final i in result.items) i.id: i};

      expect(result.items, hasLength(2));
      expect(byId['i1']!.section, 'Starters');
      expect(byId['i1']!.kitchenSection, 'food');
      expect(byId['i2']!.section, 'Mains');
    });

    test('returns categories in the admin-configured sort order', () {
      final result = parseMenu(payload);
      expect(result.categories.map((c) => c.name), ['Starters', 'Mains']);
    });

    test('attaches option groups with their options', () {
      final item = parseMenu(payload).items.firstWhere((i) => i.id == 'i1');

      expect(item.optionGroups, hasLength(1));
      final group = item.optionGroups.single;
      expect(group.name, 'Spice level');
      expect(group.isRequired, isTrue);
      expect(group.options.map((o) => o.name), ['Mild', 'Hot']);
    });

    test('attaches addon groups with their choices and link limits', () {
      final item = parseMenu(payload).items.firstWhere((i) => i.id == 'i1');

      expect(item.addonGroups, hasLength(1));
      final group = item.addonGroups.single;
      expect(group.name, 'Extras');
      expect(group.selectionType, 'M');
      expect(group.maxSelect, 3);
      expect(group.choices.single.name, 'Extra cheese');
      expect(group.choices.single.price, const Money.rupees(40));
    });

    test('falls back to the cheapest variation when base price is zero', () {
      final item = parseMenu(payload).items.firstWhere((i) => i.id == 'i2');

      expect(item.variations.map((v) => v.name), ['Half', 'Full']);
      expect(item.price, const Money.rupees(320));
    });

    test('keeps an explicit base price over the variations', () {
      final item = parseMenu(payload).items.firstWhere((i) => i.id == 'i1');
      expect(item.price, const Money.rupees(250));
    });

    test('supports the older shape with items nested under categories', () {
      final nested = <String, dynamic>{
        'categories': [
          {
            'id': 'c1',
            'name': 'Breads',
            'type': 'food',
            'sort_order': 1,
            'items': [
              {'id': 'i9', 'name': 'Naan', 'price': 60, 'is_veg': 1},
            ],
          },
        ],
      };

      final result = parseMenu(nested);
      expect(result.items, hasLength(1));
      expect(result.items.single.name, 'Naan');
      expect(result.items.single.section, 'Breads');
    });

    test('returns nothing for an empty payload rather than throwing', () {
      final result = parseMenu(<String, dynamic>{});
      expect(result.items, isEmpty);
      expect(result.categories, isEmpty);
    });
  });
}
