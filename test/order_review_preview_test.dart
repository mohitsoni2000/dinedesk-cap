import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/screens/order_review_screen.dart';

/// Blueprint 12 finding 3: `order:preview-totals` carried a raw [Money] as
/// `total_price`. jsonEncode threw, the ack helper turned the throw into
/// `connection_lost`, and "Calculating final total…" never resolved. Amounts
/// go out as rupees, like every other payload.
void main() {
  const paneer = MenuItem(
    id: 'itm_paneer',
    name: 'Paneer Tikka',
    section: 'Starters',
    kitchenSection: 'tandoor',
    price: Money(32050),
    isVeg: true,
  );

  test('the preview items JSON-encode with rupee totals', () {
    final items = previewTotalsItems(<CartLine>[
      CartLine(item: paneer, qty: 2),
    ]);

    final wire = jsonDecode(jsonEncode(<String, dynamic>{'items': items}))
        as Map<String, dynamic>;
    final line =
        (wire['items'] as List<dynamic>).single as Map<String, dynamic>;
    expect(line['item_id'], 'itm_paneer');
    expect(line['item_type'], 'tandoor');
    expect(line['total_price'], 641.0);
  });

  test('a weighed line sends its weighed total', () {
    const rice = MenuItem(
      id: 'itm_rice',
      name: 'Basmati',
      section: 'Mains',
      kitchenSection: 'curry',
      price: Money(40000),
      isVeg: true,
      measureUnit: 'kg',
    );
    final items = previewTotalsItems(
        <CartLine>[CartLine(item: rice, qty: 1, weight: 0.25)]);
    expect(jsonDecode(jsonEncode(items)), <Object>[
      <String, dynamic>{
        'item_id': 'itm_rice',
        'item_type': 'curry',
        'total_price': 100.0,
      },
    ]);
  });
}
