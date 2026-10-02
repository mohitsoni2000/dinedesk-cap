import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/kot_queue_service.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// N2: a socket the desk recovered used to stay `connected` forever. The
/// recovered branch skipped the resync (correct: nothing was missed) but never
/// marked the session verified, so the heartbeat — which only runs on a
/// verified socket — never started and the outbox never flushed.
class _RecoveredSocket extends SocketService {
  @override
  bool get wasRecovered => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pairing = PairingInfo(host: '10.0.0.5', port: 3000, token: 'tok');

  late SocketService socket;
  late ProviderContainer container;
  late List<String> sent;

  Future<ProviderContainer> build(SocketService s) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = s;
    sent = <String>[];
    socket.rawEmitOverride = (event, data, timeout) async {
      sent.add(event);
      if (event == 'operator:resync') {
        return <String, dynamic>{
          'kind': 'success',
          'sync': <String, dynamic>{},
          'operator': <String, dynamic>{'id': 'op1', 'name': 'Asha'},
        };
      }
      return <String, dynamic>{'kind': 'success'};
    };
    container = ProviderContainer(
      overrides: [socketServiceProvider.overrideWithValue(socket)],
    );
    return container;
  }

  tearDown(() => container.dispose());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test(
      'recovered + authenticated: verified, resumed, outbox flushed, no resync',
      () async {
    await build(_RecoveredSocket());
    container.read(isAuthenticatedProvider.notifier).state = true;
    // A KOT waiting from before the blip.
    final kots = container.read(kotQueueProvider);
    await kots.sendKot(socket, <String, dynamic>{'order_id': 'o1'},
        clientRequestId: 'k1');
    expect(await kots.pendingCount(), 1);
    sent.clear();

    socket.debugSetState(SocketState.connected);
    final bootstrap = container.read(connectionBootstrapProvider.notifier);
    await bootstrap.debugAttemptSilentResume(pairing);
    await settle();

    expect(socket.state, SocketState.verified,
        reason: 'without this the heartbeat never starts');
    expect(
        container.read(connectionBootstrapProvider), isA<BootstrapResumed>());
    expect(sent, isNot(contains('operator:resync')),
        reason: 'recovery replayed everything missed — no full resync');
    expect(sent, contains('kot:send'), reason: 'the queued KOT must go out');
    expect(await kots.pendingCount(), 0);
  });

  test('recovered but this process never authenticated: falls back to a resync',
      () async {
    await build(_RecoveredSocket());
    socket.debugSetState(SocketState.connected);

    await container
        .read(connectionBootstrapProvider.notifier)
        .debugAttemptSilentResume(pairing);

    expect(sent, contains('operator:resync'));
    expect(socket.state, SocketState.verified);
  });

  test('not recovered: a resync runs once and the session becomes verified',
      () async {
    await build(SocketService());
    socket.debugSetState(SocketState.connected);

    await container
        .read(connectionBootstrapProvider.notifier)
        .debugAttemptSilentResume(pairing);

    expect(sent.where((e) => e == 'operator:resync'), hasLength(1));
    expect(socket.state, SocketState.verified);
    expect(
        container.read(connectionBootstrapProvider), isA<BootstrapResumed>());
  });

  test('the sync service no longer fires its own resync on `connected`',
      () async {
    await build(SocketService());
    container.read(isAuthenticatedProvider.notifier).state = true;
    // listeners registered, as after a first successful resume
    container.read(syncServiceProvider).registerListeners();

    socket.debugSetState(SocketState.connected);
    await settle();

    expect(sent, isNot(contains('operator:resync')),
        reason: 'the bootstrap is the single owner of the post-connect resync');
  });
}
