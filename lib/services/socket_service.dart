import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../utils/request_id.dart';
import 'connection_health.dart';
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

/// What [SocketService.reconnectIfNeeded] should do about a socket the app
/// believes is down. See [SocketService.decideReconnect].
enum ReconnectAction {
  /// Nothing to do: no socket, or it isn't down.
  none,

  /// An operator:verify is in flight; its own outcome decides (see
  /// [SocketService.verifyPin]). Tearing the socket down now would lose the
  /// ack and is exactly how PIN entry used to end in "Connection lost".
  deferForVerify,

  /// We flagged the socket dead but socket.io still thinks it is connected —
  /// a zombie that no socket.io event will ever revive. Close the engine so
  /// the Manager redials under the same io.Socket (see
  /// [SocketService.nudgeEngine]).
  forceReconnect,

  /// socket.io's own reconnect loop still owns this socket (it may be
  /// mid-handshake). Calling `connect()` now would send a second CONNECT.
  leaveToSocketIo,

  /// Nothing is driving the socket any more (the desk disconnected it, or the
  /// handshake was refused); `connect()` is the only way back.
  connect,
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
    // Counter "Pay & Fire": order, KOT, bills and payment in one ack.
    'qsr:checkout',
    // Gate: a ticket sale takes money; a check-in spends a ticket for good
    // (anti-passback), so a lost ack must be retried, never guessed.
    'ticket:issue',
    'ticket:check_in',
  };

  static String namespaceUrl(String host, int port, {bool useTls = false}) =>
      '${useTls ? 'https' : 'http'}://$host:$port/operator';

  /// Codes the desk's auth middleware uses when it genuinely refuses this
  /// pairing. `VERIFICATION_UNAVAILABLE` is deliberately NOT here: it is a
  /// transient desk-side DB error ("try again"), and treating it as a revoked
  /// pairing used to stop the reconnect loop for good over a hiccup.
  static const Set<String> _authErrorCodes = <String>{
    'MISSING_TOKEN',
    'TOKEN_EXPIRED',
    'TOKEN_INVALID',
    'TOKEN_REVOKED',
    'OPERATOR_DEACTIVATED',
  };

  /// The structured code of a `connect_error`, or null.
  ///
  /// socket.io delivers a middleware `next(err)` as
  /// `{message, data: {code, message}}` — the code lives under `data`, never at
  /// the top level. This used to read `err['code']` only, which is always null
  /// for a real desk, so every classification silently fell through to the
  /// substring match. The top-level read is kept for the recovery/pairing
  /// sockets' older shapes and for tests.
  static String? handshakeErrorCode(Object? err) {
    if (err is! Map) return null;
    final top = err['code'];
    if (top is String) return top;
    final data = err['data'];
    if (data is Map) {
      final nested = data['code'];
      if (nested is String) return nested;
    }
    return null;
  }

  /// The human message of a `connect_error`, from either nesting level.
  static String? handshakeErrorMessage(Object? err) {
    if (err is! Map) return null;
    final data = err['data'];
    if (data is Map) {
      final nested = data['message'];
      if (nested is String && nested.isNotEmpty) return nested;
    }
    final top = err['message'];
    return top is String && top.isNotEmpty ? top : null;
  }

  static bool isAuthHandshakeError(Object? err) {
    final code = handshakeErrorCode(err);
    // A code is authoritative: an unknown code is NOT an auth failure, whatever
    // words its message happens to contain.
    if (code != null) return _authErrorCodes.contains(code);
    final message = err.toString().toLowerCase();
    return message.contains('unauthorized') ||
        message.contains('token') ||
        message.contains('revoked') ||
        message.contains('deactivated');
  }

  /// App version announced in the handshake (`app_version`). Cached once at
  /// startup by [loadAppVersion] so [connect] itself can stay synchronous.
  static String? _appVersion;

  /// Capabilities this build announces. `recovery-offset-v1` tells the desk it
  /// may append the recovery offset to our broadcasts and recover our session;
  /// [stripRecoveryOffset] is what makes that safe to accept.
  static const List<String> handshakeCaps = <String>['recovery-offset-v1'];

  @visibleForTesting
  static set debugAppVersion(String? value) => _appVersion = value;

  static String? get appVersion => _appVersion;

  /// Reads the pubspec version once. Never throws (no plugin host in tests,
  /// platform-channel failure): a missing version just omits the field.
  static Future<void> loadAppVersion() async {
    if (_appVersion != null) return;
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 2),
      );
      if (info.version.isNotEmpty) _appVersion = info.version;
    } catch (err) {
      logD(_tag, 'app version unavailable: $err');
    }
  }

  /// The operator-socket handshake auth (see the network contract, item 1).
  static Map<String, dynamic> buildHandshakeAuth(String token) =>
      <String, dynamic>{
        'token': token,
        if (_appVersion != null) 'app_version': _appVersion,
        'caps': handshakeCaps,
      };

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
    recoverySocket.on('pairing:recovered', (dynamic raw) {
      final data = stripRecoveryOffset(raw);
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
      final code = handshakeErrorCode(err);
      final message =
          handshakeErrorMessage(err) ?? "Can't reach the desk — same Wi-Fi?";
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
    pairingSocket.on('pairing:recovered', (dynamic raw) {
      final data = stripRecoveryOffset(raw);
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
      final code = handshakeErrorCode(err);
      final message =
          handshakeErrorMessage(err) ?? "Can't reach the desk — same Wi-Fi?";
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

  /// How many handshakes in a row the desk refused with an auth-coded
  /// `connect_error`. Reset by any successful connect. One refusal can be a
  /// race (a token being rotated, the desk mid-restart); only a repeat is
  /// treated as "this pairing is really dead" — see ConnectionBootstrap.
  int _authRejectionStreak = 0;
  int get authRejectionStreak => _authRejectionStreak;

  @visibleForTesting
  set debugAuthRejectionStreak(int value) => _authRejectionStreak = value;

  final StreamController<ConnectFailure> _connectFailures =
      StreamController<ConnectFailure>.broadcast();

  /// One event per failed handshake attempt. [stateStream] can't carry this:
  /// the state is already `disconnected` between retries, so the second and
  /// third refusals produce no state change at all.
  Stream<ConnectFailure> get connectFailureStream => _connectFailures.stream;

  /// How the measured link widens the timeouts below. Defaults to the fixed
  /// behaviour this class had before; [ConnectionSupervisor] swaps in an
  /// adaptive one once it is watching. Kept as an injected seam so the socket
  /// stays a transport and doesn't grow a second job.
  TimeoutPolicy timeoutPolicy = const FixedTimeoutPolicy();

  /// Fired with the round-trip time of every ack that came back cleanly, so a
  /// listener can build a link estimate from real traffic instead of only from
  /// dedicated probes.
  void Function(Duration)? onAckRtt;

  /// Fired when a (non-probe) ack times out, with the event name and the
  /// timeout that elapsed. A timeout is *evidence*, not a verdict: the socket
  /// may merely be slow or busy. This class used to flip itself to
  /// `disconnected` on any timeout, which left a zombie (io.Socket still
  /// connected, so no onConnect ever fired again). Now it only reports; the
  /// [LinkMonitor] decides, by probing, whether the link is really gone.
  void Function(String event, Duration timeout)? onAckTimeout;

  /// Transports for the long-lived operator socket. Websocket only — and
  /// deliberately so, even though the Desk may accept long-polling too.
  ///
  /// socket_io_client (3.1.4 in pubspec.lock, and still in 3.1.6) has no
  /// polling transport on native platforms at all: the dart:io build of
  /// `Transports.newInstance` (lib/src/engine/transport/io_transports.dart)
  /// ignores the requested name and always returns a WebSocket transport.
  /// Polling exists only in the web build. That rules out both orderings:
  ///
  /// - `['websocket', 'polling']` gives no fallback. A failed websocket
  ///   handshake goes engine `onError` -> `onClose` and the Manager simply
  ///   retries the *same* first transport; the list is only ever advanced when
  ///   constructing a transport throws, which never happens here.
  /// - `['polling', 'websocket']` is actively harmful. `createTransport` puts
  ///   the *name* into the handshake query, so the phone would open a
  ///   WebSocket to `...&transport=polling` — a transport mismatch every
  ///   engine.io server rejects, i.e. no connection at all, on every Desk.
  ///
  /// So a Desk-side polling allowance changes nothing for Crew until the app
  /// uses a client that actually implements polling on Android/iOS. Auth,
  /// connectionStateRecovery (pid/offset) and the heartbeat all ride the
  /// socket.io CONNECT packet / namespace events and are transport-agnostic,
  /// so nothing else here would need to change if that day comes.
  static const List<String> operatorTransports = <String>['websocket'];

  /// Base handshake timeout, before [timeoutPolicy] widens it. 3s was
  /// effectively a fixed value (the adaptive policy only widens once it has
  /// samples, and there are none on a fresh connect) and is shorter than a
  /// weak-WiFi TLS-less websocket upgrade routinely takes at 1 bar; the
  /// manager would then abandon an attempt that was about to succeed.
  static const Duration connectTimeout = Duration(seconds: 8);

  Stream<SocketState> get stateStream => _stateController.stream;

  /// Emits once per transition into [SocketState.verified]. The outbox drain
  /// worker and anything else that must "act on every (re)verify" hang off
  /// this instead of filtering [stateStream] themselves.
  Stream<void> get verifiedStream =>
      stateStream.where((s) => s == SocketState.verified);
  SocketState get state => _state;
  io.Socket? get socket => _socket;

  ConnectFailure get lastConnectFailure => _lastConnectFailure;

  bool get isUsable => _socket != null && _state != SocketState.disconnected;

  /// True when the desk restored the previous session on the last reconnect
  /// rather than handing out a fresh one (`connectionStateRecovery`,
  /// operator-server.ts). Every broadcast missed during the outage has already
  /// been replayed onto the existing listeners, so the usual catch-up resync
  /// would be pure redundant work — and it would be pushing the whole
  /// initial-sync payload back down the link that just proved weak enough to
  /// drop the connection.
  ///
  /// Only ever true for socket.io's own internal reconnects. A fresh
  /// [connect] builds a new session and can't recover.
  bool get wasRecovered => _socket?.recovered ?? false;

  /// Pure decision behind [reconnectIfNeeded], split out so it can be tested
  /// without a live socket.
  ///
  /// The `leaveToSocketIo` case is the one that matters most. socket_io_client's
  /// `Socket.connect()` (lib/src/socket.dart) re-sends the CONNECT packet
  /// whenever the engine is already open but the namespace isn't connected yet
  /// — which is precisely the state *during* socket.io's own reconnect, while
  /// the desk's auth middleware is still answering the first CONNECT. Nudging
  /// then put a second CONNECT on the wire with the same token: the desk
  /// registered a second socket for this operator, and its duplicate-socket
  /// teardown (operator.gateway.ts, `sameToken` → `oldSocket.disconnect(true)`)
  /// closed the connection the phone was actually using. Resume and
  /// "Wi-Fi is back" — the two callers — fire exactly when that reconnect is
  /// most likely to be mid-flight.
  static ReconnectAction decideReconnect({
    required bool hasSocket,
    required SocketState state,
    required bool verifyInFlight,
    required bool ioConnected,
    required bool ioActive,
  }) {
    if (!hasSocket || state != SocketState.disconnected) {
      return ReconnectAction.none;
    }
    if (verifyInFlight) return ReconnectAction.deferForVerify;
    if (ioConnected) return ReconnectAction.forceReconnect;
    if (ioActive) return ReconnectAction.leaveToSocketIo;
    return ReconnectAction.connect;
  }

  void reconnectIfNeeded() => _reconnectIfNeeded(ignoreVerify: false);

  void _reconnectIfNeeded({required bool ignoreVerify}) {
    final socket = _socket;
    final action = decideReconnect(
      hasSocket: socket != null,
      state: _state,
      verifyInFlight: !ignoreVerify && isVerifyInFlight,
      ioConnected: socket?.connected ?? false,
      ioActive: socket?.active ?? false,
    );
    switch (action) {
      case ReconnectAction.none:
        return;
      case ReconnectAction.deferForVerify:
        // verifyPin's own `finally` reconnects if the verify left it down.
        logD(_tag, 'reconnect requested mid-verify — deferring to its outcome');
      case ReconnectAction.forceReconnect:
        _forceReconnect('socket flagged dead but socket.io still connected');
      case ReconnectAction.leaveToSocketIo:
        logD(_tag, 'socket.io is already reconnecting — not doubling CONNECT');
      case ReconnectAction.connect:
        logD(_tag, 'socket idle while disconnected — nudging reconnect');
        socket!.connect();
    }
  }

  /// Rebuilds the *engine* under the same io.Socket, for a socket concluded
  /// dead while socket.io still reports it connected (the [LinkMonitor] proved
  /// the link half-open, or a network change broke it silently).
  ///
  /// Why not `socket.disconnect(); socket.connect()`: a client-side
  /// `disconnect()` sends a namespace DISCONNECT packet, which socket.io never
  /// persists for connection-state recovery, so the desk forgot the session and
  /// we paid a full resync. Instead the engine is closed from underneath the
  /// Manager: `Manager.onclose` (socket_io_client manager.dart) runs, sees
  /// `reconnection && !skipReconnect` and schedules its own backoff redial on
  /// the *same* io.Socket — which keeps `_pid`/`_lastOffset`, so the CONNECT
  /// carries them and the desk can recover the session.
  ///
  /// `engine.onClose(...)` rather than `engine.close()`: the latter waits for
  /// the write buffer to drain first (engine/socket.dart `close()`), and on a
  /// half-open link the drain never comes — the very case this exists for.
  /// `onClose` performs the whole cleanup immediately. Both are checked against
  /// the pinned socket_io_client (~3.1.4); `socket_recovery_api_test.dart`
  /// references them so an upgrade breaks loudly rather than silently
  /// regressing to zombies.
  void _forceReconnect(String why) {
    nudgeEngine(why);
  }

  /// Closes the engine (see [_forceReconnect]) and marks the socket down.
  ///
  /// No-op while an operator:verify is in flight: the desk drops a socket when
  /// a newer one presents the same token, and tearing the engine down would
  /// lose the verify's ack just the same.
  /// Returns whether it acted.
  bool nudgeEngine(String why) {
    if (isVerifyInFlight) {
      logD(_tag, 'nudgeEngine ignored — a PIN verify is in flight ($why)');
      return false;
    }
    final socket = _socket;
    if (socket == null) return false;
    logD(_tag, 'nudging the engine: $why');
    // Down first: every pending ack fails fast and nothing new is sent into
    // the dead engine while it closes.
    _setState(SocketState.disconnected);
    final engine = socket.io.engine;
    if (engine != null && engine.readyState != 'closed') {
      engine.onClose('client nudge: $why');
    } else {
      // No live engine to close (a connect attempt failed, or the Manager is
      // between attempts): connect() is idempotent about not doubling CONNECT.
      socket.connect();
    }
    return true;
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
          .setTransports(operatorTransports)
          .setAuth(buildHandshakeAuth(token))
          .enableReconnection()
          .setTimeout(timeoutPolicy.forConnect(connectTimeout).inMilliseconds)
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
      _authRejectionStreak = 0;
      _setState(SocketState.connected);
    });
    socket.onDisconnect((Object? reason) {
      logD(_tag, 'disconnected: $reason');
      _setState(SocketState.disconnected);
    });
    socket.onConnectError((Object? err) {
      logE(_tag, 'connection error', err);

      final auth = isAuthHandshakeError(err);
      _lastConnectFailure =
          auth ? ConnectFailure.authRejected : ConnectFailure.unreachable;
      _authRejectionStreak = auth ? _authRejectionStreak + 1 : 0;
      _setState(SocketState.disconnected);
      if (!_connectFailures.isClosed) _connectFailures.add(_lastConnectFailure);
    });
    socket.onReconnect((_) => logD(_tag, 'reconnected'));
    socket.connect();
  }

  /// For any ack whose success response bundles the full initial-sync
  /// payload (tables, menu, active orders) — operator:verify, operator:resync
  /// — far more data than the plain [ackTimeout] was sized for. The desk's
  /// own engine.io heartbeat tolerates up to `pingInterval + pingTimeout`
  /// (40s, operator-server.ts) of silence before calling a connection dead —
  /// raised alongside this value because a large payload that takes longer
  /// to transfer than the *old*, shorter pingTimeout could trip the
  /// heartbeat and kill a connection that was never actually dead, just busy
  /// moving data over a slow multi-hop LAN (e.g. a weak-signal floor
  /// relaying through another floor's router to reach the desk). 28s keeps a
  /// safety margin under that 40s ceiling — always let the app's own timeout
  /// give up first, never the transport underneath it.
  static const Duration syncBundledAckTimeout = Duration(seconds: 28);

  /// The `operator:verify` payload.
  ///
  /// [menuVersion] is the version of the menu this phone already holds (the
  /// same value `operator:resync` sends — see SyncService). A Desk that knows
  /// it answers with `sync.menu` omitted when the versions match — the menu is
  /// ~277KB of the ~368KB verify reply, re-sent on every PIN entry for nothing,
  /// and that one oversized ack is what a weak multi-hop LAN chokes on. An
  /// older Desk strips the unknown key (its zod schema is non-strict) and
  /// sends the full menu as before. Omitted entirely when there is no cached
  /// menu, so a cold start always gets one.
  static Map<String, dynamic> buildVerifyPayload(
    String pin, {
    String? menuVersion,
  }) =>
      <String, dynamic>{
        'pin': pin,
        if (menuVersion != null && menuVersion.isNotEmpty)
          'menu_version': menuVersion,
      };

  Completer<void>? _verifyInFlight;

  /// True while an operator:verify is between "PIN submitted" and "answer
  /// handled". Everything that could replace or tear down the socket —
  /// [ConnectionBootstrap]'s connect/retry/repair, the supervisor's heartbeat,
  /// the app-resume check — holds off while this is set, because the desk
  /// drops a socket as soon as another one presents the same token, and the
  /// verify's ack dies with it.
  bool get isVerifyInFlight => _verifyInFlight != null;

  /// Completes once no verify is in flight (immediately if none is).
  Future<void> whenVerifyIdle() =>
      _verifyInFlight?.future ?? Future<void>.value();

  /// How long [verifyPin] waits for a down socket to come back before giving
  /// up on a PIN it hasn't sent yet. An instance field so tests can shorten it.
  Duration verifyReconnectWait = const Duration(seconds: 10);

  /// operator:verify, single-flight, with one transparent retry where that is
  /// provably safe.
  ///
  /// - **Single-flight.** Concurrent calls queue behind each other, and while
  ///   one is in flight [isVerifyInFlight] holds every reconnect path off.
  /// - **Socket down before sending → wait, then send once.** The PIN never
  ///   left the phone, so the desk has not counted it against the operator's
  ///   5-strike lockout (session-manager.ts `verifyPinForOperator`). Waiting up
  ///   to [verifyReconnectWait] for the socket to come back and sending it then
  ///   is invisible to the operator — this used to be an instant
  ///   "Connection lost" and a re-typed PIN, forever, if the socket was a
  ///   zombie (see [_forceReconnect]).
  /// - **Socket drops after sending → fail fast, never resend.** The desk may
  ///   well have checked that PIN already; if it was wrong, a silent resend
  ///   would burn a second lockout strike for one attempt. So the operator is
  ///   asked to enter it again — but straight away, instead of after the full
  ///   [syncBundledAckTimeout], because this Dart client never rejects an
  ///   ack whose socket went away; it only lets its timer run out.
  Future<Map<String, dynamic>> verifyPin(
    String pin, {
    String? menuVersion,
  }) async {
    while (_verifyInFlight != null) {
      await _verifyInFlight!.future;
    }
    final inFlight = Completer<void>();
    _verifyInFlight = inFlight;
    try {
      logD(_tag,
          'operator:verify${menuVersion == null ? '' : ' (menu_version held)'}');
      final payload = buildVerifyPayload(pin, menuVersion: menuVersion);

      if (!isUsable) {
        logD(_tag, 'verify: socket down before send — waiting for it');
        _reconnectIfNeeded(ignoreVerify: true);
        if (!await _awaitUsable(verifyReconnectWait)) {
          logD(_tag, 'verify: socket did not come back — PIN not sent');
          return _errorAck(AckCode.connectionLost, 'Connection lost');
        }
        logD(_tag, 'verify: socket back — sending the held PIN');
      }

      final response = await _sendVerifyUnlessDropped(payload);
      if (response['kind'] == 'success') _setState(SocketState.verified);
      return response;
    } finally {
      _verifyInFlight = null;
      inFlight.complete();
      _settleDeferredReconnect();
    }
  }

  Future<bool> _awaitUsable(Duration wait) async {
    if (isUsable) return true;
    try {
      await stateStream
          .firstWhere(
              (s) => s == SocketState.connected || s == SocketState.verified)
          .timeout(wait);
    } on TimeoutException {
      return false;
    } on StateError {
      return false; // stream closed — service disposed
    }
    return isUsable;
  }

  Future<Map<String, dynamic>> _sendVerifyUnlessDropped(
    Map<String, dynamic> payload,
  ) async {
    final dropped = Completer<Map<String, dynamic>>();
    final sub = stateStream.listen((s) {
      if (s == SocketState.disconnected && !dropped.isCompleted) {
        logD(_tag, 'verify: socket dropped with the PIN in flight');
        dropped.complete(_errorAck(
          AckCode.connectionLost,
          'Connection dropped while checking your PIN — please enter it again',
        ));
      }
    });
    try {
      return await Future.any(<Future<Map<String, dynamic>>>[
        sendVerify(payload),
        dropped.future,
      ]);
    } finally {
      await sub.cancel();
    }
  }

  /// The raw operator:verify emit. Overridden in tests only.
  @visibleForTesting
  Future<Map<String, dynamic>> sendVerify(Map<String, dynamic> payload) =>
      emitAck('operator:verify', payload, timeout: syncBundledAckTimeout);

  /// A verify that ended with the socket down leaves the PIN screen with
  /// nothing else driving a reconnect (the supervisor only watches verified
  /// sockets, ConnectionBootstrap only resumed ones), so bring it back here —
  /// ready for the operator's next attempt instead of "Connection lost"
  /// forever.
  void _settleDeferredReconnect() {
    if (_state == SocketState.disconnected) {
      _reconnectIfNeeded(ignoreVerify: true);
    }
  }

  @visibleForTesting
  void debugSetState(SocketState next) => _setState(next);

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
    return _emitAck(
      event,
      data,
      timeoutPolicy.forAck(timeout ?? ackTimeout),
      reportTimeout: true,
    );
  }

  /// [emitAck] (or [emitAckWhenConnected]) with a `client_request_id` that is
  /// stable for this *intent* — see `requestIdFor`. Every retry, including the
  /// reconnect-and-resend loop inside [emitAckWhenConnected], carries the same
  /// id, so a first attempt that landed but lost its ack is replayed by the desk
  /// instead of applied twice. The id is retired on success.
  ///
  /// [requestId] is an id the caller holds itself (one it stamped earlier
  /// from `requestIdFor` and keeps past its 15-minute expiry); it is sent
  /// instead, and the intent is still retired on success.
  Future<Map<String, dynamic>> emitAckIdempotent(
    String event,
    Map<String, dynamic> data, {
    Duration? timeout,
    bool whenConnected = false,
    String? requestId,
  }) async {
    final stamped = <String, dynamic>{
      ...data,
      'client_request_id': requestId ?? requestIdFor(event, data),
    };
    final response = whenConnected
        ? await emitAckWhenConnected(event, stamped, timeout: timeout)
        : await emitAck(event, stamped, timeout: timeout);
    if (response['kind'] != 'error') settleRequestId(event, data);
    return response;
  }

  /// [emitAck] for liveness probing. A timeout here is genuinely ambiguous (a
  /// desk build older than the probed event never answers it) and the caller
  /// is the one deciding what silence means, so it is not reported through
  /// [onAckTimeout] — that would make the monitor probe because of its own
  /// probe.
  Future<Map<String, dynamic>> emitAckProbe(
    String event,
    Map<String, dynamic> data, {
    Duration timeout = ackTimeout,
  }) =>
      _emitAck(event, data, timeout, reportTimeout: false);

  /// Acks currently awaiting an answer. Every one is failed the instant the
  /// socket goes `disconnected` (see [_setState]): this Dart client never
  /// rejects an ack whose socket went away, it only lets the timer run out, so
  /// a user would otherwise stare at a spinner for the full timeout (up to 28s
  /// for a sync) after the link was already known to be down.
  final Set<Completer<Map<String, dynamic>>> _pendingAcks =
      <Completer<Map<String, dynamic>>>{};

  @visibleForTesting
  int get pendingAckCount => _pendingAcks.length;

  /// The raw socket.io emit-with-ack. Replaceable in tests so the timeout and
  /// drop behaviour can be exercised without a live socket. Throws a
  /// "timed out" error when no ack arrives in [timeout].
  @visibleForTesting
  Future<dynamic> Function(
          String event, Map<String, dynamic> data, Duration timeout)?
      rawEmitOverride;

  Future<dynamic> _rawEmit(
    String event,
    Map<String, dynamic> data,
    Duration timeout,
  ) {
    final override = rawEmitOverride;
    if (override != null) return override(event, data, timeout);
    return _socket!
        .timeout(timeout.inMilliseconds)
        .emitWithAckAsync(event, data);
  }

  Future<Map<String, dynamic>> _emitAck(
    String event,
    Map<String, dynamic> data,
    Duration effectiveTimeout, {
    required bool reportTimeout,
  }) async {
    logD(_tag, '-> $event ${summarizeShape(data)}');
    if ((_socket == null && rawEmitOverride == null) ||
        _state == SocketState.disconnected) {
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
    final pending = Completer<Map<String, dynamic>>();
    _pendingAcks.add(pending);
    unawaited(_runAck(event, data, effectiveTimeout, reportTimeout, pending)
        .then((response) {
      if (!pending.isCompleted) pending.complete(response);
    }));
    try {
      return await pending.future;
    } finally {
      _pendingAcks.remove(pending);
    }
  }

  Future<Map<String, dynamic>> _runAck(
    String event,
    Map<String, dynamic> data,
    Duration effectiveTimeout,
    bool reportTimeout,
    Completer<Map<String, dynamic>> pending,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final raw = await _rawEmit(event, data, effectiveTimeout);
      if (raw is! Map) {
        logE(_tag, '$event ack was not a Map');
        return _errorAck(AckCode.badResponse, 'Invalid server response');
      }
      onAckRtt?.call(stopwatch.elapsed);
      final response = Map<String, dynamic>.from(raw);
      logD(_tag, '<- $event ack kind=${response['kind']}');
      return response;
    } catch (err, stack) {
      if (err.toString().contains('timed out')) {
        logE(_tag, '$event ack timed out');
        // Evidence, not a verdict: report it and leave the state alone. Not
        // while a verify is in flight — its sync-sized reply holds up every
        // ack queued behind it, so an unrelated timeout then says "busy", not
        // "dead".
        // Nor if the ack was already failed by a disconnect: that timer firing
        // late says nothing about the *current* connection.
        if (reportTimeout && !isVerifyInFlight && !pending.isCompleted) {
          onAckTimeout?.call(event, effectiveTimeout);
        }
        return _errorAck(
          AckCode.timeout,
          "The desk didn't respond — check the connection and retry",
        );
      }
      logE(_tag, '$event failed', err, stack);
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
  }

  void _failPendingAcks() {
    if (_pendingAcks.isEmpty) return;
    final pending = _pendingAcks.toList();
    _pendingAcks.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(_errorAck(AckCode.connectionLost, 'Connection lost'));
      }
    }
  }

  /// Declares the transport dead from the outside. For a caller that has
  /// established, by means this class can't see, that the socket is a zombie —
  /// io.Socket still reporting "connected" over a TCP connection nothing is
  /// listening on.
  void markDead() {
    if (_socket == null) return;
    if (isVerifyInFlight) {
      logD(_tag, 'markDead ignored — a PIN verify is in flight');
      return;
    }
    // Not a bare state flip: that is what produced zombies. Close the engine
    // so socket.io actually redials.
    nudgeEngine('marked dead from outside');
  }

  /// Like [emitAck], but a transport failure (offline, or the ack timed out
  /// because the desk is unreachable) waits for the socket to reconnect and
  /// re-verify, then retries — instead of surfacing the failure immediately.
  /// `kot:send` already gets this via [KotQueueService]'s local queue;
  /// interactive actions like opening a table have no queue to fall back
  /// into, so a tap made mid-blip used to fail outright and need a second,
  /// manual tap once back online. Bounded by [maxWait] so a genuinely dead
  /// network still surfaces an error instead of hanging the caller forever.
  ///
  /// Two different failures look alike here and need different waits:
  /// - the socket dropped (state != verified): wait for the next `verified`;
  /// - a plain ack timeout on a socket that is *still* verified (timeouts are
  ///   evidence, never a verdict, so they no longer change the state): there is
  ///   no transition coming, and waiting for one used to hang the caller for the
  ///   whole [maxWait]. Re-emit after a short jittered backoff instead, at most
  ///   [maxBackoffRetries] times. The caller's `client_request_id` rides every
  ///   retry unchanged (see [emitAckIdempotent]), so a first attempt that landed
  ///   is replayed by the desk, not applied twice.
  Future<Map<String, dynamic>> emitAckWhenConnected(
    String event,
    Map<String, dynamic> data, {
    Duration? timeout,
    Duration maxWait = const Duration(minutes: 5),
    int maxBackoffRetries = 4,
  }) async {
    final deadline = DateTime.now().add(maxWait);
    var response = await emitAck(event, data, timeout: timeout);
    var backoffRetries = 0;
    while (isTransportFailure(response) && DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      if (_state == SocketState.verified) {
        if (backoffRetries >= maxBackoffRetries) break;
        backoffRetries++;
        final pause = ackRetryBackoff();
        if (pause >= remaining) break;
        await Future<void>.delayed(pause);
      } else {
        await stateStream
            .firstWhere((s) => s == SocketState.verified)
            .timeout(remaining, onTimeout: () => SocketState.disconnected);
      }
      if (DateTime.now().isAfter(deadline)) break;
      response = await emitAck(event, data, timeout: timeout);
    }
    return response;
  }

  static final math.Random _jitter = math.Random();

  /// Pause before re-emitting after a plain ack timeout on a verified socket:
  /// 1.5-3s, jittered so a room of phones that timed out together (the desk
  /// stalled) do not all hit it again in the same instant. Tests zero it.
  @visibleForTesting
  Duration Function() ackRetryBackoff = () =>
      Duration(milliseconds: 1500 + _jitter.nextInt(1500));

  /// What a recovery offset looks like: socket.io's base64url-ish id.
  static final RegExp _offsetLike = RegExp(r'^[0-9A-Za-z_-]{6,}$');

  /// Strips the per-packet offset socket.io appends to every broadcast once the
  /// desk enables `connectionStateRecovery` for a capable client.
  ///
  /// socket_io_client (`socket.dart` → `emitEvent`) hands the listener
  /// `[args..., offset]` as a List whenever an event carries a payload plus the
  /// offset, and the bare offset String when the event had no payload at all.
  /// Every handler in `sync_service.dart` expects the payload Map, so without
  /// this the entire live-update layer would go quiet the moment recovery was
  /// switched on — silently, since `asMap` on a List just yields nothing.
  ///
  /// - `[Map, offset]` → the Map (the overwhelmingly common case).
  /// - `[a, …, offset]` where the last element is offset-like → the list
  ///   without it (a single remaining element is unwrapped).
  /// - a bare offset-like String → `{}` (an event that carried no payload).
  /// - anything else is returned untouched, so a payload that merely happens to
  ///   be a list or a string is never truncated.
  static dynamic stripRecoveryOffset(dynamic data) {
    if (data is String) {
      return _offsetLike.hasMatch(data) ? <String, dynamic>{} : data;
    }
    if (data is! List || data.length < 2) return data;
    final last = data.last;
    if (last is! String) return data;
    final isPayloadPair = data.length == 2 && data.first is Map;
    if (!isPayloadPair && !_offsetLike.hasMatch(last)) return data;
    final rest = data.sublist(0, data.length - 1);
    return rest.length == 1 ? rest.first : rest;
  }

  void on(String event, void Function(dynamic) handler) {
    final socket = _socket;
    if (socket == null) {
      logE(_tag, 'on($event) before connect — listener not registered');
      return;
    }
    void wrapped(dynamic data) {
      logD(_tag, '<- $event (broadcast)');
      handler(stripRecoveryOffset(data));
    }

    _handlers.putIfAbsent(event, () => <void Function(dynamic)>[]).add(wrapped);
    socket.on(event, wrapped);
  }

  /// Installs an io.Socket without dialling (tests that only need listeners).
  @visibleForTesting
  void debugAttachSocket(io.Socket socket) => _socket = socket;

  /// Events with at least one listener registered through [on].
  @visibleForTesting
  Iterable<String> get registeredEvents => _handlers.keys;

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
    // Nothing can answer these any more.
    _failPendingAcks();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  void _setState(SocketState next) {
    if (_state == next) return;
    logD(_tag, 'state: $_state -> $next');
    _state = next;
    // Before listeners hear about it, so anything awaiting an ack has already
    // been answered "connection lost" by the time a state handler reacts.
    if (next == SocketState.disconnected) _failPendingAcks();
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void dispose() {
    disconnect();
    unawaited(_stateController.close());
    unawaited(_connectFailures.close());
  }
}
