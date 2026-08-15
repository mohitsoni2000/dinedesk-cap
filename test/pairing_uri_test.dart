import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/pairing_uri.dart';

void main() {
  group('AUDIT #7 — a printed QR must not be able to redirect the phone', () {
    test('accepts a desk on the restaurant LAN', () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.port, 8080);
    });

    test('rejects a public host', () {
      // The attack: print this, tape it over the real sticker at the POS
      // station, collect operator PINs.
      for (final host in <String>[
        'evil.example.com',
        '8.8.8.8',
        '203.0.113.9',
        '172.32.0.1', // just outside 172.16/12
      ]) {
        // Port must be a *valid* one, or the port check short-circuits and
        // this never reaches the host rule it exists to test. 443 is below
        // minPairingPort, so it returned PairingUriInvalid for every host —
        // including a legitimate LAN address.
        expect(
          parsePairingUri('restroapp://pair?host=$host&port=8080&token=abc'),
          isA<PairingUriOffNetwork>(),
          reason: '$host must be refused',
        );
      }
    });

    test('accepts every private range the desk can legitimately occupy', () {
      for (final host in <String>[
        '10.0.0.5',
        '192.168.0.1',
        '172.16.0.1',
        '172.31.255.254',
        '169.254.1.1',
        '100.64.0.1',
        '127.0.0.1',
        'localhost',
        'desk.local',
      ]) {
        expect(isLocalNetworkHost(host), isTrue, reason: host);
      }
    });

    test('malformed input returns a result instead of throwing', () {
      // Uri.parse threw FormatException into an unhandled async gap here.
      expect(
        parsePairingUri('restroapp://pair?host=[bad&port=1'),
        isA<PairingUriResult>(),
      );
      expect(parsePairingUri('https://example.com'), isA<PairingUriInvalid>());
      expect(parsePairingUri(''), isA<PairingUriInvalid>());
    });

    test('rejects out-of-range and privileged ports', () {
      for (final port in <String>['0', '80', '1023', '70000', 'abc']) {
        expect(
          parsePairingUri(
            'restroapp://pair?host=192.168.1.5&port=$port&token=abc',
          ),
          isA<PairingUriInvalid>(),
          reason: 'port $port must be refused',
        );
      }
    });

    test('rejects a missing token', () {
      expect(
        parsePairingUri('restroapp://pair?host=192.168.1.5&port=8080'),
        isA<PairingUriInvalid>(),
      );
    });

    test('captures the desk_instance_id when the QR carries one', () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc&id=desk-abc-123',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.deskInstanceId, 'desk-abc-123');
    });

    test('leaves desk_instance_id null for a QR without one (older Desk build)', () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.deskInstanceId, isNull);
    });
  });
}
