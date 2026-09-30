import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/menu_area.dart';

void main() {
  group('MenuAreaContext.fromAck', () {
    test('reads hidden ids, the area and the hidden list', () {
      final ctx = MenuAreaContext.fromAck(<String, dynamic>{
        'kind': 'success',
        'enabled': true,
        'area_label': 'Rooftop',
        'can_toggle': true,
        'hidden_item_ids': ['beer', 'dal'],
        'entries': [
          {
            'id': 'b1',
            'target_type': 'category',
            'target_id': 'bar',
            'target_name': 'Bar',
            'category_name': null,
            'source': 'admin',
          },
          {
            'id': 'b2',
            'target_type': 'item',
            'target_id': 'dal',
            'target_name': 'Dal',
            'category_name': 'Food',
            'source': 'quick',
          },
          {'id': '', 'target_id': 'x'},
        ],
      });
      expect(ctx.enabled, isTrue);
      expect(ctx.areaLabel, 'Rooftop');
      expect(ctx.canToggle, isTrue);
      expect(ctx.isHidden('beer'), isTrue);
      expect(ctx.isHidden('roti'), isFalse);
      expect(ctx.entries, hasLength(2));
      expect(ctx.entries.first.isCategory, isTrue);
      expect(ctx.entries.first.isQuick, isFalse);
      expect(ctx.entries.last.isQuick, isTrue);
    });

    test('hides nothing on an error or an older desk', () {
      final err = MenuAreaContext.fromAck(<String, dynamic>{
        'kind': 'error',
        'message': 'Unknown event',
      });
      expect(err.hiddenItemIds, isEmpty);
      expect(err.canToggle, isFalse);
      expect(MenuAreaContext.fromAck(<String, dynamic>{}).enabled, isFalse);
    });
  });

  group('menuAreaWhere', () {
    test('prefers the running order', () {
      expect(menuAreaWhere(isRoom: false, slotId: 't1', orderId: 'o1'),
          {'order_id': 'o1'});
    });

    test('falls back to the table or room', () {
      expect(menuAreaWhere(isRoom: false, slotId: 't1'), {'table_id': 't1'});
      expect(menuAreaWhere(isRoom: true, slotId: 'r1', orderId: ''),
          {'room_id': 'r1'});
    });
  });
}
