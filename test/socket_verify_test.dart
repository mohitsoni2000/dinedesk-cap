import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';

/// A SocketService with no io.Socket underneath: "usable" is just the state
/// flag, and the verify emit is scripted by the test.
class _FakeSocket extends SocketService {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onSend;

  @override
  bool get isUsable => state != SocketState.disconnected;

  @override
  Future<Map<String, dynamic>> sendVerify(Map<String, dynamic> payload) {
    sent.add(payload);
    return onSend?.call(payload) ??
        Future.value(
            <String, dynamic>{'kind': 'success', 'data': <String, dynamic>{}});
  }
}

void main() {
  group('decideReconnect — never a second CONNECT for the same token', () {
    ReconnectAction decide({
      bool hasSocket = true,
      SocketState state = SocketState.disconnected,
      bool verifyInFlight = false,
      bool ioConnected = false,
      bool ioActive = false,
    }) =>
        SocketService.decideReconnect(
          hasSocket: hasSocket,
          state: state,
          verifyInFlight: verifyInFlight,
          ioConnected: ioConnected,
          ioActive: ioActive,
        );

    test('does nothing without a socket or when not down', () {
      expect(decide(hasSocket: false), ReconnectAction.none);
      expect(decide(state: SocketState.connected), ReconnectAction.none);
      expect(decide(state: SocketState.verified), ReconnectAction.none);
    });

    test('defers to an in-flight verify rather than touching the socket', () {
      expect(decide(verifyInFlight: true, ioConnected: true),
          ReconnectAction.deferForVerify);
    });

    test('rebuilds a zombie that socket.io still thinks is connected', () {
      expect(decide(ioConnected: true, ioActive: true),
          ReconnectAction.forceReconnect);
    });

    test('leaves a mid-reconnect socket to socket.io (no duplicate CONNECT)',
        () {
      expect(decide(ioActive: true), ReconnectAction.leaveToSocketIo);
    });

    test('reconnects a socket nothing is driving any more', () {
      expect(decide(), ReconnectAction.connect);
    });
  });

  group('verifyPin — single-flight, retries only when provably safe', () {
    late _FakeSocket socket;

    setUp(() {
      socket = _FakeSocket()
        ..verifyReconnectWait = const Duration(milliseconds: 300);
    });

    tearDown(() => socket.dispose());

    test('success marks the socket verified and clears the in-flight flag',
        () async {
      socket.debugSetState(SocketState.connected);
      final response = await socket.verifyPin('1234', menuVersion: 'mv');
      expect(response['kind'], 'success');
      expect(socket.state, SocketState.verified);
      expect(socket.isVerifyInFlight, isFalse);
      expect(socket.sent.single, {'pin': '1234', 'menu_version': 'mv'});
    });

    test('socket down before sending: waits, then sends the held PIN once',
        () async {
      socket.debugSetState(SocketState.disconnected);
      final pending = socket.verifyPin('1234');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(socket.sent, isEmpty,
          reason: 'a PIN must never be pushed into a socket that is down');
      expect(socket.isVerifyInFlight, isTrue);

      socket.debugSetState(SocketState.connected);
      final response = await pending;
      expect(response['kind'], 'success');
      expect(socket.sent, hasLength(1));
    });

    test('socket never comes back: fails without ever sending the PIN',
        () async {
      socket.debugSetState(SocketState.disconnected);
      final response = await socket.verifyPin('1234');
      expect(response['code'], AckCode.connectionLost);
      expect(socket.sent, isEmpty);
      expect(socket.isVerifyInFlight, isFalse);
    });

    test('socket drops with the PIN in flight: fails fast and does NOT resend',
        () async {
      socket.debugSetState(SocketState.connected);
      final neverAnswered = Completer<Map<String, dynamic>>();
      socket.onSend = (_) => neverAnswered.future;

      final pending = socket.verifyPin('1234');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.debugSetState(SocketState.disconnected);

      final response = await pending.timeout(const Duration(seconds: 1));
      expect(response['code'], AckCode.connectionLost);
      expect(socket.sent, hasLength(1),
          reason: 'the desk may already have counted this PIN toward its '
              'lockout — resending a wrong one would burn a second strike');
    });

    test('concurrent verifies are serialized, and whenVerifyIdle waits',
        () async {
      socket.debugSetState(SocketState.connected);
      final first = Completer<Map<String, dynamic>>();
      var calls = 0;
      socket.onSend = (_) {
        calls++;
        return calls == 1
            ? first.future
            : Future.value(<String, dynamic>{'kind': 'success'});
      };

      final a = socket.verifyPin('1111');
      final b = socket.verifyPin('2222');
      var idle = false;
      unawaited(socket.whenVerifyIdle().then((_) => idle = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(socket.sent.map((p) => p['pin']), ['1111'],
          reason: 'the second verify must wait for the first');
      expect(idle, isFalse);

      first.complete(<String, dynamic>{'kind': 'error', 'message': 'Invalid'});
      expect((await a)['kind'], 'error');
      expect((await b)['kind'], 'success');
      expect(socket.sent.map((p) => p['pin']), ['1111', '2222']);
      expect(idle, isTrue);
      expect(socket.isVerifyInFlight, isFalse);
    });
  });
}
