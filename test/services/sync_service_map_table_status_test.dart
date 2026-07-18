import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/sync_service.dart';

void main() {
  group('mapTableStatus (list-membership)', () {
    test('mine when the current operator is anywhere in the operators list',
        () {
      expect(
        mapTableStatus('occupied', 'op2', ['op1', 'op2']),
        TableState.mine,
      );
    });

    test('other when occupied and current operator is not in the list', () {
      expect(
        mapTableStatus('occupied', 'op3', ['op1', 'op2']),
        TableState.other,
      );
    });

    test('mine when occupied and the operators list is empty (unclaimed)',
        () {
      expect(
        mapTableStatus('occupied', 'op1', []),
        TableState.mine,
      );
    });

    test('dirty/reserved/free are unaffected by the operators list', () {
      expect(mapTableStatus('cleaning', 'op1', ['op2']), TableState.dirty);
      expect(mapTableStatus('reserved', 'op1', ['op2']), TableState.reserved);
      expect(mapTableStatus('free', 'op1', ['op2']), TableState.free);
    });
  });
}
