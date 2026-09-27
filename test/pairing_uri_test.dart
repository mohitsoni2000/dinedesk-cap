import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/pairing_uri.dart';
import 'package:restro/services/session_service.dart';

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
      for (final host in <String>[
        'evil.example.com',
        '8.8.8.8',
        '203.0.113.9',
        '172.32.0.1',
      ]) {
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

    test('leaves desk_instance_id null for a QR without one (older Desk build)',
        () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.deskInstanceId, isNull);
    });
  });

  group(
      'hosts[] — a multi-homed desk offers every address it can be reached on',
      () {
    test('captures the alternates and drops the primary duplicate', () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.137.1&port=8080&token=abc'
        '&hosts=192.168.137.1,192.168.29.5,10.0.0.7',
      );
      expect(result, isA<PairingUriOk>());
      final pairing = (result as PairingUriOk).pairing;
      expect(pairing.host, '192.168.137.1');
      expect(pairing.altHosts, ['192.168.29.5', '10.0.0.7']);
    });

    test('leaves altHosts empty for a QR without hosts (older Desk build)', () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.altHosts, isEmpty);
    });

    test('silently drops a public address smuggled into hosts, keeps the rest',
        () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc'
        '&hosts=192.168.1.42,8.8.8.8,evil.example.com,10.0.0.7',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.altHosts, ['10.0.0.7'],
          reason: 'hosts[] must be held to the same LAN-only rule as host');
    });

    test('tolerates blanks, whitespace and repeats', () {
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc'
        '&hosts=,%2010.0.0.7%20,,10.0.0.7,192.168.1.9,',
      );
      expect(result, isA<PairingUriOk>());
      expect((result as PairingUriOk).pairing.altHosts,
          ['10.0.0.7', '192.168.1.9']);
    });

    test('caps the list so a hostile QR cannot fan the phone out forever', () {
      final many = List.generate(40, (i) => '10.0.0.$i').join(',');
      final result = parsePairingUri(
        'restroapp://pair?host=192.168.1.42&port=8080&token=abc&hosts=$many',
      );
      expect(result, isA<PairingUriOk>());
      expect(
          (result as PairingUriOk).pairing.altHosts.length, maxPairingAltHosts);
    });
  });
}
