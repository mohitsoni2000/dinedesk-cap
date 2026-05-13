import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum SocketState { disconnected, connecting, connected, verified }

class SocketService {
  io.Socket? _socket;
  final _stateController = StreamController<SocketState>.broadcast();
  SocketState _state = SocketState.disconnected;

  Stream<SocketState> get stateStream => _stateController.stream;
  SocketState get state => _state;
  io.Socket? get socket => _socket;

  void connect(String host, int port, String token) {
    disconnect();
    _setState(SocketState.connecting);

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

    _socket!.onConnect((_) => _setState(SocketState.connected));
    _socket!.onDisconnect((_) => _setState(SocketState.disconnected));
    _socket!.onConnectError((err) => _setState(SocketState.disconnected));
    _socket!.on('force:disconnect', (data) {
      _setState(SocketState.disconnected);
      disconnect();
    });

    _socket!.connect();
  }

  void verifyPin(String pin, {
    required Function(Map<String, dynamic>) onVerified,
    required Function(String) onRejected,
  }) {
    _socket?.emitWithAckAsync('operator:verify', {'pin': pin}).then((res) {
      final response = Map<String, dynamic>.from(res as Map);
      if (response['kind'] == 'verified') {
        _setState(SocketState.verified);
        onVerified(response);
      } else {
        onRejected(response['error']?.toString() ?? 'Invalid PIN');
      }
    }).catchError((err) {
      onRejected('Connection error');
    });
  }

  void emit(String event, Map<String, dynamic> data, {Function(Map<String, dynamic>)? onAck}) {
    if (onAck != null) {
      _socket?.emitWithAckAsync(event, data).then((res) {
        onAck(Map<String, dynamic>.from(res as Map));
      });
    } else {
      _socket?.emit(event, data);
    }
  }

  void on(String event, Function(dynamic) handler) {
    _socket?.on(event, handler);
  }

  void off(String event) {
    _socket?.off(event);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  void _setState(SocketState s) {
    _state = s;
    _stateController.add(s);
  }

  void dispose() {
    disconnect();
    _stateController.close();
  }
}
