import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'log.dart';

enum SocketState { disconnected, connecting, connected, verified }

enum ProbeResult { ok, authRejected, unreachable }

sealed class PingResult {
  const PingResult();
}

final class PingOk extends PingResult {
  final String? id;
  const PingOk(this.id);
}

final class PingFailed extends PingResult {
  const PingFailed();
}

sealed class RecoveryResult {
  const RecoveryResult();
}

final class RecoverySuccess extends RecoveryResult {
  final String token;
  final String deviceSecret;
  const RecoverySuccess(this.token, this.deviceSecret);
}

final class RecoveryFailed extends RecoveryResult {
  final String? code;
  final String message;
  const RecoveryFailed(this.code, this.message);
}

enum ConnectFailure { none, authRejected, unreachable }

const String _tag = '[Socket]';

abstract final class AckCode {
  static const String connectionLost = 'connection_lost';
  static const String timeout = 'timeout';
  static const String badResponse = 'bad_response';
}

Map<String, dynamic> _errorAck(String code, String message) =>
    <String, dynamic>{'kind': 'error', 'code': code, 'message': message};

bool isTransportFailure(Map<String, dynamic> ack) {
  final code = ack['code'];
  return code == AckCode.connectionLost || code == AckCode.timeout;
}

class SocketService {
  static const Duration ackTimeout = Duration(seconds: 4);

  static const Set<String> _moneyEvents = {
    'bill:payment',
    'bill:generate',
    'discount:apply',
  };

  static String namespaceUrl(String host, int port, {bool useTls = false}) =>
      '${useTls ? 'https' : 'http'}://$host:$port/operator';

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
      final request =
          await client.getUrl(Uri.parse('$scheme://$host:$port/ping'));
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

  static Future<RecoveryResult> pairScanless(
    String host,
    int port,
    String employeeId,
    String pin, {
    bool useTls = false,
  }) {
    final completer = Completer<RecoveryResult>();
    io.Socket? pairingSocket;
    Timer? timeoutTimer;

    void finish(RecoveryResult result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      timeoutTimer?.cancel();
      pairingSocket?.dispose();
    }

    final url = namespaceUrl(host, port, useTls: useTls);
    logD(_tag, 'pairScanless $url');
    pairingSocket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{
            'pairing': <String, dynamic>{
              'employee_id': employeeId,
              'pin': pin,
            },
          })
          .disableReconnection()
          .build(),
    );
    pairingSocket.on('pairing:recovered', (dynamic data) {
      if (data is Map) {
        final token = data['token'];
        final secret = data['device_secret'];
        if (token is String && secret is String) {
          logD(_tag, 'pairScanless: ok');
          finish(RecoverySuccess(token, secret));
          return;
        }
      }
      finish(const RecoveryFailed(null, 'Malformed response from desk'));
    });
    pairingSocket.onConnectError((Object? err) {
      logD(_tag, 'pairScanless: connect_error');
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
    pairingSocket.onError((_) {
      logD(_tag, 'pairScanless: error');
      finish(const RecoveryFailed(null, 'Connection error'));
    });
    pairingSocket.connect();
    timeoutTimer = Timer(const Duration(seconds: 8), () {
      logD(_tag, 'pairScanless: timeout');
      finish(const RecoveryFailed(null, "The desk didn't respond in time"));
    });

    return completer.future;
  }

  io.Socket? _socket;
  final StreamController<SocketState> _stateController =
      StreamController<SocketState>.broadcast();
  SocketState _state = SocketState.disconnected;

  final Map<String, List<void Function(dynamic)>> _handlers =
      <String, List<void Function(dynamic)>>{};

  ConnectFailure _lastConnectFailure = ConnectFailure.none;

  Stream<SocketState> get stateStream => _stateController.stream;
  SocketState get state => _state;
  io.Socket? get socket => _socket;

  ConnectFailure get lastConnectFailure => _lastConnectFailure;

  bool get isUsable => _socket != null && _state != SocketState.disconnected;

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

    logD(_tag, 'connecting to $url (token ${redact(token)})');

    final socket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{'token': token})
          .enableReconnection()
          .setTimeout(3000)
          .setReconnectionDelay(400)
          .setReconnectionDelayMax(3000)
          .setRandomizationFactor(0.3)
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
    final response =
        await emitAck('operator:verify', <String, dynamic>{'pin': pin});
    if (response['kind'] == 'success') _setState(SocketState.verified);
    return response;
  }

  void markVerified() {
    if (_state != SocketState.disconnected) _setState(SocketState.verified);
  }

  void emit(
    String event,
    Map<String, dynamic> data, {
    void Function(Map<String, dynamic>)? onAck,
    Duration? timeout,
  }) {
    if (onAck == null) {
      if (_moneyEvents.contains(event)) {
        throw ArgumentError(
          '$event is a money event and must be called with emitAck (or '
          'emit(onAck:...) with an explicit timeout) — fire-and-forget with '
          'no ack leaves the caller unable to tell if it failed.',
        );
      }
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
    Duration? timeout,
  }) async {
    if (timeout == null && _moneyEvents.contains(event)) {
      throw ArgumentError(
        '$event is a money event and must pass an explicit timeout — '
        'the $ackTimeout default is not safe for it (see _moneyEvents doc).',
      );
    }
    final effectiveTimeout = timeout ?? ackTimeout;
    final socket = _socket;
    logD(_tag, '-> $event ${summarizeShape(data)}');
    if (socket == null || _state == SocketState.disconnected) {
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
    try {
      final raw = await socket
          .timeout(effectiveTimeout.inMilliseconds)
          .emitWithAckAsync(event, data);
      if (raw is! Map) {
        logE(_tag, '$event ack was not a Map');
        return _errorAck(AckCode.badResponse, 'Invalid server response');
      }
      final response = Map<String, dynamic>.from(raw);
      logD(_tag, '<- $event ack kind=${response['kind']}');
      return response;
    } catch (err, stack) {
      if (err.toString().contains('timed out')) {
        logE(_tag, '$event ack timed out');
        return _errorAck(
          AckCode.timeout,
          "The desk didn't respond — check the connection and retry",
        );
      }
      logE(_tag, '$event failed', err, stack);
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
  }

  /// Like [emitAck], but a transport failure (offline, or the ack timed out
  /// because the desk is unreachable) waits for the socket to reconnect and
  /// re-verify, then retries — instead of surfacing the failure immediately.
  /// `kot:send` already gets this via [KotQueueService]'s local queue;
  /// interactive actions like opening a table have no queue to fall back
  /// into, so a tap made mid-blip used to fail outright and need a second,
  /// manual tap once back online. Bounded by [maxWait] so a genuinely dead
  /// network still surfaces an error instead of hanging the caller forever.
  Future<Map<String, dynamic>> emitAckWhenConnected(
    String event,
    Map<String, dynamic> data, {
    Duration? timeout,
    Duration maxWait = const Duration(minutes: 5),
  }) async {
    final deadline = DateTime.now().add(maxWait);
    var response = await emitAck(event, data, timeout: timeout);
    while (isTransportFailure(response) && DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      await stateStream
          .firstWhere((s) => s == SocketState.verified)
          .timeout(remaining, onTimeout: () => SocketState.disconnected);
      if (DateTime.now().isAfter(deadline)) break;
      response = await emitAck(event, data, timeout: timeout);
    }
    return response;
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
