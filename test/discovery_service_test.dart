import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/discovery_service.dart';

void main() {
  group('scanForDesks', () {
    test('picks up a beacon matching the commanddesk-main app tag', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));

      await Future.delayed(const Duration(milliseconds: 150));

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
      await Future.delayed(const Duration(milliseconds: 150));

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
      await Future.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      sender.send(
          utf8.encode('not json'), InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      await expectLater(scanFuture, completes);
    });

    test('parses id and ips[] when the beacon sends them', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 150));

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
      await Future.delayed(const Duration(milliseconds: 150));

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
}
