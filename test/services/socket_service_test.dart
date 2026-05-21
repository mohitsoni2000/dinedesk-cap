import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';

void main() {
  test('emit returns an error ack when the socket is disconnected', () {
    final service = SocketService();
    Map<String, dynamic>? ack;

    service.emit(
      'order:create',
      {'table_id': 'table-1'},
      onAck: (response) => ack = response,
    );

    expect(ack, isNotNull);
    expect(ack?['kind'], 'error');
  });

  test('verifyPin rejects immediately when the socket is disconnected', () {
    final service = SocketService();
    String? rejection;

    service.verifyPin(
      '1234',
      onVerified: (_) => fail('Disconnected socket should not verify a PIN'),
      onRejected: (message) => rejection = message,
    );

    expect(rejection, isNotNull);
  });
}
