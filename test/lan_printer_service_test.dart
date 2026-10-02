import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/kot_print_config.dart';
import 'package:restro/services/escpos_builder.dart';
import 'package:restro/services/lan_printer_service.dart';

/// Against a real local ServerSocket: what the printer would receive.
void main() {
  late ServerSocket server;
  late List<List<int>> received;
  late Completer<void> firstClosed;

  setUp(() async {
    received = <List<int>>[];
    firstClosed = Completer<void>();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) {
      final chunks = <int>[];
      client.listen(chunks.addAll, onDone: () {
        received.add(chunks);
        if (!firstClosed.isCompleted) firstClosed.complete();
        client.destroy();
      });
    });
  });

  tearDown(() async => server.close());

  const doc = EscposDoc(
    title: 'KITCHEN',
    subtitleLines: <String>['KOT: A7Q2-001'],
    itemLines: <String>['1 x Tea'],
  );

  KotPrintDestination dest({int copies = 1}) =>
      KotPrintDestination(host: '127.0.0.1', port: server.port, copies: copies);

  test('the printer receives exactly the desk\'s ESC/POS bytes', () async {
    final result = await LanPrinterService().printDoc(dest(), doc);
    await firstClosed.future.timeout(const Duration(seconds: 3));

    expect(result.ok, isTrue);
    expect(received.length, 1);
    expect(received.single, escposBytes(doc));
    expect(received.single.take(2), [0x1B, 0x40], reason: 'starts with ESC @');
    expect(received.single.takeLast(4), [0x1D, 0x56, 0x42, 0x00],
        reason: 'ends with the partial cut');
  });

  test('honours copies: that many whole tickets in one job', () async {
    final result = await LanPrinterService().printDoc(dest(copies: 3), doc);
    await firstClosed.future.timeout(const Duration(seconds: 3));

    expect(result.ok, isTrue);
    expect(received.single, escposBytes(doc, copies: 3));
    expect(received.single.length, escposBytes(doc).length * 3);
  });

  test('jobs to one destination run one at a time, in order', () async {
    final service = LanPrinterService();
    final first = service.sendBytes('127.0.0.1', server.port, [1, 2, 3]);
    final second = service.sendBytes('127.0.0.1', server.port, [4, 5, 6]);
    final results = await Future.wait([first, second]);
    // Both closed connections are in `received` once the server saw both ends.
    for (var i = 0; i < 50 && received.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(results.every((r) => r.ok), isTrue);
    expect(received, [
      [1, 2, 3],
      [4, 5, 6],
    ]);
  });

  test('a dead port is a prompt failure, not an exception', () async {
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();

    final sw = Stopwatch()..start();
    final result =
        await LanPrinterService().sendBytes('127.0.0.1', port, [1, 2, 3]);
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('a connect that never completes times out at the connect budget',
      () async {
    final service = LanPrinterService(
      connectTimeout: const Duration(milliseconds: 150),
      connector: (host, port, {timeout}) => Completer<Socket>().future,
    );
    final sw = Stopwatch()..start();
    final result = await service.sendBytes('10.255.255.1', 9100, [1]);
    expect(result.ok, isFalse);
    expect(result.error, contains('timed out'));
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('a failed job does not block the next one for that destination',
      () async {
    var calls = 0;
    final service = LanPrinterService(
      connectTimeout: const Duration(milliseconds: 100),
      connector: (host, port, {timeout}) {
        calls++;
        if (calls == 1) return Completer<Socket>().future; // hangs -> timeout
        return Socket.connect('127.0.0.1', server.port);
      },
    );
    final a = service.sendBytes('h', 1, [1]);
    final b = service.sendBytes('h', 1, [2]);
    final results = await Future.wait([a, b]);
    expect(results[0].ok, isFalse);
    expect(results[1].ok, isTrue);
  });
}

extension on List<int> {
  List<int> takeLast(int n) => sublist(length - n);
}
