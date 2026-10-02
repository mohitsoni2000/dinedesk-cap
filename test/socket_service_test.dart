import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';

void main() {
  group('isAuthHandshakeError — structured code first, substring as fallback',
      () {
    const authCodes = <String>[
      'MISSING_TOKEN',
      'TOKEN_EXPIRED',
      'TOKEN_INVALID',
      'TOKEN_REVOKED',
      'OPERATOR_DEACTIVATED',
    ];

    test('recognizes every auth code at the top level', () {
      for (final code in authCodes) {
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

    test('reads the code where socket.io really puts it: err.data.code', () {
      // A middleware next(err) arrives as {message, data: {code, message}}.
      for (final code in authCodes) {
        final err = <String, dynamic>{
          'message': 'whatever words the desk used',
          'data': <String, dynamic>{'code': code, 'message': 'nested'},
        };
        expect(SocketService.handshakeErrorCode(err), code);
        expect(SocketService.isAuthHandshakeError(err), isTrue);
      }
    });

    test('VERIFICATION_UNAVAILABLE is a transient desk error, not auth', () {
      final err = <String, dynamic>{
        'message': 'Token verification unavailable',
        'data': <String, dynamic>{
          'code': 'VERIFICATION_UNAVAILABLE',
          'message': 'Token verification unavailable',
        },
      };
      expect(SocketService.handshakeErrorCode(err), 'VERIFICATION_UNAVAILABLE');
      // Even though the message contains the word "token": a code decides.
      expect(SocketService.isAuthHandshakeError(err), isFalse);
      expect(
        SocketService.isAuthHandshakeError(<String, dynamic>{
          'code': 'VERIFICATION_UNAVAILABLE',
        }),
        isFalse,
      );
    });

    test('a present-but-unknown code is decided by the set alone', () {
      expect(
        SocketService.isAuthHandshakeError(<String, dynamic>{
          'message': 'Unauthorized token revoked',
          'data': <String, dynamic>{'code': 'SOME_FUTURE_CODE'},
        }),
        isFalse,
      );
    });

    test('handshakeErrorMessage prefers the nested message', () {
      expect(
        SocketService.handshakeErrorMessage(<String, dynamic>{
          'message': 'outer',
          'data': <String, dynamic>{'code': 'X', 'message': 'inner'},
        }),
        'inner',
      );
      expect(SocketService.handshakeErrorMessage(<String, dynamic>{'message': 'outer'}),
          'outer');
      expect(SocketService.handshakeErrorMessage('plain string'), isNull);
    });

    test(
        'falls back to a narrowed substring match when there is no code (older desk)',
        () {
      for (final text in <String>[
        'Token expired or invalid',
        'Operator deactivated',
        'Unauthorized',
        'Token revoked',
      ]) {
        expect(SocketService.isAuthHandshakeError(Exception(text)), isTrue,
            reason: text);
      }
    });

    test('the old over-broad substrings no longer count as auth', () {
      // "auth" and "expired" alone used to be enough; a transport hiccup that
      // mentions either must not stop the reconnect loop.
      expect(SocketService.isAuthHandshakeError(Exception('authority lookup failed')),
          isFalse);
      expect(SocketService.isAuthHandshakeError(Exception('connection expired')),
          isFalse);
    });

    test('does not classify a generic transport failure as an auth error', () {
      expect(SocketService.isAuthHandshakeError(Exception('xhr poll error')),
          isFalse);
      expect(SocketService.isAuthHandshakeError(Exception('websocket error')),
          isFalse);
      expect(SocketService.isAuthHandshakeError('timeout'), isFalse);
    });
  });

  group('buildHandshakeAuth — the contract', () {
    tearDown(() => SocketService.debugAppVersion = null);

    test('carries token, app_version and the recovery capability', () {
      SocketService.debugAppVersion = '1.2.3';
      expect(SocketService.buildHandshakeAuth('tok'), <String, dynamic>{
        'token': 'tok',
        'app_version': '1.2.3',
        'caps': <String>['recovery-offset-v1'],
      });
    });

    test('omits app_version when it could not be read', () {
      SocketService.debugAppVersion = null;
      expect(SocketService.buildHandshakeAuth('tok').containsKey('app_version'),
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

    test('strips an offset-like last element from a longer list', () {
      final payload = <String, dynamic>{'k': 1};
      expect(
        SocketService.stripRecoveryOffset(<dynamic>[payload, 'mid', 'AbCdEf12']),
        equals(<dynamic>[payload, 'mid']),
      );
      // A single remaining element is unwrapped.
      expect(
        SocketService.stripRecoveryOffset(<dynamic>[7, 'AbCdEf12']),
        7,
      );
    });

    test('a bare offset-like string (event without a payload) becomes {}', () {
      expect(SocketService.stripRecoveryOffset('AbCdEf12_-'),
          equals(<String, dynamic>{}));
    });

    test('leaves short strings, non-offset strings and other shapes alone', () {
      expect(SocketService.stripRecoveryOffset('abc'), 'abc');
      expect(SocketService.stripRecoveryOffset('has spaces here'),
          'has spaces here');
      expect(SocketService.stripRecoveryOffset(null), isNull);
      expect(SocketService.stripRecoveryOffset(42), 42);
      final longerNoOffset = <dynamic>[
        <String, dynamic>{'k': 1},
        'mid',
        'no',
      ];
      expect(SocketService.stripRecoveryOffset(longerNoOffset),
          equals(longerNoOffset));
      final oneElement = <dynamic>['AbCdEf12'];
      expect(SocketService.stripRecoveryOffset(oneElement), equals(oneElement));
    });
  });

  group('buildVerifyPayload — operator:verify carries the cached menu version',
      () {
    test('sends only the PIN when no menu is cached (cold start)', () {
      expect(SocketService.buildVerifyPayload('1234'), {'pin': '1234'});
    });

    test('adds menu_version when a menu is cached', () {
      expect(
        SocketService.buildVerifyPayload('1234', menuVersion: 'mv-42'),
        {'pin': '1234', 'menu_version': 'mv-42'},
      );
    });

    test('treats an empty version as no version', () {
      expect(SocketService.buildVerifyPayload('1234', menuVersion: ''),
          {'pin': '1234'});
    });
  });

  group('operatorTransports — native socket_io_client is websocket-only', () {
    test('never leads with polling', () {
      // On dart:io, socket_io_client builds a WebSocket whatever the name, but
      // sends the name as `transport=` in the handshake — a leading 'polling'
      // would be a websocket claiming to be polling, which the Desk rejects.
      expect(SocketService.operatorTransports.first, 'websocket');
      expect(SocketService.operatorTransports, isNot(contains('polling')));
    });
  });
}
