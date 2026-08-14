// test/discovery_service_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/discovery_service.dart';

void main() {
  group('scanForDesks', () {
    test('picks up a beacon matching the commanddesk-main app tag', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      // Give the listener a moment to bind before a packet is sent.
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
      // Assert our own packet was picked up — do NOT assert exact list
      // length or emptiness anywhere in this file. A real Desk instance can
      // genuinely be broadcasting on whatever LAN this test happens to run
      // on (observed directly on this dev machine), so the only thing a
      // test can safely assert is "our packet, specifically, was (or
      // wasn't) surfaced" — never "nothing else showed up."
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
        reason: 'a beacon with the wrong app tag must never be surfaced, got: $found',
      );
    });

    test('ignores a malformed (non-JSON) packet instead of throwing', () async {
      final scanFuture = scanForDesks(timeout: const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 150));

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // No well-formed JSON here, so there's no candidate port to check for
      // absence — the real assertion is just that scanForDesks() doesn't
      // throw/crash on a garbage packet and still completes normally.
      sender.send(utf8.encode('not json'), InternetAddress('127.0.0.1'), discoveryPort);
      sender.close();

      await expectLater(scanFuture, completes);
    });

    test('a scan with nothing local broadcasting still returns a normal empty-or-ambient list', () async {
      // Not asserting emptiness — see the note in the first test. The only
      // thing this test can safely assert on a real, possibly-noisy network
      // is that scanForDesks() completes and returns a well-typed List
      // without throwing, whether or not something real is on the LAN.
      final found = await scanForDesks(timeout: const Duration(milliseconds: 500));
      expect(found, isA<List<DiscoveredDesk>>());
    });
  });
}
