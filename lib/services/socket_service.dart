import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum SocketState { disconnected, connecting, connected, verified }

enum ProbeResult { ok, authRejected, unreachable }

const _tag = '[Socket]';

class SocketService {
  /// Validates a host/port/token pairing against the server BEFORE it's
  /// saved — opens a disposable socket, never touches this instance's
  /// connection state.
  static Future<ProbeResult> probe(String host, int port, String token) {
    final completer = Completer<ProbeResult>();
    io.Socket? probeSocket;
    Timer? timeoutTimer;

    void finish(ProbeResult result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      timeoutTimer?.cancel();
      probeSocket?.dispose();
    }

    debugPrint('$_tag → probe http://$host:$port/operator');
    probeSocket = io.io(
      'http://$host:$port/operator',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableReconnection()
          .build(),
    );
    probeSocket.onConnect((_) {
      debugPrint('$_tag ← probe: ok');
      finish(ProbeResult.ok);
    });
    probeSocket.onConnectError((err) {
      final msg = err.toString().toLowerCase();
      final isAuthError = msg.contains('auth') ||
          msg.contains('token') ||
          msg.contains('expired');
      debugPrint('$_tag ← probe: connect_error ($err)');
      finish(isAuthError ? ProbeResult.authRejected : ProbeResult.unreachable);
    });
    probeSocket.onError((err) {
      debugPrint('$_tag ← probe: error ($err)');
      finish(ProbeResult.unreachable);
    });
    probeSocket.connect();
    timeoutTimer = Timer(const Duration(seconds: 6), () {
      debugPrint('$_tag ← probe: timeout');
      finish(ProbeResult.unreachable);
    });

    return completer.future;
  }

  io.Socket? _socket;
  final _stateController = StreamController<SocketState>.broadcast();
  SocketState _state = SocketState.disconnected;

  Stream<SocketState> get stateStream => _stateController.stream;
  SocketState get state => _state;
  io.Socket? get socket => _socket;

  void connect(String host, int port, String token) {
    disconnect();
    _setState(SocketState.connecting);
    debugPrint('$_tag Connecting to http://$host:$port/operator ...');
    debugPrint(
        '$_tag Token: ${token.length > 20 ? '${token.substring(0, 20)}…' : token}');

    _socket = io.io(
      'http://$host:$port/operator',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionDelay(2000)
          .setReconnectionAttempts(double.maxFinite.toInt())
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint('$_tag ✓ Connected to server');
      _setState(SocketState.connected);
    });
    _socket!.onDisconnect((reason) {
      debugPrint('$_tag ✗ Disconnected: $reason');
      _setState(SocketState.disconnected);
    });
    _socket!.onConnectError((err) {
      debugPrint('$_tag ✗ Connection error: $err');
      _setState(SocketState.disconnected);
    });
    _socket!.onReconnect((_) {
      debugPrint('$_tag ↻ Reconnected');
    });
    _socket!.onReconnectAttempt((attempt) {
      debugPrint('$_tag ↻ Reconnect attempt #$attempt');
    });
    _socket!.connect();
  }

  void verifyPin(
    String pin, {
    required Function(Map<String, dynamic>) onVerified,
    required Function(String) onRejected,
  }) {
    debugPrint('$_tag → operator:verify (pin: ${'*' * pin.length})');
    final socket = _socket;
    if (socket == null || _state == SocketState.disconnected) {
      onRejected('Connection lost');
      return;
    }
    socket
        .emitWithAckAsync('operator:verify', {'pin': pin})
        .timeout(const Duration(seconds: 12))
        .then((res) {
          if (res is! Map) {
            onRejected('Invalid server response');
            return;
          }
          final response = Map<String, dynamic>.from(res);
          debugPrint('$_tag ← operator:verify ack: kind=${response['kind']}');
          if (response['kind'] == 'success') {
            debugPrint(
                '$_tag ✓ PIN verified — operator: ${response['operator']?['name'] ?? 'unknown'}');
            debugPrint(
                '$_tag   Sync keys: ${(response['sync'] as Map?)?.keys.toList() ?? response.keys.toList()}');
            _setState(SocketState.verified);
            onVerified(response);
          } else {
            debugPrint('$_tag ✗ PIN rejected: ${response['message']}');
            onRejected(response['message']?.toString() ?? 'Invalid PIN');
          }
        })
        .catchError((err) {
          debugPrint('$_tag ✗ PIN verify error: $err');
          onRejected(err is TimeoutException
              ? "Server didn't respond — check the connection and retry"
              : 'Connection error');
        });
  }

  void emit(String event, Map<String, dynamic> data,
      {Function(Map<String, dynamic>)? onAck}) {
    debugPrint('$_tag → $event ${_summarize(data)}');
    final socket = _socket;
    if (socket == null || _state == SocketState.disconnected) {
      if (onAck != null) {
        onAck({'kind': 'error', 'message': 'Connection lost'});
      }
      return;
    }
    if (onAck != null) {
      socket.emitWithAckAsync(event, data).then((res) {
        if (res is! Map) {
          debugPrint('$_tag ← $event ack: non-Map response ($res)');
          onAck({'kind': 'error', 'message': 'Invalid server response'});
          return;
        }
        final response = Map<String, dynamic>.from(res);
        debugPrint('$_tag ← $event ack: kind=${response['kind']}');
        if (response['kind'] == 'error') {
          debugPrint('$_tag   Error: ${response['message']}');
        }
        onAck(response);
      }).catchError((err) {
        debugPrint('$_tag ✗ $event error: $err');
        onAck({'kind': 'error', 'message': 'Connection lost'});
      });
    } else {
      socket.emit(event, data);
    }
  }

  Future<Map<String, dynamic>> emitAck(
    String event,
    Map<String, dynamic> data, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    final socket = _socket;
    debugPrint('$_tag → $event ${_summarize(data)}');
    if (socket == null || _state == SocketState.disconnected) {
      return Future.value({'kind': 'error', 'message': 'Connection lost'});
    }
    return socket.emitWithAckAsync(event, data).timeout(timeout).then((res) {
      if (res is! Map) {
        debugPrint('$_tag ← $event ack: non-Map response ($res)');
        return {'kind': 'error', 'message': 'Invalid server response'};
      }
      final response = Map<String, dynamic>.from(res);
      debugPrint('$_tag ← $event ack: kind=${response['kind']}');
      if (response['kind'] == 'error') {
        debugPrint('$_tag   Error: ${response['message']}');
      }
      return response;
    }).catchError((err) {
      debugPrint('$_tag ✗ $event error: $err');
      return {'kind': 'error', 'message': 'Connection lost'};
    });
  }

  void on(String event, Function(dynamic) handler) {
    _socket?.on(event, (data) {
      debugPrint('$_tag ← $event (broadcast)');
      handler(data);
    });
  }

  void off(String event) {
    _socket?.off(event);
  }

  void disconnect() {
    debugPrint('$_tag Disconnecting...');
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  void _setState(SocketState s) {
    debugPrint('$_tag State: $_state → $s');
    _state = s;
    _stateController.add(s);
  }

  void dispose() {
    disconnect();
    _stateController.close();
  }

  static String _summarize(Map<String, dynamic> data) {
    final buf = StringBuffer('{');
    for (final e in data.entries) {
      if (buf.length > 1) buf.write(', ');
      if (e.value is List) {
        buf.write('${e.key}: [${(e.value as List).length} items]');
      } else if (e.value is String && (e.value as String).length > 40) {
        buf.write('${e.key}: "${(e.value as String).substring(0, 40)}…"');
      } else {
        buf.write('${e.key}: ${e.value}');
      }
    }
    buf.write('}');
    return buf.toString();
  }
}
