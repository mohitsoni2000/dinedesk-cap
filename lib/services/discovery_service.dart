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

  /// The Desk's stable identity, if this beacon build sends one. Null for
  /// older Desk builds — callers fall back to their pre-existing trust level.
  final String? id;

  /// Every LAN IPv4 the Desk reported holding, if the beacon carries the
  /// field. Empty for older Desk builds.
  final List<String> ips;
  const DiscoveredDesk({
    required this.ip,
    required this.port,
    this.id,
    this.ips = const [],
  });
}

/// Listens for the desk's UDP discovery beacon — already broadcasting on the
/// LAN every 2s for an unrelated feature (replica/linked-device pairing) —
/// and returns every distinct desk heard within [timeout].
///
/// This alone does NOT prove a discovered desk is the one this phone is
/// paired with: the beacon carries no credential, and a different
/// restaurant's desk on a shared LAN broadcasts the identical `app` tag.
/// Callers MUST verify a candidate with SocketService.ping() and, when a
/// desk_instance_id is on file, check it matches [DiscoveredDesk.id] before
/// trusting it enough to switch the saved pairing to it — see
/// CREW_NETWORK_DESIGN.md §5.2/§9 for why this is `ping()` and not the
/// heavier `probe()` (a real authenticated socket per candidate).
/// CC-LAT-003: [timeout] is the ceiling for the nothing-heard case — the
/// desk broadcasts every 2s, so waiting the old flat timeout even when a
/// beacon arrives at 40ms was a flat tax on every rediscovery. The first
/// valid beacon instead opens a short [settleAfterFirst] window (to collect
/// a multi-homed desk's other addresses, which can arrive as separate
/// packets with distinct ip:port keys) and resolves at the end of it. The
/// settle timer is armed exactly once, on the first hit — re-arming it on
/// every packet would let a chatty LAN hold the scan open indefinitely.
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
        final id = decoded['id'];
        final rawIps = decoded['ips'];
        final ips = rawIps is List ? rawIps.whereType<String>().toList() : const <String>[];
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
