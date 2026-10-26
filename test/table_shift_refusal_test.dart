import 'package:flutter_test/flutter_test.dart';
import 'package:restro/widgets/table_shift_sheet.dart';

/// The desk will not shift a table while items sit unsent: they would stay
/// behind on the vacated table and start a new order there.
void main() {
  test('nothing unsent: the shift may go ahead', () {
    expect(tableShiftRefusal(unsentItems: 0), isNull);
  });

  test('unsent items: send or remove them first', () {
    expect(tableShiftRefusal(unsentItems: 2),
        'Send or remove the 2 new items before shifting the table');
    expect(tableShiftRefusal(unsentItems: 1),
        'Send or remove the new item before shifting the table');
  });
}
