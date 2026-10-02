// ignore_for_file: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/link_monitor.dart';
import 'package:restro/services/socket_service.dart' show SocketState;

/// Everything the monitor does is an injected callback, so the whole policy
/// runs here against a fake clock with scripted probe results.
class Harness {
  Harness(this.async, {bool supported = true, bool proven = true}) {
    _supported = supported;
    _proven = proven;
    monitor = LinkMonitor(
      probeHeartbeat: (timeout) async {
        heartbeats.add(_now());
        return heartbeatOk;
      },
      probePing: (timeout) async {
        pings.add(_now());
        return pingOk;
      },
      nudgeEngine: (why) {
        nudges.add(_now());
        return nudgeActs;
      },
      retryConnect: () => retries.add(_now()),
      rediscover: () async => rediscoveries.add(_now()),
      reconnectIfNeeded: () => pokes.add(_now()),
      standDown: () => stoodDown,
      heartbeatSupported: () => _supported,
      heartbeatProven: () => _proven,
      onHeartbeatUnsupported: () {
        unsupportedCalls++;
        _supported = false;
      },
      onHealthChanged: healths.add,
      now: _now,
    );
  }

  final FakeAsync async;
  late final LinkMonitor monitor;
  late bool _supported;
  late bool _proven;

  bool heartbeatOk = true;
  bool pingOk = true;
  bool nudgeActs = true;
  bool stoodDown = false;
  int unsupportedCalls = 0;

  final List<DateTime> heartbeats = <DateTime>[];
  final List<DateTime> pings = <DateTime>[];
  final List<DateTime> nudges = <DateTime>[];
  final List<DateTime> retries = <DateTime>[];
  final List<DateTime> rediscoveries = <DateTime>[];
  final List<DateTime> pokes = <DateTime>[];
  final List<LinkHealth> healths = <LinkHealth>[];

  final DateTime _epoch = DateTime(2026, 1, 1);
  DateTime _now() => async.getClock(_epoch).now();

  void verified() => monitor.onSocketState(SocketState.verified);
  void elapse(Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }

  void flush() => async.flushMicrotasks();
}

const Duration s1 = Duration(seconds: 1);

void run(String name, void Function(Harness h) body,
    {bool supported = true, bool proven = true}) {
  test(name, () {
    fakeAsync((async) {
      final h = Harness(async, supported: supported, proven: proven);
      body(h);
      h.monitor.dispose();
    });
  });
}

void main() {
  group('suspicion, not a verdict', () {
    run('an ack timeout makes the link suspect and probes at once', (h) {
      h.verified();
      h.monitor.onAckTimeout('order:create');
      expect(h.monitor.health, LinkHealth.suspect);
      h.flush();
      expect(h.heartbeats, hasLength(1));
      expect(h.pings, hasLength(1), reason: 'heartbeat and /ping in parallel');
      expect(h.nudges, isEmpty);
    });

    run('a heartbeat that answers heals the suspicion without any teardown',
        (h) {
      h.verified();
      h.monitor.onAckTimeout('order:create');
      h.flush();
      expect(h.monitor.health, LinkHealth.healthy);
      expect(h.nudges, isEmpty);
      expect(h.retries, isEmpty);
      expect(h.healths, [LinkHealth.suspect, LinkHealth.healthy]);
    });

    run('a missed scheduled beat makes it suspect; a good one clears it', (h) {
      h.verified();
      h.monitor.onBeat(ok: false);
      expect(h.monitor.health, LinkHealth.suspect);
      h.flush();
      expect(h.monitor.health, LinkHealth.healthy);
      h.monitor.onBeat(ok: true);
      expect(h.monitor.health, LinkHealth.healthy);
    });

    run('signals while not verified are ignored (the socket owns that case)',
        (h) {
      h.monitor.onAckTimeout('order:create');
      h.monitor.onBeat(ok: false);
      expect(h.monitor.health, LinkHealth.healthy);
      expect(h.heartbeats, isEmpty);
    });
  });

  group('diagnosis', () {
    run('heartbeat missed while /ping answers => half-open => dead at once',
        (h) {
      h.heartbeatOk = false;
      h.pingOk = true;
      h.verified();
      h.monitor.onAckTimeout('order:create');
      h.flush();
      expect(h.monitor.health, LinkHealth.dead);
      expect(h.nudges, hasLength(1), reason: 'ladder step 1');
      expect(h.heartbeats, hasLength(1), reason: 'no second guess needed');
    });

    run('both probes failing once is not yet dead; a second failure is', (h) {
      h.heartbeatOk = false;
      h.pingOk = false;
      h.verified();
      h.monitor.onAckTimeout('order:create');
      h.flush();
      expect(h.monitor.health, LinkHealth.suspect);
      expect(h.nudges, isEmpty);

      // Confirming round after the 1.5s pause (and the 2s minimum gap).
      h.elapse(const Duration(milliseconds: 1500));
      expect(h.monitor.health, LinkHealth.suspect,
          reason: 'probes are at least 2s apart');
      h.elapse(const Duration(milliseconds: 600));
      h.flush();
      expect(h.heartbeats, hasLength(2));
      expect(h.monitor.health, LinkHealth.dead);
      expect(h.nudges, hasLength(1));
    });

    run('both failing, then the link recovers on the confirming probe', (h) {
      h.heartbeatOk = false;
      h.pingOk = false;
      h.verified();
      h.monitor.onAckTimeout('x');
      h.flush();
      h.heartbeatOk = true;
      h.elapse(const Duration(seconds: 3));
      expect(h.monitor.health, LinkHealth.healthy);
      expect(h.nudges, isEmpty);
    });

    run('probes are never closer than 2s apart', (h) {
      h.verified();
      h.monitor.onAckTimeout('a');
      h.flush();
      expect(h.monitor.health, LinkHealth.healthy);
      // New trouble immediately after the first probe round.
      h.monitor.onAckTimeout('b');
      h.flush();
      expect(h.heartbeats, hasLength(1), reason: 'held back by the 2s gap');
      h.elapse(const Duration(seconds: 2));
      h.flush();
      expect(h.heartbeats, hasLength(2));
      expect(h.heartbeats[1].difference(h.heartbeats[0]),
          greaterThanOrEqualTo(const Duration(seconds: 2)));
    });

    run('a network event while verified is suspicion too', (h) {
      h.verified();
      h.monitor.onNetworkEvent(const NetworkEvent(NetworkEventType.changed));
      expect(h.monitor.health, LinkHealth.suspect);
      h.flush();
      expect(h.heartbeats, hasLength(1));
    });

    run('resume: a short absence costs nothing, a long one probes', (h) {
      h.verified();
      h.monitor.onResume(const Duration(seconds: 19));
      h.flush();
      expect(h.heartbeats, isEmpty);
      h.monitor.onResume(const Duration(seconds: 21));
      h.flush();
      expect(h.heartbeats, hasLength(1));
    });
  });

  group('old desks: heartbeat silence never kills a session', () {
    run('first-ever missed beat on a reachable desk => unsupported, healthy',
        (h) {
      h.heartbeatOk = false;
      h.pingOk = true;
      h.verified();
      h.monitor.onBeat(ok: false);
      h.flush();
      expect(h.unsupportedCalls, 1);
      expect(h.monitor.health, LinkHealth.healthy);
      expect(h.nudges, isEmpty);
    }, proven: false);

    run('once unsupported: only /ping is consulted and the link never goes dead',
        (h) {
      h.heartbeatOk = false;
      h.pingOk = false;
      h.verified();
      h.monitor.onAckTimeout('order:create');
      h.elapse(const Duration(minutes: 2));
      expect(h.monitor.health, LinkHealth.suspect);
      expect(h.nudges, isEmpty);
      expect(h.retries, isEmpty);
      expect(h.heartbeats, isEmpty, reason: 'never sent to a desk without it');

      h.pingOk = true;
      h.elapse(const Duration(seconds: 12));
      expect(h.monitor.health, LinkHealth.healthy);
    }, supported: false);
  });

  group('the ladder never gives up', () {
    run('nudge, then rebuild, then rediscover, then loop with backoff', (h) {
      h.heartbeatOk = false;
      h.verified();
      h.monitor.onAckTimeout('x');
      h.flush();
      expect(h.nudges, hasLength(1));
      expect(h.retries, isEmpty);

      h.elapse(const Duration(seconds: 11));
      expect(h.retries, isEmpty, reason: 'nudge gets 12s to land');
      h.elapse(const Duration(seconds: 2));
      expect(h.retries, hasLength(1), reason: 'step 2 after 12s');
      expect(h.rediscoveries, isEmpty);

      h.elapse(const Duration(seconds: 15));
      expect(h.rediscoveries, hasLength(1), reason: 'step 3 after another 15s');

      // Then it keeps cycling, forever, with growing pauses.
      h.elapse(const Duration(seconds: 15 + 3));
      expect(h.retries.length, greaterThanOrEqualTo(2));
      final before = h.retries.length;
      h.elapse(const Duration(minutes: 10));
      expect(h.retries.length, greaterThan(before + 3));
      expect(h.rediscoveries.length, greaterThan(2));
    });

    run('it stops the moment the socket is up again, and starts over later',
        (h) {
      h.heartbeatOk = false;
      h.verified();
      h.monitor.onAckTimeout('x');
      h.flush();
      h.elapse(const Duration(seconds: 13));
      expect(h.retries, hasLength(1));

      h.monitor.onSocketState(SocketState.connected);
      h.verified();
      expect(h.monitor.health, LinkHealth.healthy);
      final retries = h.retries.length;
      final nudges = h.nudges.length;
      h.elapse(const Duration(minutes: 2));
      expect(h.retries.length, retries);
      expect(h.nudges.length, nudges);

      // Reset on verified: the next death begins at step 1 again.
      h.monitor.onAckTimeout('y');
      h.flush();
      expect(h.nudges.length, nudges + 1);
    });

    run('a socket that drops by itself gets its own redial window first', (h) {
      h.verified();
      h.monitor.onSocketState(SocketState.disconnected);
      expect(h.monitor.health, LinkHealth.dead);
      h.flush();
      expect(h.nudges, isEmpty, reason: 'socket.io is already redialling');
      h.elapse(const Duration(seconds: 13));
      expect(h.retries, hasLength(1));
    });

    run('a declined nudge (verify in flight) is not a death', (h) {
      h.heartbeatOk = false;
      h.nudgeActs = false;
      h.verified();
      h.monitor.onAckTimeout('x');
      h.flush();
      expect(h.nudges, hasLength(1));
      expect(h.monitor.health, LinkHealth.suspect);
      expect(h.retries, isEmpty);
      h.nudgeActs = true;
      h.elapse(const Duration(seconds: 3));
      h.flush();
      expect(h.nudges.length, greaterThanOrEqualTo(2),
          reason: 'it looks again once the verify is out of the way');
    });
  });

  group('standing down (refused pairing / force-disconnect / signed out)', () {
    run('a ladder that starts stood down does nothing at all', (h) {
      h.stoodDown = true;
      h.verified();
      h.monitor.onSocketState(SocketState.disconnected);
      h.elapse(const Duration(minutes: 2));
      expect(h.nudges, isEmpty);
      expect(h.retries, isEmpty);
      expect(h.rediscoveries, isEmpty);
    });

    run('a running ladder ends the moment the session is refused', (h) {
      h.verified();
      h.monitor.onSocketState(SocketState.disconnected);
      h.elapse(const Duration(seconds: 13));
      expect(h.retries, hasLength(1), reason: 'ladder step 2 ran');
      h.stoodDown = true; // two auth rejections / force:disconnect
      h.elapse(const Duration(minutes: 5));
      expect(h.retries, hasLength(1),
          reason: 'it must never redial with the refused token');
      expect(h.rediscoveries, isEmpty);
    });

    run('the watchdog and network events stop poking too', (h) {
      h.verified();
      h.monitor.onSocketState(SocketState.disconnected);
      h.stoodDown = true;
      h.elapse(const Duration(seconds: 30));
      h.monitor.onNetworkEvent(const NetworkEvent(NetworkEventType.available));
      h.monitor.onResume(const Duration(minutes: 5));
      expect(h.pokes, isEmpty);
    });
  });

  group('the reconnect watchdog', () {
    run('pokes an idle disconnected socket every 5s', (h) {
      h.verified();
      h.monitor.onSocketState(SocketState.disconnected);
      h.elapse(const Duration(seconds: 21));
      expect(h.pokes.length, 4);
    });

    run('stops when the socket is back', (h) {
      h.verified();
      h.monitor.onSocketState(SocketState.disconnected);
      h.elapse(const Duration(seconds: 6));
      final seen = h.pokes.length;
      h.monitor.onSocketState(SocketState.connected);
      h.elapse(const Duration(seconds: 30));
      expect(h.pokes.length, seen);
    });

    run('a network event while disconnected pokes immediately', (h) {
      h.monitor.onSocketState(SocketState.verified);
      h.monitor.onSocketState(SocketState.disconnected);
      h.monitor.onNetworkEvent(const NetworkEvent(NetworkEventType.available));
      expect(h.pokes, hasLength(1));
    });

    run('resume while disconnected pokes immediately', (h) {
      h.monitor.onSocketState(SocketState.verified);
      h.monitor.onSocketState(SocketState.disconnected);
      h.monitor.onResume(const Duration(minutes: 5));
      expect(h.pokes, hasLength(1));
    });
  });

  group('NetworkEvent.fromMap', () {
    test('parses the native channel payload', () {
      final e = NetworkEvent.fromMap(
          <String, dynamic>{'type': 'changed', 'networkId': '100'});
      expect(e!.type, NetworkEventType.changed);
      expect(e.networkId, '100');
      expect(NetworkEvent.fromMap(<String, dynamic>{'type': 'lost'})!.networkId,
          isNull);
    });

    test('unknown shapes are ignored, never thrown', () {
      expect(NetworkEvent.fromMap('x'), isNull);
      expect(NetworkEvent.fromMap(<String, dynamic>{'type': 'nope'}), isNull);
      expect(NetworkEvent.fromMap(null), isNull);
    });
  });
}
