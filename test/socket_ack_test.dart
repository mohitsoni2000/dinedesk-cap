import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';

/// A SocketService whose "usable" is just the state flag (no io.Socket).
class _FlagSocket extends SocketService {
  @override
  bool get isUsable => state != SocketState.disconnected;
}

/// F1 / F6: an ack timeout is evidence, never a verdict, and a drop answers
/// every waiting ack immediately instead of letting its timer run out.
void main() {
  late SocketService socket;

  setUp(() {
    socket = SocketService();
  });

  tearDown(() => socket.dispose());

  Future<dynamic> timesOut(String e, Map<String, dynamic> d, Duration t) =>
      Future<dynamic>.error(TimeoutException('ack timed out'));

  test('an ack timeout does not change the socket state', () async {
    socket.debugSetState(SocketState.verified);
    socket.rawEmitOverride = timesOut;

    final response = await socket.emitAck('order:create', <String, dynamic>{});

    expect(response['code'], AckCode.timeout);
    expect(socket.state, SocketState.verified,
        reason: 'flipping to disconnected here left a zombie: the io.Socket '
            'was still connected, so no onConnect ever fired again');
  });

  test('a timeout is reported with the event and the timeout that elapsed',
      () async {
    socket.debugSetState(SocketState.verified);
    socket.rawEmitOverride = timesOut;
    final reports = <String>[];
    Duration? elapsed;
    socket.onAckTimeout = (event, timeout) {
      reports.add(event);
      elapsed = timeout;
    };

    await socket.emitAck('order:create', <String, dynamic>{},
        timeout: const Duration(seconds: 7));

    expect(reports, ['order:create']);
    expect(elapsed, const Duration(seconds: 7));
  });

  test('a probe timing out is not reported (it must not trigger itself)',
      () async {
    socket.debugSetState(SocketState.verified);
    socket.rawEmitOverride = timesOut;
    var reported = false;
    socket.onAckTimeout = (_, __) => reported = true;

    final response = await socket.emitAckProbe(
        'operator:heartbeat', <String, dynamic>{},
        timeout: const Duration(seconds: 1));

    expect(response['code'], AckCode.timeout);
    expect(reported, isFalse);
    expect(socket.state, SocketState.verified);
  });

  test('pending acks fail fast, with connection_lost, when the socket drops',
      () async {
    socket.debugSetState(SocketState.verified);
    final never = Completer<dynamic>();
    socket.rawEmitOverride = (e, d, t) => never.future;

    final a = socket.emitAck('order:update', <String, dynamic>{});
    final b = socket.emitAck('table:shift', <String, dynamic>{},
        timeout: const Duration(seconds: 20));
    await Future<void>.delayed(Duration.zero);
    expect(socket.pendingAckCount, 2);

    socket.debugSetState(SocketState.disconnected);

    final results = await Future.wait(<Future<Map<String, dynamic>>>[a, b])
        .timeout(const Duration(milliseconds: 500));
    for (final r in results) {
      expect(r['code'], AckCode.connectionLost);
    }
    expect(socket.pendingAckCount, 0);
  });

  test('a timeout that fires after the ack was already failed is not reported',
      () async {
    socket.debugSetState(SocketState.verified);
    final late = Completer<dynamic>();
    socket.rawEmitOverride = (e, d, t) => late.future;
    var reported = false;
    socket.onAckTimeout = (_, __) => reported = true;

    final pending = socket.emitAck('order:update', <String, dynamic>{});
    await Future<void>.delayed(Duration.zero);
    socket.debugSetState(SocketState.disconnected);
    expect((await pending)['code'], AckCode.connectionLost);

    late.completeError(TimeoutException('ack timed out'));
    await Future<void>.delayed(Duration.zero);
    expect(reported, isFalse,
        reason: 'it says nothing about the current connection');
  });

  test('suspicion never fails acks: only a real disconnect does', () async {
    socket.debugSetState(SocketState.verified);
    final answer = Completer<dynamic>();
    socket.rawEmitOverride = (e, d, t) => answer.future;

    final pending = socket.emitAck('order:update', <String, dynamic>{});
    await Future<void>.delayed(Duration.zero);
    // A slow reply (another request timing out) must leave this one alone.
    expect(socket.pendingAckCount, 1);

    answer.complete(<String, dynamic>{'kind': 'success'});
    expect((await pending)['kind'], 'success');
  });

  test('emitting while disconnected answers connection_lost immediately',
      () async {
    socket.rawEmitOverride = (e, d, t) => fail('must not reach the wire');
    final response = await socket.emitAck('order:update', <String, dynamic>{});
    expect(response['code'], AckCode.connectionLost);
  });

  test('a successful ack feeds the RTT hook', () async {
    socket.debugSetState(SocketState.verified);
    socket.rawEmitOverride =
        (e, d, t) async => <String, dynamic>{'kind': 'success'};
    Duration? rtt;
    socket.onAckRtt = (d) => rtt = d;
    await socket.emitAck('order:update', <String, dynamic>{});
    expect(rtt, isNotNull);
  });

  group('emitAckWhenConnected', () {
    test(
        'a plain ack timeout on a still-verified socket re-emits after a short '
        'backoff instead of waiting for a transition that never comes',
        () async {
      socket.debugSetState(SocketState.verified);
      socket.ackRetryBackoff = () => Duration.zero;
      var calls = 0;
      socket.rawEmitOverride = (e, d, t) async {
        calls++;
        if (calls < 3) throw TimeoutException('ack timed out');
        return <String, dynamic>{'kind': 'success'};
      };

      final response = await socket
          .emitAckWhenConnected('table:open', <String, dynamic>{}).timeout(
              const Duration(seconds: 2),
              onTimeout: () => fail('hung waiting for a state change'));

      expect(response['kind'], 'success');
      expect(calls, 3);
    });

    test('the backoff retries are bounded', () async {
      socket.debugSetState(SocketState.verified);
      socket.ackRetryBackoff = () => Duration.zero;
      var calls = 0;
      socket.rawEmitOverride = (e, d, t) async {
        calls++;
        throw TimeoutException('ack timed out');
      };

      final response = await socket.emitAckWhenConnected(
          'table:open', <String, dynamic>{},
          maxBackoffRetries: 2).timeout(const Duration(seconds: 2));

      expect(response['code'], AckCode.timeout);
      expect(calls, 3, reason: 'the first emit plus two retries');
    });

    test('every retry of one intent carries the same client_request_id',
        () async {
      socket.debugSetState(SocketState.verified);
      socket.ackRetryBackoff = () => Duration.zero;
      final ids = <Object?>[];
      socket.rawEmitOverride = (e, d, t) async {
        ids.add(d['client_request_id']);
        if (ids.length < 3) throw TimeoutException('ack timed out');
        return <String, dynamic>{'kind': 'success'};
      };

      await socket.emitAckIdempotent('table:merge', <String, dynamic>{'a': 1},
          whenConnected: true);

      expect(ids, hasLength(3));
      expect(ids.toSet(), hasLength(1));
    });

    test('a dropped socket still waits for the next verified', () async {
      var calls = 0;
      socket.rawEmitOverride = (e, d, t) async {
        calls++;
        return <String, dynamic>{'kind': 'success'};
      };
      // Disconnected: the first emit answers connection_lost at once.
      final pending =
          socket.emitAckWhenConnected('table:open', <String, dynamic>{});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 0, reason: 'nothing may be emitted while disconnected');
      socket.debugSetState(SocketState.verified);

      expect((await pending)['kind'], 'success');
      expect(calls, 1);
    });
  });

  group('nudgeEngine', () {
    test('is a no-op while a PIN verify is in flight', () async {
      final flag = _FlagSocket();
      addTearDown(flag.dispose);
      flag.debugSetState(SocketState.connected);
      final never = Completer<dynamic>();
      flag.rawEmitOverride = (e, d, t) => never.future;

      final verify = flag.verifyPin('1234');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(flag.isVerifyInFlight, isTrue);

      expect(flag.nudgeEngine('test'), isFalse);
      expect(flag.state, SocketState.connected,
          reason: 'tearing the engine down would lose the verify\'s ack');

      never.complete(<String, dynamic>{'kind': 'success'});
      await verify;
    });

    test('with a live io.Socket: marks disconnected and fails pending acks',
        () async {
      // A real io.Socket pointed at a closed port: no engine is ever open, so
      // this exercises the state/ack half; the engine-close half is pinned by
      // socket_recovery_api_test.dart.
      socket.connect('127.0.0.1', 1, 'token');
      socket.debugSetState(SocketState.verified);
      final never = Completer<dynamic>();
      socket.rawEmitOverride = (e, d, t) => never.future;
      final pending = socket.emitAck('order:update', <String, dynamic>{});
      await Future<void>.delayed(Duration.zero);

      expect(socket.nudgeEngine('test'), isTrue);

      expect(socket.state, SocketState.disconnected);
      expect((await pending)['code'], AckCode.connectionLost);
    });

    test('markDead is a nudge, not a bare flag flip', () {
      socket.connect('127.0.0.1', 1, 'token');
      socket.debugSetState(SocketState.verified);
      socket.markDead();
      expect(socket.state, SocketState.disconnected);
    });

    test('does nothing without a socket', () {
      expect(socket.nudgeEngine('test'), isFalse);
    });
  });

  test('verifiedStream emits once per transition into verified', () async {
    final seen = <int>[];
    final sub = socket.verifiedStream.listen((_) => seen.add(seen.length));
    socket.debugSetState(SocketState.connected);
    socket.debugSetState(SocketState.verified);
    socket.debugSetState(SocketState.disconnected);
    socket.debugSetState(SocketState.connected);
    socket.debugSetState(SocketState.verified);
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 2);
    await sub.cancel();
  });
}
