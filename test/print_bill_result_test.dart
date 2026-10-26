import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/utils/print_bill_result.dart';

/// What the waiter is told after tapping Print Bill: the desk's answer, not a
/// "queued" the desk never gave.
void main() {
  Map<String, dynamic> ok() => <String, dynamic>{'kind': 'success'};
  Map<String, dynamic> refused(String message) =>
      <String, dynamic>{'kind': 'error', 'message': message};

  test('every bill accepted is reported as queued', () {
    final r = summarizePrintBillAcks([ok(), ok()]);

    expect(r.queued, 2);
    expect(r.refusal, isNull);
  });

  test('a refusal carries the desk\'s own words and queues nothing for it', () {
    final r = summarizePrintBillAcks(
        [ok(), refused('This action is disabled for your account')]);

    expect(r.queued, 1);
    expect(r.refusal, 'This action is disabled for your account');
  });

  test('a refusal without a message still says the print was refused', () {
    final r = summarizePrintBillAcks([
      <String, dynamic>{'kind': 'error'}
    ]);

    expect(r.queued, 0);
    expect(r.refusal, 'The desk refused to print this bill');
  });

  test('a duplicate the desk dropped is not an error', () {
    final r = summarizePrintBillAcks([
      <String, dynamic>{'kind': 'success', 'duplicate': true}
    ]);

    expect(r.refusal, isNull);
  });

  test('no answer is reported as an unconfirmed print, not as gibberish', () {
    final r = summarizePrintBillAcks([
      <String, dynamic>{
        'kind': 'error',
        'code': AckCode.timeout,
        'message': 'ack timed out',
      }
    ]);

    expect(r.queued, 0);
    expect(r.refusal,
        'The desk did not confirm the bill print — check the printer');
  });

  group('requestBillPrints', () {
    late SocketService socket;
    final asked = <String>[];
    late Map<String, dynamic> Function(String billId) desk;

    setUp(() {
      asked.clear();
      socket = SocketService()..debugSetState(SocketState.verified);
      socket.rawEmitOverride = (event, data, timeout) async {
        final id = data['bill_id'] as String;
        asked.add(id);
        return desk(id);
      };
    });
    tearDown(() => socket.dispose());

    test('every bill is asked for; all printed says nothing', () async {
      desk = (_) => <String, dynamic>{'kind': 'success', 'queued': true};
      final problems = <String>[];

      requestBillPrints(socket, ['b1', 'b2'], problems.add);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(asked, ['b1', 'b2']);
      expect(problems, isEmpty);
    });

    test('a refused bill is reported once, in the desk\'s words', () async {
      desk = (id) => id == 'b2'
          ? <String, dynamic>{
              'kind': 'error',
              'message': 'This action is disabled for your account',
            }
          : <String, dynamic>{'kind': 'success'};
      final problems = <String>[];

      requestBillPrints(socket, ['b1', 'b2'], problems.add);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(problems, ['This action is disabled for your account']);
    });
  });
}
