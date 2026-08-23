import 'session_service.dart';

sealed class PairingUriResult {
  const PairingUriResult();
}

final class PairingUriOk extends PairingUriResult {
  final PairingInfo pairing;
  const PairingUriOk(this.pairing);
}

final class PairingUriOffNetwork extends PairingUriResult {
  final String host;
  const PairingUriOffNetwork(this.host);
}

final class PairingUriInvalid extends PairingUriResult {
  final String reason;
  const PairingUriInvalid(this.reason);
}

const String pairingScheme = 'restroapp://pair?';

const int minPairingPort = 1024;
const int maxPairingPort = 65535;

PairingUriResult parsePairingUri(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith(pairingScheme)) {
    return const PairingUriInvalid('wrong scheme');
  }

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

bool isLocalNetworkHost(String host) {
  final lower = host.toLowerCase();

  if (lower == 'localhost' || lower.endsWith('.local')) return true;

  if (lower.contains(':')) {
    if (lower == '::1') return true;

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

  if (a == 127) return true;
  if (a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 169 && b == 254) return true;
  if (a == 100 && b >= 64 && b <= 127) return true;

  return false;
}
