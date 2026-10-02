import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/offline_guard.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `isDeskOffline` / `requireDesk` are the one place that decides "the desk
/// must confirm this", now that `requirePinIfNeeded` is purely about PINs.
void main() {
  late SocketService socket;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService();
  });

  tearDown(() => socket.dispose());

  Future<({WidgetRef ref, BuildContext context, ProviderContainer container})>
      pump(WidgetTester tester, {PairingInfo? pairing}) async {
    late WidgetRef capturedRef;
    late BuildContext capturedContext;
    final container = ProviderContainer(
      overrides: [socketServiceProvider.overrideWithValue(socket)],
    );
    addTearDown(container.dispose);
    if (pairing != null) {
      container
          .read(connectionBootstrapProvider.notifier)
          .debugSetPairing(pairing);
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            capturedRef = ref;
            capturedContext = context;
            return const SizedBox();
          }),
        ),
      ),
    ));
    return (ref: capturedRef, context: capturedContext, container: container);
  }

  testWidgets('a verified socket is not offline and requireDesk passes',
      (tester) async {
    socket.debugSetState(SocketState.verified);
    final h = await pump(tester);
    expect(isDeskOffline(h.ref), isFalse);
    expect(requireDesk(h.context, h.ref), isTrue);
  });

  testWidgets(
      'anything short of verified is offline: requireDesk refuses and says why',
      (tester) async {
    for (final s in <SocketState>[
      SocketState.disconnected,
      SocketState.connecting,
      SocketState.connected,
    ]) {
      socket.debugSetState(s);
      final h = await pump(tester);
      expect(isDeskOffline(h.ref), isTrue, reason: '$s');
      expect(requireDesk(h.context, h.ref), isFalse, reason: '$s');
      await tester.pump();
      expect(find.text(kNeedsDeskMessage), findsOneWidget, reason: '$s');
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }
  });

  testWidgets('a demo pairing has no real socket and is never offline',
      (tester) async {
    final h = await pump(tester,
        pairing: const PairingInfo(
            host: 'localhost', port: 1, token: 'demo-token'));
    expect(isDeskOffline(h.ref), isFalse);
    expect(requireDesk(h.context, h.ref), isTrue);
  });
}
