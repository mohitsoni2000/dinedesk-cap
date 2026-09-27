import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';
import 'session_service.dart';
import 'socket_service.dart';

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

/// One concrete address to probe, flattened out of a [DiscoveredDesk].
class DeskEndpoint {
  final String ip;
  final int port;
  final String? id;
  const DeskEndpoint({required this.ip, required this.port, this.id});

  @override
  String toString() => '$ip:$port${id == null ? '' : ' ($id)'}';
}

/// Every address worth probing across [candidates] — each desk's primary
/// `ip` followed by its `ips[]` alternates, deduped, in beacon order.
///
/// [excludeIp]/[excludePort] drop the one endpoint the caller is already
/// failing on, so a rediscovery pass doesn't re-probe the dead address.
///
/// That exclusion is deliberately per-*address*, never per-desk. A
/// multi-homed desk beacons one interface as the primary `ip` and carries
/// the rest in `ips[]`, and the primary is exactly the address the QR
/// handed the phone — so dropping the whole record because its primary
/// matched would throw away the alternates, which are the only addresses
/// that can actually repair the link. That is the multi-homed case `ips[]`
/// exists for, and it was the one case where discovery silently gave up.
List<DeskEndpoint> expandDeskEndpoints(
  List<DiscoveredDesk> candidates, {
  String? excludeIp,
  int? excludePort,
}) {
  final endpoints = <DeskEndpoint>[];
  final seen = <String>{};
  for (final candidate in candidates) {
    for (final address in <String>[candidate.ip, ...candidate.ips]) {
      if (address.isEmpty) continue;
      if (address == excludeIp && candidate.port == excludePort) continue;
      if (!seen.add('$address:${candidate.port}')) continue;
      endpoints.add(DeskEndpoint(
        ip: address,
        port: candidate.port,
        id: candidate.id,
      ));
    }
  }
  return endpoints;
}

/// Pings [targets] over the desk's unauthenticated HTTP `/ping` and completes
/// with the first one that answers as the expected desk, or null if none does.
///
/// [expectedId] is the pairing's `deskInstanceId`: a desk that answers with a
/// different id is a *different* desk on the same LAN (a second POS, a demo
/// install) and must never be adopted — re-pointing a pairing at it would hand
/// this phone's token to a desk that never issued it. Null accepts any desk,
/// which only happens for a pairing minted before desk ids existed.
///
/// Targets on [priorityHost]'s /24 are pinged first and the rest ~300ms later:
/// the address a pairing already knows is the likeliest to work, and letting a
/// slower interface of the same desk win the race would pointlessly move the
/// pairing off a perfectly good address.
///
/// [pinger] exists for tests; production always uses [SocketService.ping].
Future<DeskEndpoint?> firstVerifiedEndpoint(
  List<DeskEndpoint> targets,
  String? expectedId, {
  String? priorityHost,
  Duration pingTimeout = const Duration(milliseconds: 1500),
  Future<PingResult> Function(String ip, int port, Duration timeout)? pinger,
}) {
  if (targets.isEmpty) return Future.value(null);
  final ping = pinger ??
      (String ip, int port, Duration timeout) =>
          SocketService.ping(ip, port, timeout: timeout);
  final completer = Completer<DeskEndpoint?>();
  var remaining = targets.length;

  void pingTarget(DeskEndpoint target) {
    ping(target.ip, target.port, pingTimeout).then((result) {
      if (completer.isCompleted) return;
      final matches = switch (result) {
        PingOk(id: final id) => expectedId == null || id == expectedId,
        PingFailed() => false,
      };
      if (matches) {
        completer.complete(target);
      } else if (--remaining == 0) {
        completer.complete(null);
      }
    });
  }

  final priority = <DeskEndpoint>[];
  final rest = <DeskEndpoint>[];
  for (final target in targets) {
    (priorityHost != null && sameSubnet24(target.ip, priorityHost)
            ? priority
            : rest)
        .add(target);
  }
  for (final target in priority) {
    pingTarget(target);
  }
  if (rest.isEmpty) return completer.future;
  if (priority.isEmpty) {
    for (final target in rest) {
      pingTarget(target);
    }
  } else {
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (completer.isCompleted) return;
      for (final target in rest) {
        pingTarget(target);
      }
    });
  }
  return completer.future;
}

/// True when two dotted-quad IPv4 addresses share their first three octets.
bool sameSubnet24(String a, String b) {
  final partsA = a.split('.');
  final partsB = b.split('.');
  if (partsA.length != 4 || partsB.length != 4) return false;
  return partsA[0] == partsB[0] &&
      partsA[1] == partsB[1] &&
      partsA[2] == partsB[2];
}

/// Every address a pairing already knows for its desk — [PairingInfo.host]
/// first, then [PairingInfo.altHosts] — as probe targets.
List<DeskEndpoint> knownPairingEndpoints(PairingInfo pairing) =>
    expandDeskEndpoints(<DiscoveredDesk>[
      DiscoveredDesk(
        ip: pairing.host,
        port: pairing.port,
        id: pairing.deskInstanceId,
        ips: pairing.altHosts,
      ),
    ]);

/// [pairing], moved to whichever of its known addresses the desk actually
/// answers on right now — or [pairing] unchanged when it has no alternates,
/// when the primary answers, or when nothing answers at all (so the caller's
/// own error path reports the failure exactly as it did before `hosts`).
///
/// This is what lets a *first* contact use the QR's `hosts` fan-out. A desk on
/// both Ethernet and Wi-Fi puts one address in `host`, and a phone on the other
/// network used to fail the QR scan (or a recovery login) outright with
/// "can't reach the desk", even though the very same QR listed an address it
/// could reach. Repair already probed alternates; first contact never did.
///
/// Uses the unauthenticated `/ping` rather than a token probe on purpose: a
/// token-bearing socket to every address in parallel would be several
/// sockets presenting the same credentials at once, which the desk treats as
/// one device logging in over itself.
Future<PairingInfo> resolveReachablePairing(
  PairingInfo pairing, {
  Future<PingResult> Function(String ip, int port, Duration timeout)? pinger,
}) async {
  if (pairing.altHosts.isEmpty) return pairing;
  final reachable = await firstVerifiedEndpoint(
    knownPairingEndpoints(pairing),
    pairing.deskInstanceId,
    priorityHost: pairing.host,
    pinger: pinger,
  );
  if (reachable == null || reachable.ip == pairing.host) return pairing;
  logD(_tag,
      '${pairing.host} unreachable — desk answered on alternate ${reachable.ip}');
  return pairing.movedTo(reachable.ip, reachable.port);
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
