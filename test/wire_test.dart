import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/models/wire.dart';

Map<String, dynamic> _order({
  Object? total = 100.0,
  Object? itemCount,
  List<Map<String, dynamic>> items = const <Map<String, dynamic>>[],
}) =>
    <String, dynamic>{
      'id': 'order_1',
      'table_id': 'tbl_1',
      'status': 'open',
      'total': total,
      if (itemCount != null) 'item_count': itemCount,
      'created_at': '2026-08-06T01:00:00Z',
      'business_date': '2026-08-05',
      'items': items,
    };

Map<String, dynamic> _item({
  Object? unitPrice = 45.0,
  Object? totalPrice = 180.0,
  int quantity = 4,
}) =>
    <String, dynamic>{
      'id': 'oi_1',
      'item_id': 'itm_1',
      'item_name': 'Butter Naan',
      'quantity': quantity,
      'unit_price': unitPrice,
      'total_price': totalPrice,
      'item_type': 'tandoor',
    };

void main() {
  group('AUDIT #2 — order total has exactly one definition', () {
    test('a genuinely zero total is preserved, not recomputed', () {
      final order = ServerOrder.fromMap(<String, dynamic>{
        ..._order(total: 0),
        'food_subtotal': 800.0,
        'liquor_subtotal': 200.0,
      });
      expect(order.total, Money.zero);
    });

    test('a missing total is a hard failure, not a guess', () {
      expect(
        () => ServerOrder.fromMap(_order(total: null)),
        throwsA(isA<WireFormatException>()),
      );
    });
  });

  group('AUDIT #9 — unit price never falls back to total price', () {
    test('a zero unit price stays zero', () {
      final item = ServerOrderItem.fromMap(
        _item(unitPrice: 0, totalPrice: 300.0, quantity: 3),
      );

      expect(item.unitPrice, Money.zero);
      expect(item.totalPrice, const Money(30000));
    });

    test('a missing unit price fails loudly', () {
      expect(
        () => ServerOrderItem.fromMap(_item(unitPrice: null)),
        throwsA(isA<WireFormatException>()),
      );
    });
  });

  group('item_count: absent vs zero', () {
    test('absent falls back to the parsed item list', () {
      final order = ServerOrder.fromMap(
        _order(items: <Map<String, dynamic>>[_item()]),
      );
      expect(order.itemCount, 1);
    });

    test('an explicit zero is respected', () {
      final order = ServerOrder.fromMap(_order(itemCount: 0));
      expect(order.itemCount, 0);
    });
  });

  group('AUDIT #18 — no silent coercion', () {
    test('an empty id is not a valid id', () {
      expect(
        () => requireString(<String, dynamic>{'id': '  '}, 'id', 'T'),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('bool parsing is case-insensitive', () {
      expect(optionalBool(<String, dynamic>{'v': 'True'}, 'v'), isTrue);
      expect(optionalBool(<String, dynamic>{'v': 'YES'}, 'v'), isTrue);
      expect(optionalBool(<String, dynamic>{'v': 'False'}, 'v'), isFalse);
      expect(optionalBool(<String, dynamic>{'v': 'maybe'}, 'v'), isNull);
    });

    test('a menu item with no is_veg flag is rejected rather than guessed', () {
      expect(
        () => ServerMenuItem.fromMap(<String, dynamic>{
          'id': 'itm_1',
          'name': 'Paneer Tikka',
          'base_price': 320,
        }),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('parseEach drops only the bad row', () {
      final parsed = parseEach(
        <Map<String, dynamic>>[
          _item(),
          _item(unitPrice: null),
          _item(),
        ],
        ServerOrderItem.fromMap,
        'ServerOrderItem',
      );
      expect(parsed.length, 2);
    });
  });

  group('AUDIT — BroadcastEnvelope', () {
    test('an empty order_id reads as null, not as an empty string', () {
      const envelope = BroadcastEnvelope(<String, dynamic>{'order_id': ''});
      expect(envelope.orderId, isNull);
    });
  });

  group('AUDIT #14 — bills', () {
    test('a bill without a total is rejected', () {
      expect(
        () => ServerBill.fromMap(<String, dynamic>{'id': 'b1'}),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('a zero-total bill is valid', () {
      final bill = ServerBill.fromMap(
        <String, dynamic>{'id': 'b1', 'total_amount': 0},
      );
      expect(bill.totalAmount, Money.zero);
    });
  });
}
