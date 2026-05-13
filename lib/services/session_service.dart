import 'package:shared_preferences/shared_preferences.dart';

class PairingInfo {
  final String host;
  final int port;
  final String token;
  const PairingInfo({required this.host, required this.port, required this.token});
}

class SessionService {
  static const _keyHost = 'pairing_host';
  static const _keyPort = 'pairing_port';
  static const _keyToken = 'pairing_token';

  Future<void> savePairing(PairingInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, info.host);
    await prefs.setInt(_keyPort, info.port);
    await prefs.setString(_keyToken, info.token);
  }

  Future<PairingInfo?> getSavedPairing() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_keyHost);
    final port = prefs.getInt(_keyPort);
    final token = prefs.getString(_keyToken);
    if (host == null || port == null || token == null) return null;
    return PairingInfo(host: host, port: port, token: token);
  }

  Future<void> clearPairing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHost);
    await prefs.remove(_keyPort);
    await prefs.remove(_keyToken);
  }
}
