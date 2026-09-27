import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/session_service.dart';

void main() {
  group('PairingInfo.movedTo — the endpoint cache survives a repair', () {
    const pairing = PairingInfo(
      host: '192.168.137.1',
      port: 8080,
      token: 'tok',
      deviceSecret: 'sec',
      deskInstanceId: 'desk-1',
      altHosts: ['192.168.29.5', '10.0.0.7'],
    );

    test('promotes the repaired address and demotes the old one', () {
      final moved = pairing.movedTo('192.168.29.5', 8080);
      expect(moved.host, '192.168.29.5');
      expect(moved.port, 8080);
      expect(moved.altHosts, ['192.168.137.1', '10.0.0.7'],
          reason: 'the address we moved off is still a real interface of the '
              'same desk — keep it, at the front, so a later repair can find '
              'its way back (most recently abandoned is likeliest to work)');
    });

    test('carries the credentials and desk identity through unchanged', () {
      final moved = pairing.movedTo('10.0.0.7', 8081);
      expect(moved.token, 'tok');
      expect(moved.deviceSecret, 'sec');
      expect(moved.deskInstanceId, 'desk-1');
      expect(moved.port, 8081);
    });

    test('never lets the new host linger in its own alternates', () {
      final moved = pairing.movedTo('192.168.29.5', 8080);
      expect(moved.altHosts, isNot(contains('192.168.29.5')));
    });

    test('is a no-op-shaped move when the address did not actually change', () {
      final moved = pairing.movedTo('192.168.137.1', 8080);
      expect(moved.host, '192.168.137.1');
      expect(moved.altHosts, ['192.168.29.5', '10.0.0.7']);
    });

    test('keeps the alternates bounded as the desk hops around', () {
      var p = const PairingInfo(host: '10.0.0.0', port: 8080, token: 't');
      for (var i = 1; i <= 20; i++) {
        p = p.movedTo('10.0.0.$i', 8080);
      }
      expect(p.altHosts.length, lessThanOrEqualTo(maxPairingAltHosts));
      expect(p.altHosts.first, '10.0.0.19',
          reason: 'most recently abandoned address is the likeliest to work');
    });
  });
}
