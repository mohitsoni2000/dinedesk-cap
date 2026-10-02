import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F5: one auth-coded refusal is not a verdict (a token mid-rotation, the desk
/// restarting). Only a repeat, a few seconds later, ends the reconnecting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pairing = PairingInfo(host: '10.0.0.5', port: 3000, token: 'tok');
  late SocketService socket;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService();
    container = ProviderContainer(
      overrides: [socketServiceProvider.overrideWithValue(socket)],
    );
  });

  tearDown(() => container.dispose());

  ConnectionBootstrap bootstrap() =>
      container.read(connectionBootstrapProvider.notifier);

  test('a single auth refusal does not reject the pairing', () {
    socket.debugAuthRejectionStreak = 1;
    bootstrap().debugOnConnectFailure(ConnectFailure.authRejected, pairing);
    expect(container.read(connectionBootstrapProvider),
        isNot(isA<BootstrapPairingRejected>()));
  });

  test('two in a row reject it and say so in the connection status', () {
    socket.debugAuthRejectionStreak = 2;
    bootstrap().debugOnConnectFailure(ConnectFailure.authRejected, pairing);
    expect(container.read(connectionBootstrapProvider),
        isA<BootstrapPairingRejected>());
    expect(container.read(connectionProvider).online, isFalse);
    expect(
        container.read(connectionProvider).label, contains('Pairing expired'));
  });

  test('an unreachable failure never rejects, however many there are', () {
    socket.debugAuthRejectionStreak = 0;
    for (var i = 0; i < 10; i++) {
      bootstrap().debugOnConnectFailure(ConnectFailure.unreachable, pairing);
    }
    expect(container.read(connectionBootstrapProvider),
        isNot(isA<BootstrapPairingRejected>()));
  });

  group('standing down', () {
    test('an automatic retry never resurrects a refused pairing', () {
      socket.debugAuthRejectionStreak = 2;
      bootstrap().debugSetPairing(pairing);
      bootstrap().debugOnConnectFailure(ConnectFailure.authRejected, pairing);
      expect(bootstrap().isStoodDown, isTrue);

      bootstrap().retry(automatic: true);

      expect(container.read(connectionBootstrapProvider),
          isA<BootstrapPairingRejected>(),
          reason: 'the link ladder passes automatic: true');
    });

    test('a force-disconnected device is stood down', () {
      bootstrap().debugSetPairing(pairing);
      expect(bootstrap().isStoodDown, isFalse);
      container.read(forceDisconnectedProvider.notifier).state = true;
      expect(bootstrap().isStoodDown, isTrue);
      bootstrap().retry(automatic: true);
      expect(container.read(connectionBootstrapProvider),
          isA<BootstrapIdle>());
    });

    test('signOut drops the pairing and every retry bails', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      bootstrap().debugSetPairing(pairing);
      container.read(isAuthenticatedProvider.notifier).state = true;

      final done = bootstrap().signOut();
      // Synchronously, before the first await: nothing may dial any more.
      expect(bootstrap().currentPairing, isNull);
      expect(bootstrap().isStoodDown, isTrue);
      expect(container.read(isAuthenticatedProvider), isFalse);
      bootstrap().retry();
      bootstrap().retry(automatic: true);
      expect(container.read(connectionBootstrapProvider),
          isNot(isA<BootstrapConnecting>()));

      await done;
      expect(container.read(connectionBootstrapProvider),
          isA<BootstrapNoPairing>());
    });
  });
}
