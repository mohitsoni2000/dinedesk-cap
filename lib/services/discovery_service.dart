import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';

const String _tag = '[Discovery]';

const int discoveryPort = 45654;

const String _appTag = 'commanddesk-main';

class DiscoveredDesk {
  final String ip;
  final int port;

  final String? id;

  final List<String> ips;
  const DiscoveredDesk({
    required this.ip,
    required this.port,
    this.id,
    this.ips = const [],
  });
}

Future<List<DiscoveredDesk>> scanForDesks({
  Duration timeout = const Duration(seconds: 3),
  Duration settleAfterFirst = const Duration(milliseconds: 250),
}) async {
  final found = <String, DiscoveredDesk>{};
  RawDatagramSocket? socket;
  final completer = Completer<void>();
  Timer? settleTimer;
  Timer? ceilingTimer;

  void finish() {
    if (!completer.isCompleted) completer.complete();
  }

  try {
    socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, discoveryPort,
        reuseAddress: true);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket?.receive();
      if (datagram == null) return;
      try {
        final decoded = json.decode(utf8.decode(datagram.data));
        if (decoded is! Map) return;
        if (decoded['app'] != _appTag) return;
        final ip = decoded['ip'];
        final port = decoded['port'];
        if (ip is! String || port is! int) return;
        final id = decoded['id'];
        final rawIps = decoded['ips'];
        final ips = rawIps is List
            ? rawIps.whereType<String>().toList()
            : const <String>[];
        final isFirstHit = found.isEmpty;
        found['$ip:$port'] = DiscoveredDesk(
          ip: ip,
          port: port,
          id: id is String ? id : null,
          ips: ips,
        );
        if (isFirstHit) {
          settleTimer = Timer(settleAfterFirst, finish);
        }
      } catch (err) {
        logD(_tag, 'ignoring malformed beacon packet: $err');
      }
    });
    ceilingTimer = Timer(timeout, finish);
    await completer.future;
  } catch (err) {
    logD(_tag, 'scan failed: $err');
  } finally {
    settleTimer?.cancel();
    ceilingTimer?.cancel();
    socket?.close();
  }
  return found.values.toList();
}
