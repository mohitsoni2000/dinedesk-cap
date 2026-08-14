import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';

const String _tag = '[Discovery]';

/// Must match DISCOVERY_PORT in command.desk's electron/linked/discovery.service.ts.
const int discoveryPort = 45654;

/// Must match APP_TAG in electron/linked/discovery.service.ts.
const String _appTag = 'commanddesk-main';

class DiscoveredDesk {
  final String ip;
  final int port;
  const DiscoveredDesk({required this.ip, required this.port});
}

/// Listens for the desk's UDP discovery beacon — already broadcasting on the
/// LAN every 2s for an unrelated feature (replica/linked-device pairing) —
/// and returns every distinct desk heard within [timeout].
///
/// This alone does NOT prove a discovered desk is the one this phone is
/// paired with: the beacon carries no credential, and a different
/// restaurant's desk on a shared LAN broadcasts the identical `app` tag.
/// Callers MUST verify a candidate with SocketService.probe() (real JWT
/// auth against this phone's saved token) before trusting it enough to
/// switch the saved pairing to it.
Future<List<DiscoveredDesk>> scanForDesks({
  Duration timeout = const Duration(seconds: 4),
}) async {
  final found = <String, DiscoveredDesk>{};
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort,
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
        found['$ip:$port'] = DiscoveredDesk(ip: ip, port: port);
      } catch (err) {
        logD(_tag, 'ignoring malformed beacon packet: $err');
      }
    });
    await Future.delayed(timeout);
  } catch (err) {
    logD(_tag, 'scan failed: $err');
  } finally {
    socket?.close();
  }
  return found.values.toList();
}
