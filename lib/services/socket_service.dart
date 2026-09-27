import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:socket_io_client/socket_io_client.dart' as io;

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
  /// a zombie that no socket.io event will ever revive. Rebuild the engine.
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

  /// How the measured link widens the timeouts below. Defaults to the fixed
  /// behaviour this class had before; [ConnectionSupervisor] swaps in an
  /// adaptive one once it is watching. Kept as an injected seam so the socket
  /// stays a transport and doesn't grow a second job.
  TimeoutPolicy timeoutPolicy = const FixedTimeoutPolicy();

  /// Fired with the round-trip time of every ack that came back cleanly, so a
  /// listener can build a link estimate from real traffic instead of only from
  /// dedicated probes.
  void Function(Duration)? onAckRtt;

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

  /// Base handshake timeout, before [timeoutPolicy] widens it.
  static const Duration connectTimeout = Duration(seconds: 3);

  Stream<SocketState> get stateStream => _stateController.stream;
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

  /// Rebuilds the engine under the *same* io.Socket, for a socket we have
  /// concluded is dead while socket.io still reports it connected (an ack
  /// timed out, or the supervisor's heartbeat went silent).
  ///
  /// Flipping [state] alone — what this class used to do — left a zombie: the
  /// io.Socket never emits another connect/disconnect, so every later emit
  /// was refused at the `_emitAck` gate with "Connection lost", and
  /// [reconnectIfNeeded]'s `connect()` returned immediately because socket.io
  /// still thought it was connected. On the PIN screen nothing else ever
  /// reconnects (ConnectionBootstrap only watches for drops once resumed), so
  /// the operator was stuck on "Connection lost" for good.
  ///
  /// A client-side `disconnect()` closes the engine and stops socket.io's own
  /// reconnect loop; `connect()` then opens exactly one new engine. Strictly
  /// sequential — never two engines, never two CONNECTs for this token.
  /// Listeners registered through [on] stay attached (same io.Socket).
  void _forceReconnect(String why) {
    final socket = _socket;
    if (socket == null) return;
    logD(_tag, 'forcing a fresh engine: $why');
    _setState(SocketState.disconnected);
    socket.disconnect();
    socket.connect();
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
          .setAuth(<String, dynamic>{'token': token})
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
      markDeadOnTimeout: true,
    );
  }

  /// [emitAck] without the "a timeout means the link is dead" conclusion.
  ///
  /// Needed for liveness probing, where a missing ack is genuinely ambiguous:
  /// a desk build older than the event being probed for will never answer it,
  /// and letting that tear down a perfectly healthy session would be a
  /// self-inflicted outage on every un-upgraded desk. The caller decides what
  /// silence means and calls [markDead] if it concludes the socket is gone.
  Future<Map<String, dynamic>> emitAckProbe(
    String event,
    Map<String, dynamic> data, {
    Duration timeout = ackTimeout,
  }) =>
      _emitAck(event, data, timeout, markDeadOnTimeout: false);

  Future<Map<String, dynamic>> _emitAck(
    String event,
    Map<String, dynamic> data,
    Duration effectiveTimeout, {
    required bool markDeadOnTimeout,
  }) async {
    final socket = _socket;
    logD(_tag, '-> $event ${summarizeShape(data)}');
    if (socket == null || _state == SocketState.disconnected) {
      return _errorAck(AckCode.connectionLost, 'Connection lost');
    }
    final stopwatch = Stopwatch()..start();
    try {
      final raw = await socket
          .timeout(effectiveTimeout.inMilliseconds)
          .emitWithAckAsync(event, data);
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
        // A real ack timeout is definitive proof the transport isn't
        // answering, even if the underlying io.Socket (or Android, after
        // resuming a suspended isolate) still thinks it's connected. Flip
        // `_state` here so every caller that gates on it — reconnectIfNeeded,
        // ConnectionBootstrap, SyncService's reconnect listener — sees the
        // truth instead of a stale "verified" that never self-corrects.
        // Not while a verify is in flight: its sync-sized reply holds up every
        // ack queued behind it, so an unrelated timeout then is evidence of a
        // busy link, not a dead one — and flipping state would make the
        // bootstrap/resume paths replace the socket carrying the PIN.
        if (markDeadOnTimeout && !isVerifyInFlight) {
          _setState(SocketState.disconnected);
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
    logD(_tag, 'marked dead by supervisor');
    _setState(SocketState.disconnected);
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

  /// Strips the per-packet offset socket.io appends to every broadcast once the
  /// desk enables `connectionStateRecovery`.
  ///
  /// With recovery on, the server sends `[payload, offsetString]` rather than
  /// `[payload]`, and socket_io_client hands a multi-arg event to the listener
  /// as a List (`socket.dart` → `emitEvent`, the `args.length > 2` branch).
  /// Every handler in `sync_service.dart` expects the payload Map, so without
  /// this the entire live-update layer would go quiet the moment recovery was
  /// switched on — silently, since `asMap` on a List just yields nothing.
  ///
  /// The shape test is deliberately narrow: exactly two elements, a Map first
  /// and a String last. No broadcast this app consumes is itself a two-element
  /// list, so nothing legitimate matches.
  static dynamic stripRecoveryOffset(dynamic data) {
    if (data is List &&
        data.length == 2 &&
        data.first is Map &&
        data.last is String) {
      return data.first;
    }
    return data;
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
