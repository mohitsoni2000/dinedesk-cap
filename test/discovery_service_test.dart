import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/discovery_service.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/socket_service.dart';

void main() {
  group('scanForDesks', () {
    test('picks up a beacon matching the commanddesk-main app tag', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));

      await Future<void>.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final payload = utf8.encode(json.encode(<String, dynamic>{
        'app': 'commanddesk-main',
        'name': 'Test Desk',
        'ip': '127.0.0.1',
        'port': 8081,
      }));
      sender.send(payload, InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      final found = await scanFuture;

      expect(
        found.any((d) => d.ip == '127.0.0.1' && d.port == 8081),
        isTrue,
        reason: 'expected to find the beacon we just sent, among: $found',
      );
    });

    test('ignores a beacon with a different app tag', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final payload = utf8.encode(json.encode(<String, dynamic>{
        'app': 'some-other-app',
        'ip': '127.0.0.1',
        'port': 8082,
      }));
      sender.send(payload, InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      final found = await scanFuture;
      expect(
        found.any((d) => d.port == 8082),
        isFalse,
        reason:
            'a beacon with the wrong app tag must never be surfaced, got: $found',
      );
    });

    test('ignores a malformed (non-JSON) packet instead of throwing', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      sender.send(
          utf8.encode('not json'), InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      await expectLater(scanFuture, completes);
    });

    test('parses id and ips[] when the beacon sends them', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final payload = utf8.encode(json.encode(<String, dynamic>{
        'app': 'commanddesk-main',
        'name': 'Test Desk',
        'ip': '127.0.0.1',
        'ips': ['127.0.0.1', '10.0.0.5'],
        'port': 8083,
        'id': 'desk-abc-123',
      }));
      sender.send(payload, InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      final found = await scanFuture;
      final match = found.where((d) => d.ip == '127.0.0.1' && d.port == 8083);
      expect(match, isNotEmpty,
          reason: 'expected to find the beacon we just sent, among: $found');
      expect(match.first.id, 'desk-abc-123');
      expect(match.first.ips, containsAll(<String>['127.0.0.1', '10.0.0.5']));
    });

    test('leaves id null and ips empty for a beacon without those fields',
        () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final payload = utf8.encode(json.encode(<String, dynamic>{
        'app': 'commanddesk-main',
        'ip': '127.0.0.1',
        'port': 8084,
      }));
      sender.send(payload, InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      final found = await scanFuture;
      final match = found.where((d) => d.ip == '127.0.0.1' && d.port == 8084);
      expect(match, isNotEmpty,
          reason: 'expected to find the beacon we just sent, among: $found');
      expect(match.first.id, isNull);
      expect(match.first.ips, isEmpty);
    });

    test(
        'a scan with nothing local broadcasting still returns a normal empty-or-ambient list',
        () async {
      final found =
          await scanForDesks(timeout: const Duration(milliseconds: 500));
      expect(found, isA<List<DiscoveredDesk>>());
    });
  });

  group('expandDeskEndpoints', () {
    test(
        "keeps a multi-homed desk's alternate addresses when its primary is the one already failing",
        () {
      // The exact shape of the reported bug: the desk beacons its unreachable
      // ICS/LAN interface as the primary `ip` (that is also what the QR put in
      // the pairing) while carrying the reachable Wi-Fi address in `ips[]`.
      const beacon = DiscoveredDesk(
        ip: '192.168.137.1',
        port: 8080,
        id: 'desk-1',
        ips: ['192.168.137.1', '192.168.29.5'],
      );

      final endpoints = expandDeskEndpoints(
        [beacon],
        excludeIp: '192.168.137.1',
        excludePort: 8080,
      );

      expect(
        endpoints.map((e) => e.ip),
        ['192.168.29.5'],
        reason: 'the alternate address is the only thing that can repair the '
            'link — excluding the failing primary must not discard it',
      );
      expect(endpoints.single.id, 'desk-1');
      expect(endpoints.single.port, 8080);
    });

    test(
        'drops only the exact excluded ip:port pair, not the same ip on another port',
        () {
      const beacon = DiscoveredDesk(
        ip: '192.168.29.5',
        port: 8081,
        id: 'desk-1',
        ips: ['192.168.29.5'],
      );

      final endpoints = expandDeskEndpoints(
        [beacon],
        excludeIp: '192.168.29.5',
        excludePort: 8080,
      );

      expect(endpoints.map((e) => e.ip), ['192.168.29.5']);
      expect(endpoints.single.port, 8081);
    });

    test('dedupes an address that appears as both the primary ip and in ips[]',
        () {
      const beacon = DiscoveredDesk(
        ip: '10.0.0.5',
        port: 8080,
        id: 'desk-1',
        ips: ['10.0.0.5', '192.168.1.7'],
      );

      final endpoints = expandDeskEndpoints([beacon]);

      expect(endpoints.map((e) => e.ip), ['10.0.0.5', '192.168.1.7']);
    });

    test('flattens several desks and keeps each one\'s id with its addresses',
        () {
      final endpoints = expandDeskEndpoints([
        const DiscoveredDesk(
            ip: '10.0.0.5', port: 8080, id: 'desk-a', ips: ['10.0.0.5']),
        const DiscoveredDesk(
            ip: '10.0.0.6',
            port: 8081,
            id: 'desk-b',
            ips: ['10.0.0.6', '192.168.1.9']),
      ]);

      expect(endpoints.map((e) => '${e.id}@${e.ip}:${e.port}'), [
        'desk-a@10.0.0.5:8080',
        'desk-b@10.0.0.6:8081',
        'desk-b@192.168.1.9:8081',
      ]);
    });

    test('returns an empty list when there is nothing to probe', () {
      expect(expandDeskEndpoints(const []), isEmpty);
    });
  });

  group('resolveReachablePairing — first contact can use the QR\'s hosts[]',
      () {
    const pairing = PairingInfo(
      host: '192.168.137.1',
      port: 8080,
      token: 'tok',
      deskInstanceId: 'desk-1',
      altHosts: ['192.168.29.5', '10.0.0.7'],
    );

    Future<PingResult> Function(String, int, Duration) answering(
      Map<String, String?> ids,
    ) =>
        (ip, port, timeout) async =>
            ids.containsKey(ip) ? PingOk(ids[ip]) : const PingFailed();

    test('keeps the primary when it answers', () async {
      final resolved = await resolveReachablePairing(
        pairing,
        pinger: answering({'192.168.137.1': 'desk-1', '10.0.0.7': 'desk-1'}),
      );
      expect(resolved.host, '192.168.137.1');
      expect(resolved.altHosts, ['192.168.29.5', '10.0.0.7']);
    });

    test('moves to the alternate that answers when the primary is dead',
        () async {
      final resolved = await resolveReachablePairing(
        pairing,
        pinger: answering({'10.0.0.7': 'desk-1'}),
      );
      expect(resolved.host, '10.0.0.7');
      expect(resolved.token, 'tok');
      expect(resolved.altHosts, contains('192.168.137.1'),
          reason: 'the primary is still a real interface of the same desk');
    });

    test('never adopts a different desk answering on an alternate', () async {
      final resolved = await resolveReachablePairing(
        pairing,
        pinger: answering({'10.0.0.7': 'some-other-desk'}),
      );
      expect(resolved.host, '192.168.137.1');
    });

    test('returns the pairing untouched when nothing answers', () async {
      final resolved = await resolveReachablePairing(
        pairing,
        pinger: answering(const {}),
      );
      expect(identical(resolved, pairing), isTrue);
    });

    test('does not ping at all for a pairing without alternates', () async {
      var pings = 0;
      const single =
          PairingInfo(host: '192.168.1.42', port: 8080, token: 'tok');
      final resolved = await resolveReachablePairing(
        single,
        pinger: (ip, port, timeout) async {
          pings++;
          return const PingFailed();
        },
      );
      expect(identical(resolved, single), isTrue);
      expect(pings, 0,
          reason: 'a legacy single-host pairing must behave exactly as before');
    });
  });
}
