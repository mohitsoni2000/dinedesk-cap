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

  group('stripRecoveryOffset — connectionStateRecovery changes broadcast shape',
      () {
    test('unwraps the [payload, offset] pair socket.io sends with recovery on',
        () {
      final payload = <String, dynamic>{'order_id': 'o1', 'status': 'sent'};
      expect(
        SocketService.stripRecoveryOffset(<dynamic>[payload, 'AAAAAQ==']),
        same(payload),
      );
    });

    test('passes an ordinary single-payload broadcast straight through', () {
      final payload = <String, dynamic>{'order_id': 'o1'};
      expect(SocketService.stripRecoveryOffset(payload), same(payload));
    });

    test('leaves a two-element list alone unless it looks like Map + offset',
        () {
      // Guards the heuristic against over-matching: neither of these is a
      // recovery-wrapped payload and neither may be silently truncated.
      expect(
        SocketService.stripRecoveryOffset(<dynamic>['a', 'b']),
        equals(<dynamic>['a', 'b']),
      );
      expect(
        SocketService.stripRecoveryOffset(<dynamic>[
          <String, dynamic>{'k': 1},
          <String, dynamic>{'k': 2},
        ]),
        isA<List<dynamic>>().having((l) => l.length, 'length', 2),
      );
    });

    test('leaves a list of the wrong length alone', () {
      final three = <dynamic>[
        <String, dynamic>{'k': 1},
        'mid',
        'offset',
      ];
      expect(SocketService.stripRecoveryOffset(three), equals(three));
    });
  });
}
