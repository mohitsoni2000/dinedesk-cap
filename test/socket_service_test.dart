import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';

void main() {
  group('isAuthHandshakeError — structured code first, substring as fallback',
      () {
    test('recognizes every structured code the desk can send', () {
      for (final code in <String>[
        'MISSING_TOKEN',
        'TOKEN_EXPIRED',
        'TOKEN_INVALID',
        'TOKEN_REVOKED',
        'OPERATOR_DEACTIVATED',
        'VERIFICATION_UNAVAILABLE',
      ]) {
        expect(
          SocketService.isAuthHandshakeError(<String, dynamic>{
            'code': code,
            'message': 'irrelevant for this check',
          }),
          isTrue,
          reason: '$code must be classified as an auth handshake error',
        );
      }
    });

    test('does not misclassify an unrecognized structured code', () {
      expect(
        SocketService.isAuthHandshakeError(<String, dynamic>{
          'code': 'SOME_FUTURE_CODE',
          'message': 'server had a burp',
        }),
        isFalse,
      );
    });

    test(
        'falls back to substring matching for a bare-string error (older desk build)',
        () {
      expect(
        SocketService.isAuthHandshakeError(
            Exception('Token expired or invalid')),
        isTrue,
      );
      expect(
        SocketService.isAuthHandshakeError(Exception('Operator deactivated')),
        isTrue,
      );
    });

    test('does not classify a generic transport failure as an auth error', () {
      expect(SocketService.isAuthHandshakeError(Exception('xhr poll error')),
          isFalse);
      expect(SocketService.isAuthHandshakeError(Exception('websocket error')),
          isFalse);
    });
  });
}
