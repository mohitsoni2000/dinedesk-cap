import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'log.dart';

enum SocketState { disconnected, connecting, connected, verified }

enum ProbeResult { ok, authRejected, unreachable }

/// Result of an unauthenticated `GET /ping` probe — cheap enough to fan out
/// to every rediscovery candidate without the auth-socket cost `probe()`
/// pays (see CREW_NETWORK_DESIGN.md §5.2/§9).
sealed class PingResult {
  const PingResult();
}

final class PingOk extends PingResult {
  /// The Desk's stable identity, if this Desk build sends one.
  final String? id;
  const PingOk(this.id);
}

final class PingFailed extends PingResult {
  const PingFailed();
}

/// Result of a device-secret recovery attempt (employee ID + PIN login,
/// no QR). A one-shot, disposable connection — same shape as [probe] — since
/// the credentials it carries are only good for this single handshake; the
/// real ongoing connection is a normal [SocketService.connect] using the
/// fresh token this returns.
sealed class RecoveryResult {
  const RecoveryResult();
}

final class RecoverySuccess extends RecoveryResult {
  final String token;
  final String deviceSecret;
  const RecoverySuccess(this.token, this.deviceSecret);
}

final class RecoveryFailed extends RecoveryResult {
  /// 'RECOVERY_DISABLED' or 'RECOVERY_FAILED' from the desk, null for a
  /// network-level failure (unreachable, timeout, malformed response).
  final String? code;
  final String message;
  const RecoveryFailed(this.code, this.message);
}

/// Why the last live connect attempt failed, when it failed during the
/// handshake and never reached `connected`.
///
/// `authRejected` is worth telling apart because retrying cannot fix it: an
/// expired, revoked or deactivated pairing needs a fresh QR, and a screen that
/// says "check your Wi-Fi" sends the waiter chasing the wrong problem.
enum ConnectFailure { none, authRejected, unreachable }

const String _tag = '[Socket]';

/// Every ack the app produces internally uses these codes, so callers branch
/// on a value rather than on substrings of an English message.
abstract final class AckCode {
  static const String connectionLost = 'connection_lost';
  static const String timeout = 'timeout';
  static const String badResponse = 'bad_response';
}

Map<String, dynamic> _errorAck(String code, String message) =>
    <String, dynamic>{'kind': 'error', 'code': code, 'message': message};

/// True when an ack represents a *transport* failure rather than the desk
/// deliberately rejecting the request.
///
/// The KOT queue depends on this distinction: a rejected KOT must be
/// surfaced and quarantined, but a KOT that never reached the desk must be
/// retried. The old code could not tell them apart, so it deleted both.
bool isTransportFailure(Map<String, dynamic> ack) {
  final code = ack['code'];
  return code == AckCode.connectionLost || code == AckCode.timeout;
}

class SocketService {
  /// Default ack timeout. Every ack path now has one — `emit(onAck:)`
  /// previously had none at all, so a desk that accepted a packet and never
  /// replied left the calling screen spinning forever.
  static const Duration ackTimeout = Duration(seconds: 12);

  /// Builds the namespace URL.
  ///
  /// `useTls` exists so the desk can move to a self-signed certificate whose
  /// fingerprint travels in the pairing QR, without another client release.
  /// Until then this is plain HTTP on the LAN and the pairing token and
  /// operator PIN are sniffable by anyone on the same WiFi — see
  /// CREW_FLUTTER_AUDIT.md #6.
  static String namespaceUrl(String host, int port, {bool useTls = false}) =>
      '${useTls ? 'https' : 'http'}://$host:$port/operator';

  /// True when the desk turned the handshake away over the pairing itself
  /// rather than the network failing.
  ///
  /// The desk sends a structured `{code, message}` payload on every
  /// handshake rejection now (see `authError()` in the desk's
  /// session-manager.ts) — checked first, and authoritative when present.
  /// Substring matching on a bare message is kept only as a fallback for a
  /// Desk build that predates the structured codes; a restaurant's phones
  /// and Desk software can be on different versions for a while after an
  /// update, so this can't be removed outright yet.
  static const Set<String> _authErrorCodes = <String>{
    'MISSING_TOKEN',
    'TOKEN_EXPIRED',
    'TOKEN_INVALID',
    'TOKEN_REVOKED',
    'OPERATOR_DEACTIVATED',
    'VERIFICATION_UNAVAILABLE',
  };

  static bool isAuthHandshakeError(Object? err) {
    if (err is Map) {
      final code = err['code'];
      if (code is String) return _authErrorCodes.contains(code);
    }
    final message = err.toString().toLowerCase();
    return message.contains('unauthorized') ||
        message.contains('auth') ||
        message.contains('token') ||
        message.contains('expired') ||
        message.contains('revoked') ||
        message.contains('deactivated');
  }

  /// Validates a host/port/token against the desk BEFORE it is persisted.
  /// Opens a disposable socket; never touches this instance's state.
  static Future<ProbeResult> probe(
    String host,
    int port,
    String token, {
    bool useTls = false,
  }) {
    final completer = Completer<ProbeResult>();
    io.Socket? probeSocket;
    Timer? timeoutTimer;

    void finish(ProbeResult result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      timeoutTimer?.cancel();
      probeSocket?.dispose();
    }

    final url = namespaceUrl(host, port, useTls: useTls);
    logD(_tag, 'probe $url');
    probeSocket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{'token': token})
          .disableReconnection()
          .build(),
    );
    probeSocket.onConnect((_) {
      logD(_tag, 'probe: ok');
      finish(ProbeResult.ok);
    });
    probeSocket.onConnectError((Object? err) {
      logD(_tag, 'probe: connect_error');
      finish(isAuthHandshakeError(err)
          ? ProbeResult.authRejected
          : ProbeResult.unreachable);
    });
    probeSocket.onError((_) {
      logD(_tag, 'probe: error');
      finish(ProbeResult.unreachable);
    });
    probeSocket.connect();
    timeoutTimer = Timer(const Duration(seconds: 6), () {
      logD(_tag, 'probe: timeout');
      finish(ProbeResult.unreachable);
    });

    return completer.future;
  }

  /// Hits the Desk's unauthenticated `GET /ping` — no socket, no token, no
  /// session mutation. Used to verify a rediscovery candidate is reachable
  /// (and, when the caller has a stored desk_instance_id, that it's the
  /// *same* Desk) without paying for a real authenticated socket per
  /// candidate the way [probe] does.
  ///
  /// [timeout] bounds the whole call, matching [probe]/[recover] — not just
  /// one of its internal awaits — so a caller racing several candidates gets
  /// the ceiling it asked for rather than up to 3x it.
  static Future<PingResult> ping(
    String host,
    int port, {
    bool useTls = false,
    Duration timeout = const Duration(seconds: 3),
  }) {
    return _pingUnbounded(host, port, useTls: useTls).timeout(
      timeout,
      onTimeout: () {
        logD(_tag, 'ping $host:$port: timeout');
        return const PingFailed();
      },
    );
  }

  static Future<PingResult> _pingUnbounded(
    String host,
    int port, {
    bool useTls = false,
  }) async {
    final scheme = useTls ? 'https' : 'http';
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$scheme://$host:$port/ping'));
      final response = await request.close();
      if (response.statusCode != 200) {
        logD(_tag, 'ping $host:$port: bad status ${response.statusCode}');
        return const PingFailed();
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      final id = decoded is Map ? decoded['id'] : null;
      logD(_tag, 'ping $host:$port: ok (id=$id)');
      return PingOk(id is String ? id : null);
    } catch (err) {
      logD(_tag, 'ping $host:$port failed: $err');
      return const PingFailed();
    } finally {
      client.close(force: true);
    }
  }

  /// Attempts a device-secret recovery login (employee ID + PIN, no QR).
  /// Never touches this instance's state — on success the caller persists
  /// the returned credentials and opens the real connection via [connect].
  static Future<RecoveryResult> recover(
    String host,
    int port,
    String employeeId,
    String pin,
    String deviceSecret, {
    bool useTls = false,
  }) {
    final completer = Completer<RecoveryResult>();
    io.Socket? recoverySocket;
    Timer? timeoutTimer;

    void finish(RecoveryResult result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      timeoutTimer?.cancel();
      recoverySocket?.dispose();
    }

    final url = namespaceUrl(host, port, useTls: useTls);
    logD(_tag, 'recover $url');
    recoverySocket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{
            'recovery': <String, dynamic>{
              'employee_id': employeeId,
              'pin': pin,
              'device_secret': deviceSecret,
            },
          })
          .disableReconnection()
          .build(),
    );
    recoverySocket.on('pairing:recovered', (dynamic data) {
      if (data is Map) {
        final token = data['token'];
        final secret = data['device_secret'];
        if (token is String && secret is String) {
          logD(_tag, 'recover: ok');
          finish(RecoverySuccess(token, secret));
          return;
        }
      }
      finish(const RecoveryFailed(null, 'Malformed response from desk'));
    });
    recoverySocket.onConnectError((Object? err) {
      logD(_tag, 'recover: connect_error');
      String? code;
      var message = "Can't reach the desk — same Wi-Fi?";
      if (err is Map) {
        final c = err['code'];
        if (c is String) code = c;
        final m = err['message'];
        if (m is String) message = m;
      }
      finish(RecoveryFailed(code, message));
    });
    recoverySocket.onError((_) {
      logD(_tag, 'recover: error');
      finish(const RecoveryFailed(null, 'Connection error'));
    });
    recoverySocket.connect();
    timeoutTimer = Timer(const Duration(seconds: 8), () {
      logD(_tag, 'recover: timeout');
      finish(const RecoveryFailed(null, "The desk didn't respond in time"));
    });

    return completer.future;
  }

  io.Socket? _socket;
  final StreamController<SocketState> _stateController =
      StreamController<SocketState>.broadcast();
  SocketState _state = SocketState.disconnected;

  /// Handlers registered per event, so [off] can remove exactly what was
  /// added instead of clearing every listener for that event.
  final Map<String, List<void Function(dynamic)>> _handlers =
      <String, List<void Function(dynamic)>>{};

  ConnectFailure _lastConnectFailure = ConnectFailure.none;

  Stream<SocketState> get stateStream => _stateController.stream;
  SocketState get state => _state;
  io.Socket? get socket => _socket;

  /// Why the most recent connect attempt failed. Read alongside a
  /// `disconnected` state transition — the state alone cannot say whether
  /// retrying is worth anything.
  ConnectFailure get lastConnectFailure => _lastConnectFailure;

  bool get isUsable =>
      _socket != null && _state != SocketState.disconnected;

  /// Nudges an already-configured socket that is sitting disconnected. The OS
  /// can freeze background networking, so engine.io's heartbeat may not have
  /// noticed a dead connection by the time the app is back in front of the
  /// user. No-op if we are already connecting/connected, or if connect() was
  /// never called this session.
  void reconnectIfNeeded() {
    if (_state == SocketState.disconnected && _socket != null) {
      logD(_tag, 'app resumed while disconnected — nudging reconnect');
      _socket!.connect();
    }
  }

  void connect(String host, int port, String token, {bool useTls = false}) {
    disconnect();
    _lastConnectFailure = ConnectFailure.none;
    _setState(SocketState.connecting);
    final url = namespaceUrl(host, port, useTls: useTls);
    // The token is never logged, not even a prefix. `debugPrint` survives
    // release builds, so the old "Token: ${token.substring(0, 20)}..." line
    // was writing the JWT header and the start of its payload to logcat on
    // every production connect.
    logD(_tag, 'connecting to $url (token ${redact(token)})');

    final socket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{'token': token})
          .enableReconnection()
          .setReconnectionDelay(2000)
          .setReconnectionAttempts(double.maxFinite.toInt())
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      logD(_tag, 'connected');
      _lastConnectFailure = ConnectFailure.none;
      _setState(SocketState.connected);
    });
    socket.onDisconnect((Object? reason) {
      logD(_tag, 'disconnected: $reason');
      _setState(SocketState.disconnected);
    });
    socket.onConnectError((Object? err) {
      logE(_tag, 'connection error', err);
      // Classified before the state change, so a listener reacting to
      // `disconnected` already sees why.
      _lastConnectFailure = isAuthHandshakeError(err)
          ? ConnectFailure.authRejected
          : ConnectFailure.unreachable;
      _setState(SocketState.disconnected);
    });
    socket.onReconnect((_) => logD(_tag, 'reconnected'));
    socket.connect();
  }

  Future<Map<String, dynamic>> verifyPin(String pin) async {
    logD(_tag, 'operator:verify');
    final response = await emitAck('operator:verify', <String, dynamic>{'pin': pin});
    if (response['kind'] == 'success') _setState(SocketState.verified);
    return response;
  }

  /// Restores `verified` after a successful resync has confirmed the desk
  /// still trusts our prior PIN verification. Without this a reconnect leaves
  /// the transport stuck at `connected`, which silently blocks KOT sending.
  ///
  /// This is a *transport* state, not an authorization decision — the desk
  /// re-checks the session on every mutating handler regardless.
  void markVerified() {
    if (_state != SocketState.disconnected) _setState(SocketState.verified);
  }

  /// Fire-and-forget, or callback-with-ack. The ack path now carries the same
  /// timeout as [emitAck].
  void emit(
    String event,
    Map<String, dynamic> data, {
    void Function(Map<String, dynamic>)? onAck,
    Duration timeout = ackTimeout,
  }) {
    if (onAck == null) {
      final socket = _socket;
      logD(_tag, '-> $event ${summarizeShape(data)}');
      if (socket == null || _state == SocketState.disconnected) {
        logD(_tag, '-> $event dropped (no connection)');
        return;
      }
      socket.emit(event, data);
      return;
    }
    unawaited(emitAck(event, data, timeout: timeout).then(onAck));
  }

  Future<Map<String, dynamic>> emitAck(
    String event,
    Map<String, dynamic> data, {
    Duration timeout = ackTimeout,
  }) async {
    final socket = _socket;
    logD(_tag, '-> $event ${summarizeShape(data)}');
    if (socket == null || _state == SocketState.disconnected) {
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
    try {
      final raw = await socket.emitWithAckAsync(event, data).timeout(timeout);
      if (raw is! Map) {
        logE(_tag, '$event ack was not a Map');
        return _errorAck(AckCode.badResponse, 'Invalid server response');
      }
      final response = Map<String, dynamic>.from(raw);
      logD(_tag, '<- $event ack kind=${response['kind']}');
      return response;
    } on TimeoutException {
      logE(_tag, '$event ack timed out');
      return _errorAck(
        AckCode.timeout,
        "The desk didn't respond — check the connection and retry",
      );
    } catch (err, stack) {
      logE(_tag, '$event failed', err, stack);
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
  }

  void on(String event, void Function(dynamic) handler) {
    final socket = _socket;
    if (socket == null) {
      logE(_tag, 'on($event) before connect — listener not registered');
      return;
    }
    void wrapped(dynamic data) {
      logD(_tag, '<- $event (broadcast)');
      handler(data);
    }

    _handlers.putIfAbsent(event, () => <void Function(dynamic)>[]).add(wrapped);
    socket.on(event, wrapped);
  }

  /// Removes only the handlers this service registered for [event].
  void off(String event) {
    final registered = _handlers.remove(event);
    final socket = _socket;
    if (socket == null || registered == null) return;
    for (final handler in registered) {
      socket.off(event, handler);
    }
  }

  void offAll() {
    for (final event in _handlers.keys.toList()) {
      off(event);
    }
  }

  void disconnect() {
    logD(_tag, 'disconnecting');
    offAll();
    _handlers.clear();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  void _setState(SocketState next) {
    if (_state == next) return;
    logD(_tag, 'state: $_state -> $next');
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void dispose() {
    disconnect();
    unawaited(_stateController.close());
  }
}
