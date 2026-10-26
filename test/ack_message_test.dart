import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/utils/ack_message.dart';

/// What the waiter reads when a desk request fails: the desk's own reason for
/// a refusal, and for no answer, that it may still have gone through.
void main() {
  test('a refusal shows the desk\'s own words', () {
    expect(
        ackFailureText(<String, dynamic>{
          'kind': 'error',
          'message': 'This table was cleared since you opened it',
          'code': 'slot_changed',
        }, fallback: 'Could not save order — please retry'),
        'This table was cleared since you opened it');
  });

  test('a refusal without words falls back to the screen\'s own text', () {
    expect(
        ackFailureText(<String, dynamic>{'kind': 'error'},
            fallback: 'Could not save order — please retry'),
        'Could not save order — please retry');
  });

  test('no answer says so instead of claiming a refusal', () {
    final ack = <String, dynamic>{
      'kind': 'error',
      'code': AckCode.timeout,
      'message': 'ack timed out',
    };
    expect(
        ackFailureText(ack,
            fallback: 'Payment failed',
            noAnswer: 'No answer from the desk — check the bill'),
        'No answer from the desk — check the bill');
    expect(ackFailureText(ack, fallback: 'Payment failed'), 'Payment failed',
        reason: 'a timeout\'s own text is not for staff');
  });
}
