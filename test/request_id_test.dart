import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/utils/request_id.dart';

/// One id per user intent, reused on every retry of that intent.
void main() {
  late DateTime now;

  setUp(() {
    resetRequestIds();
    now = DateTime(2026, 1, 1);
    requestIdClock = () => now;
  });

  tearDown(() {
    resetRequestIds();
    requestIdClock = DateTime.now;
  });

  test('a retry of the same intent gets the same id', () {
    final a = requestIdFor('order:cancel', <String, dynamic>{'order_id': 'o1'});
    final b = requestIdFor('order:cancel', <String, dynamic>{'order_id': 'o1'});
    expect(b, a);
    expect(a.length, inInclusiveRange(1, 100));
  });

  test('key order does not matter; a changed payload is a new intent', () {
    final a = requestIdFor('discount:apply', <String, dynamic>{
      'order_id': 'o1',
      'custom': <String, dynamic>{'type': 'flat', 'value': 50},
    });
    final b = requestIdFor('discount:apply', <String, dynamic>{
      'custom': <String, dynamic>{'value': 50, 'type': 'flat'},
      'order_id': 'o1',
    });
    final c = requestIdFor('discount:apply', <String, dynamic>{
      'order_id': 'o1',
      'custom': <String, dynamic>{'type': 'flat', 'value': 60},
    });
    expect(b, a);
    expect(c, isNot(a));
  });

  test('different events never share an id', () {
    final a = requestIdFor('table:link', <String, dynamic>{'table_id': 't1'});
    final b = requestIdFor('table:unlink', <String, dynamic>{'table_id': 't1'});
    expect(a, isNot(b));
  });

  test('settling retires the id: doing it again deliberately is new', () {
    final a = requestIdFor('table:shift', <String, dynamic>{'to': 't2'});
    settleRequestId('table:shift', <String, dynamic>{'to': 't2'});
    expect(
        requestIdFor('table:shift', <String, dynamic>{'to': 't2'}), isNot(a));
  });

  test('an unanswered id expires so a much later action is not a replay', () {
    final a = requestIdFor('order:hold', <String, dynamic>{'order_id': 'o1'});
    now = now.add(kRequestIdTtl + const Duration(seconds: 1));
    expect(requestIdFor('order:hold', <String, dynamic>{'order_id': 'o1'}),
        isNot(a));
  });

  test('a client_request_id already in the payload is not part of the intent',
      () {
    final a = requestIdFor('kot:edit', <String, dynamic>{'order_id': 'o1'});
    final b = requestIdFor('kot:edit',
        <String, dynamic>{'order_id': 'o1', 'client_request_id': 'x'});
    expect(b, a);
  });

  group('emitAckIdempotent', () {
    late SocketService socket;
    late List<Map<String, dynamic>> payloads;

    setUp(() {
      socket = SocketService()
        ..debugSetState(SocketState.verified)
        ..ackRetryBackoff = (() => Duration.zero);
      payloads = <Map<String, dynamic>>[];
    });

    tearDown(() => socket.dispose());

    test('stamps the id and reuses it when the first attempt got no answer',
        () async {
      var attempt = 0;
      socket.rawEmitOverride = (event, data, timeout) async {
        payloads.add(data);
        if (attempt++ == 0) throw TimeoutException('ack timed out');
        return <String, dynamic>{'kind': 'success'};
      };
      final data = <String, dynamic>{'order_id': 'o1', 'reason': 'x'};

      final first = await socket.emitAckIdempotent('order:cancel', data);
      expect(first['code'], AckCode.timeout);
      final second = await socket.emitAckIdempotent('order:cancel', data);
      expect(second['kind'], 'success');

      expect(payloads, hasLength(2));
      expect(
          payloads[1]['client_request_id'], payloads[0]['client_request_id']);
      expect(payloads[0]['order_id'], 'o1');
      expect(data.containsKey('client_request_id'), isFalse,
          reason: 'the caller\'s map is not mutated');
    });

    test('a reconnect-and-resend inside emitAckWhenConnected keeps one id',
        () async {
      var attempt = 0;
      socket.rawEmitOverride = (event, data, timeout) async {
        payloads.add(data);
        if (attempt++ == 0) {
          // The link drops mid-request; back (verified) a moment later.
          Timer(const Duration(milliseconds: 10), () {
            socket.debugSetState(SocketState.disconnected);
            socket.debugSetState(SocketState.verified);
          });
          throw TimeoutException('ack timed out');
        }
        return <String, dynamic>{'kind': 'success'};
      };

      final result = await socket.emitAckIdempotent(
        'table:merge',
        <String, dynamic>{'a': 't1', 'b': 't2'},
        whenConnected: true,
      );

      expect(result['kind'], 'success');
      expect(payloads, hasLength(2));
      expect(
          payloads[1]['client_request_id'], payloads[0]['client_request_id']);
    });

    test('success retires the id; the next identical action is a new one',
        () async {
      socket.rawEmitOverride = (event, data, timeout) async {
        payloads.add(data);
        return <String, dynamic>{'kind': 'success'};
      };
      final data = <String, dynamic>{'order_id': 'o1'};
      await socket.emitAckIdempotent('order:hold', data);
      await socket.emitAckIdempotent('order:hold', data);
      expect(payloads[1]['client_request_id'],
          isNot(payloads[0]['client_request_id']));
    });

    test(
        'bill:payment: a lost ack is retried under the same id, a settled one '
        'is retired (the widgets no longer keep their own id maps)', () async {
      final data = <String, dynamic>{
        'bill_id': 'b1',
        'payments': <Map<String, dynamic>>[
          <String, dynamic>{'payment_mode': 'cash', 'amount': '100.00'}
        ],
      };
      var attempt = 0;
      socket.rawEmitOverride = (event, d, timeout) async {
        payloads.add(d);
        if (attempt++ == 0) throw TimeoutException('ack timed out');
        return <String, dynamic>{'kind': 'success'};
      };
      const t = Duration(seconds: 15);
      expect(
          (await socket.emitAckIdempotent('bill:payment', data,
              timeout: t))['code'],
          AckCode.timeout);
      await socket.emitAckIdempotent('bill:payment', data, timeout: t);
      expect(
          payloads[1]['client_request_id'], payloads[0]['client_request_id']);

      // Settled: charging the same amount again later is a NEW payment.
      await socket.emitAckIdempotent('bill:payment', data, timeout: t);
      expect(payloads[2]['client_request_id'],
          isNot(payloads[1]['client_request_id']));
    });

    test('money events keep their explicit-timeout rule', () {
      socket.rawEmitOverride =
          (event, data, timeout) async => <String, dynamic>{'kind': 'success'};
      expect(
        () => socket.emitAckIdempotent(
            'bill:generate', <String, dynamic>{'order_id': 'o1'}),
        throwsArgumentError,
      );
    });
  });
}
