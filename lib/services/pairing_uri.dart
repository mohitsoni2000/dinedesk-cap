import 'session_service.dart';

/// Parsing and validation for the pairing QR payload.
///
/// The QR is untrusted input from the physical world: printing a sticker and
/// taping it over the real one at a POS station is a two-minute attack that
/// harvests operator PINs. So the host is not merely parsed, it is
/// *constrained* — the desk is always a machine on the restaurant's own LAN,
/// so anything routable on the public internet is refused outright.
sealed class PairingUriResult {
  const PairingUriResult();
}

final class PairingUriOk extends PairingUriResult {
  final PairingInfo pairing;
  const PairingUriOk(this.pairing);
}

/// Well-formed, but pointing somewhere the desk cannot legitimately be.
final class PairingUriOffNetwork extends PairingUriResult {
  final String host;
  const PairingUriOffNetwork(this.host);
}

final class PairingUriInvalid extends PairingUriResult {
  final String reason;
  const PairingUriInvalid(this.reason);
}

const String pairingScheme = 'restroapp://pair?';

/// Ports below 1024 need root and are not where a desktop Electron app
/// listens; 65535 is the ceiling.
const int minPairingPort = 1024;
const int maxPairingPort = 65535;

PairingUriResult parsePairingUri(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith(pairingScheme)) {
    return const PairingUriInvalid('wrong scheme');
  }

  // tryParse, not parse — `Uri.parse` throws FormatException on input like
  // `restroapp://pair?host=[bad`, and the old caller was a `void ... async`
  // so it escaped to the zone as an unhandled error.
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return const PairingUriInvalid('unparseable');

  final host = uri.queryParameters['host']?.trim();
  final portText = uri.queryParameters['port']?.trim();
  final token = uri.queryParameters['token']?.trim();
  final deviceSecret = uri.queryParameters['device_secret']?.trim();
  final deskInstanceId = uri.queryParameters['id']?.trim();

  if (host == null || host.isEmpty) {
    return const PairingUriInvalid('missing host');
  }
  if (token == null || token.isEmpty) {
    return const PairingUriInvalid('missing token');
  }

  final port = portText == null ? null : int.tryParse(portText);
  if (port == null || port < minPairingPort || port > maxPairingPort) {
    return const PairingUriInvalid('bad port');
  }

  if (!isLocalNetworkHost(host)) return PairingUriOffNetwork(host);

  return PairingUriOk(
    PairingInfo(
        host: host,
        port: port,
        token: token,
        deviceSecret: (deviceSecret == null || deviceSecret.isEmpty)
            ? null
            : deviceSecret,
        deskInstanceId: (deskInstanceId == null || deskInstanceId.isEmpty)
            ? null
            : deskInstanceId),
  );
}

/// True for addresses the desk can plausibly occupy: RFC1918 / CGNAT / link
/// local / loopback IPv4, IPv6 loopback and unique-local, and `.local`
/// mDNS names.
bool isLocalNetworkHost(String host) {
  final lower = host.toLowerCase();

  if (lower == 'localhost' || lower.endsWith('.local')) return true;

  // IPv6
  if (lower.contains(':')) {
    if (lower == '::1') return true;
    // fc00::/7 — unique local addresses. fe80::/10 — link local.
    return lower.startsWith('fc') ||
        lower.startsWith('fd') ||
        lower.startsWith('fe8') ||
        lower.startsWith('fe9') ||
        lower.startsWith('fea') ||
        lower.startsWith('feb');
  }

  final octets = lower.split('.');
  if (octets.length != 4) return false;
  final parsed = <int>[];
  for (final octet in octets) {
    final value = int.tryParse(octet);
    if (value == null || value < 0 || value > 255) return false;
    parsed.add(value);
  }

  final a = parsed[0];
  final b = parsed[1];

  if (a == 127) return true; // loopback
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 169 && b == 254) return true; // link local
  if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT

  return false;
}
