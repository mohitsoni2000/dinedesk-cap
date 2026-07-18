import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/server_models.dart';

void main() {
  test('ServerTable.fromMap parses the operators array into id/name lists', () {
    final table = ServerTable.fromMap({
      'id': 't1',
      'name': 'T1',
      'capacity': 4,
      'status': 'occupied',
      'floor_id': 'f1',
      'order_total': 0,
      'operators': [
        {'operator_id': 'op1', 'operator_name': 'Priya'},
        {'operator_id': 'op2', 'operator_name': 'Rahul'},
      ],
    });

    expect(table.operatorIds, ['op1', 'op2']);
    expect(table.operatorNames, ['Priya', 'Rahul']);
  });

  test('ServerTable.fromMap defaults to empty lists when operators is absent', () {
    final table = ServerTable.fromMap({
      'id': 't1',
      'name': 'T1',
      'capacity': 4,
      'status': 'free',
      'floor_id': 'f1',
      'order_total': 0,
    });

    expect(table.operatorIds, <String>[]);
    expect(table.operatorNames, <String>[]);
  });

  test('ServerTable.fromMap tolerates a non-list operators value without throwing', () {
    final table = ServerTable.fromMap({
      'id': 't1',
      'name': 'T1',
      'capacity': 4,
      'status': 'free',
      'floor_id': 'f1',
      'order_total': 0,
      'operators': {},
    });

    expect(table.operatorIds, <String>[]);
    expect(table.operatorNames, <String>[]);
  });

  test('ServerTable.fromMap skips malformed entries in the operators list', () {
    final table = ServerTable.fromMap({
      'id': 't1',
      'name': 'T1',
      'capacity': 4,
      'status': 'occupied',
      'floor_id': 'f1',
      'order_total': 0,
      'operators': [
        'garbage',
        {'operator_id': 'op1', 'operator_name': 'Priya'},
      ],
    });

    expect(table.operatorIds, ['op1']);
    expect(table.operatorNames, ['Priya']);
  });
}
