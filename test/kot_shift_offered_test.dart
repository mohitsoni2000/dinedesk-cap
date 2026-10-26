import 'package:flutter_test/flutter_test.dart';
import 'package:restro/widgets/kot_history_sheet.dart';

/// Shift KOT is offered only where the desk would accept it.
void main() {
  bool offered({
    bool permitted = true,
    bool editable = true,
    bool hasRounds = true,
    bool onRoom = false,
    bool billed = false,
  }) =>
      kotShiftOffered(
        permitted: permitted,
        editable: editable,
        hasRounds: hasRounds,
        onRoom: onRoom,
        billed: billed,
      );

  test('a table order with rounds to move can shift', () {
    expect(offered(), isTrue);
  });

  test('a room order cannot: there is no table to shift from', () {
    expect(offered(onRoom: true), isFalse);
  });

  test('a billed order cannot: the desk refuses to shift a billed item', () {
    expect(offered(billed: true), isFalse);
  });

  test('the old rules still hold', () {
    expect(offered(permitted: false), isFalse);
    expect(offered(editable: false), isFalse);
    expect(offered(hasRounds: false), isFalse);
  });
}
