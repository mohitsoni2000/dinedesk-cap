import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// SocketService.nudgeEngine reaches into socket_io_client internals so that a
/// reconnect is the *Manager's* (same io.Socket, so `_pid`/`_lastOffset` survive
/// and the desk can recover the session) instead of a client `disconnect()`
/// (which sends a namespace DISCONNECT socket.io never persists for recovery).
///
/// Those internals are not public API. This test references every one of them,
/// so a socket_io_client upgrade that moves or renames any breaks *here*, loudly,
/// instead of silently turning "recoverable blip" back into "full resync".
void main() {
  test('the engine-close API nudgeEngine relies on still exists', () {
    // Compile-time references (never invoked): Socket.io, Manager.engine,
    // engine.readyState and engine.onClose(reason).
    void closeEngine(io.Socket socket) {
      final engine = socket.io.engine;
      if (engine != null && engine.readyState != 'closed') {
        engine.onClose('client nudge: test');
      }
    }

    expect(closeEngine, isA<Function>());
  });

  test('a fresh io.Socket exposes the state nudgeEngine/decideReconnect read',
      () {
    final socket = io.io(
      'http://127.0.0.1:1/operator',
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .disableAutoConnect()
          .build(),
    );
    addTearDown(socket.dispose);

    expect(socket.io.engine, isNull,
        reason: 'no engine until the Manager opens one');
    expect(socket.connected, isFalse);
    expect(socket.active, isFalse);
    expect(socket.recovered, isFalse);
    expect(socket.io.reconnecting, isFalse);
  });

  test('the Manager reconnects on a closed engine unless skipReconnect is set',
      () {
    // Documents (and pins) the two flags `Manager.onclose` consults before it
    // schedules its own redial — the reason engine.onClose beats disconnect().
    final socket = io.io(
      'http://127.0.0.1:1/operator',
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .enableReconnection()
          .disableAutoConnect()
          .build(),
    );
    addTearDown(socket.dispose);
    expect(socket.io.reconnection, isTrue);
    expect(socket.io.skipReconnect, isNot(isTrue));
  });

  test('pubspec pins socket_io_client to the line this was verified against',
      () {
    final lock = File('pubspec.lock').readAsStringSync();
    final match = RegExp(
      r'socket_io_client:\n(?:\s+.*\n)*?\s+version: "([^"]+)"',
    ).firstMatch(lock);
    expect(match, isNotNull, reason: 'socket_io_client missing from the lock');
    expect(match!.group(1), startsWith('3.1.'),
        reason: 'nudgeEngine was verified against socket_io_client 3.1.x '
            '(manager.dart onclose, engine/socket.dart onClose). Re-read both '
            'before bumping, then update this expectation.');

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('socket_io_client: ">=3.1.4 <3.2.0"'));
  });
}
