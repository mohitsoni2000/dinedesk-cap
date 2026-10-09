import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/floor_cache.dart';
import 'package:restro/services/offline_session.dart';
import 'package:restro/services/offline_snapshot.dart';
import 'package:restro/services/biometric_service.dart';
import 'package:restro/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cold start with the desk unreachable: the boot path that opens the cached
/// session instead of the failure screen, and the guards around it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pairing = PairingInfo(
      host: '10.0.0.5', port: 3000, token: 'tok', deskInstanceId: 'desk-1');

  late Directory dir;
  late OfflineSnapshotStore store;
  late ProviderContainer container;

  OfflineSession session({
    Duration ago = const Duration(minutes: 5),
    int grace = 30,
    String? desk = 'desk-1',
  }) =>
      OfflineSession(
        operatorId: 'op1',
        name: 'Asha',
        role: 'Waiter',
        shift: 'Day',
        employeeId: 'E7',
        deskInstanceId: desk,
        lastSeenAt: DateTime.now().subtract(ago),
        pinGraceMinutes: grace,
      );

  Future<void> arrange({
    OfflineSession? stored,
    bool withSnapshot = true,
    Map<String, String> secure = const <String, String>{},
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      if (stored != null) 'offline_session_v1': stored.encode(),
      ...secure,
    });
    dir = await Directory.systemTemp.createTemp('resume_test');
    store = OfflineSnapshotStore(directory: dir);
    if (withSnapshot) {
      await store.save(OfflineSnapshot(
        savedAt: DateTime.now(),
        deskInstanceId: 'desk-1',
        restaurantInfo: const {'name': 'Spice Hub'},
        menu: const {
          'categories': [
            {'id': 'c1', 'name': 'Starters', 'type': 'food'}
          ],
          'items': [
            {
              'id': 'i1',
              'name': 'Tikka',
              'category_id': 'c1',
              'price': 100,
              'is_veg': 1
            }
          ],
        },
        menuVersion: 'mv-1',
        sessionPolicy: const {'pin_grace_minutes': 30},
      ));
    }
    await FloorCache.save(const FloorCacheSnapshot(
      floorNames: <String>['Ground'],
      tables: <RestaurantTable>[
        RestaurantTable(
            id: 'T1',
            serverId: 't1',
            seats: 4,
            floor: 'Ground',
            state: TableState.free),
      ],
      rooms: <RestaurantRoom>[],
    ));
    container = ProviderContainer(
      overrides: [offlineSnapshotStoreProvider.overrideWithValue(store)],
    );
    container
        .read(connectionBootstrapProvider.notifier)
        .debugSetPairing(pairing);
  }

  Operator op1() =>
      const Operator(name: 'Asha', role: 'Waiter', shift: 'Day', id: 'op1');

  tearDown(() async {
    container.dispose();
    // A live sync saves the snapshot fire-and-forget; let that write land
    // before the folder is deleted under it.
    await store.idle;
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  ConnectionBootstrap bootstrap() =>
      container.read(connectionBootstrapProvider.notifier);

  test('inside the grace window the app opens on the cached session', () async {
    await arrange(stored: session());
    expect(await bootstrap().offlineResumeEligible(), isTrue);

    expect(await bootstrap().resumeOffline(), isTrue);

    expect(container.read(connectionBootstrapProvider),
        isA<BootstrapOfflineResumed>());
    expect(container.read(isAuthenticatedProvider), isTrue);
    final op = container.read(operatorProvider)!;
    expect(op.id, 'op1');
    expect(op.name, 'Asha');
    expect(op.employeeId, 'E7');
    expect(container.read(offlineResumedProvider), isTrue);
    expect(container.read(menuProvider).map((i) => i.id), ['i1']);
    expect(container.read(tablesProvider).single.id, 'T1',
        reason: 'floors/tables come from the FloorCache');
    expect(container.read(floorNamesProvider), ['Ground']);
    expect(container.read(isFloorDataStaleProvider), isTrue);
    expect(container.read(connectionProvider).online, isFalse,
        reason: 'never claims to be online');
  });

  test('past the grace window it refuses and leaves the PIN screen', () async {
    await arrange(stored: session(ago: const Duration(minutes: 45)));
    expect(await bootstrap().offlineResumeEligible(), isFalse);
    expect(await bootstrap().resumeOffline(), isFalse);
    expect(container.read(isAuthenticatedProvider), isFalse);
    expect(container.read(operatorProvider), isNull);
    expect(container.read(menuProvider), isEmpty);
  });

  test('a grace of 0 (PIN on every reconnect) never resumes', () async {
    await arrange(stored: session(grace: 0, ago: Duration.zero));
    expect(await bootstrap().resumeOffline(), isFalse);
  });

  test('no stored session, no resume', () async {
    await arrange();
    expect(await bootstrap().offlineResumeEligible(), isFalse);
    expect(await bootstrap().resumeOffline(), isFalse);
  });

  test('a session from another desk does not resume', () async {
    await arrange(stored: session(desk: 'desk-2'));
    expect(await bootstrap().resumeOffline(), isFalse);
    expect(container.read(isAuthenticatedProvider), isFalse);
  });

  test('no snapshot, no resume (and nothing half-applied)', () async {
    await arrange(stored: session(), withSnapshot: false);
    expect(await bootstrap().resumeOffline(), isFalse);
    expect(container.read(isAuthenticatedProvider), isFalse);
    expect(container.read(operatorProvider), isNull);
  });

  test('a snapshot of another desk is not shown', () async {
    await arrange(stored: session());
    const other = PairingInfo(
        host: '10.0.0.5', port: 3000, token: 'tok', deskInstanceId: 'desk-2');
    bootstrap().debugSetPairing(other);
    expect(await bootstrap().resumeOffline(), isFalse);
    expect(container.read(menuProvider), isEmpty);
  });

  test('a demo pairing never resumes offline', () async {
    await arrange(stored: session());
    bootstrap().debugSetPairing(
        const PairingInfo(host: 'localhost', port: 8080, token: 'demo-token'));
    expect(await bootstrap().resumeOffline(), isFalse);
  });

  test(
      'declining the PIN prompt on reconnect sends an offline-resumed session '
      'back to the PIN screen', () async {
    await arrange(stored: session());
    await bootstrap().resumeOffline();
    expect(container.read(isAuthenticatedProvider), isTrue);

    // No navigator in a unit test: the prompt resolves "not entered".
    final entered =
        await container.read(syncServiceProvider).handleReauthRequired();

    expect(entered, isFalse);
    expect(container.read(isAuthenticatedProvider), isFalse);
    expect(container.read(offlineResumedProvider), isFalse);
  });

  test(
      'declining the PIN prompt on a LIVE authenticated session also returns '
      'to the PIN screen (no connected-but-unverified limbo)', () async {
    await arrange(stored: session());
    container.read(isAuthenticatedProvider.notifier).state = true;
    expect(container.read(offlineResumedProvider), isFalse);

    final entered =
        await container.read(syncServiceProvider).handleReauthRequired();

    expect(entered, isFalse);
    expect(container.read(isAuthenticatedProvider), isFalse,
        reason: 'the router ignores NeedsAuth for an authenticated app');
  });

  group('the biometric prompt', () {
    test('never fires for a session that is already authenticated', () async {
      await arrange(stored: session());
      final bio = _SpyBiometric();
      container.dispose();
      container = ProviderContainer(overrides: [
        offlineSnapshotStoreProvider.overrideWithValue(store),
        biometricServiceProvider.overrideWithValue(bio),
      ]);
      bootstrap().debugSetPairing(pairing);
      container.read(isAuthenticatedProvider.notifier).state = true;

      expect(await bootstrap().resumeOffline(), isFalse);
      expect(bio.unlocks, 0);
      expect(bio.enabledChecks, 0);
    });

    test('never fires once a live sync has landed', () async {
      await arrange(stored: session());
      final bio = _SpyBiometric();
      container.dispose();
      container = ProviderContainer(overrides: [
        offlineSnapshotStoreProvider.overrideWithValue(store),
        biometricServiceProvider.overrideWithValue(bio),
      ]);
      bootstrap().debugSetPairing(pairing);
      await container
          .read(syncServiceProvider)
          .applyInitialSync(<String, dynamic>{'tables': <Object>[]});

      expect(await bootstrap().resumeOffline(), isFalse);
      expect(bio.unlocks, 0);
      // Let the snapshot write the live sync scheduled land before teardown
      // deletes its directory.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    test('still guards a genuine cold start', () async {
      await arrange(stored: session());
      final bio = _SpyBiometric(enabled: true, passes: true);
      container.dispose();
      container = ProviderContainer(overrides: [
        offlineSnapshotStoreProvider.overrideWithValue(store),
        biometricServiceProvider.overrideWithValue(bio),
      ]);
      bootstrap().debugSetPairing(pairing);

      expect(await bootstrap().resumeOffline(), isTrue);
      expect(bio.unlocks, 1);
    });
  });

  test('a live sync ends the offline-resumed state', () async {
    await arrange(stored: session());
    await bootstrap().resumeOffline();
    await container
        .read(syncServiceProvider)
        .applyInitialSync(<String, dynamic>{'tables': <Object>[]});
    expect(container.read(offlineResumedProvider), isFalse);
  });

  group('writing and clearing the offline session', () {
    test('verified: the session is written with the desk\'s grace', () async {
      await arrange();
      container.read(isAuthenticatedProvider.notifier).state = true;
      final sync = container.read(syncServiceProvider);
      await sync.applyInitialSync(<String, dynamic>{
        'tables': <Object>[],
        'session_policy': {'pin_grace_minutes': 40},
      });
      container.read(operatorProvider.notifier).state =
          const Operator(name: 'Asha', role: 'Waiter', shift: 'Day', id: 'op1');

      await sync.persistOfflineSession(force: true);

      final stored = (await SessionService().getOfflineSession())!;
      expect(stored.operatorId, 'op1');
      expect(stored.pinGraceMinutes, 40);
      expect(stored.deskInstanceId, 'desk-1');
      expect(
          DateTime.now().difference(stored.lastSeenAt).inSeconds, lessThan(5));
      expect(stored.encode().toLowerCase(), isNot(contains('pin"')),
          reason: 'no PIN, no PIN hash');
    });

    test('lastSeenAt refreshes at most once a minute unless forced', () async {
      await arrange();
      container.read(isAuthenticatedProvider.notifier).state = true;
      final sync = container.read(syncServiceProvider);
      container.read(operatorProvider.notifier).state =
          const Operator(name: 'Asha', role: 'Waiter', shift: 'Day', id: 'op1');
      await sync.persistOfflineSession(force: true);
      final first = (await SessionService().getOfflineSession())!.lastSeenAt;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sync.persistOfflineSession(); // throttled
      expect((await SessionService().getOfflineSession())!.lastSeenAt, first);

      await sync.persistOfflineSession(force: true);
      expect(
          (await SessionService().getOfflineSession())!
              .lastSeenAt
              .isAfter(first),
          isTrue);
    });

    test('an offline-resumed session never extends its own window', () async {
      final old = session(ago: const Duration(minutes: 20));
      await arrange(stored: old);
      await bootstrap().resumeOffline();
      await container
          .read(syncServiceProvider)
          .persistOfflineSession(force: true);
      final stored = (await SessionService().getOfflineSession())!;
      expect(stored.lastSeenAt, old.lastSeenAt.toUtc());
    });

    test('a signed-out (unauthenticated) session never writes one', () async {
      await arrange();
      final sync = container.read(syncServiceProvider);
      container.read(operatorProvider.notifier).state = op1();
      // isAuthenticated stays false: the supervisor's disconnect-edge touch
      // after a sign-out must not re-create what the sign-out cleared.
      await sync.persistOfflineSession(force: true);
      expect(await SessionService().getOfflineSession(), isNull);
    });

    test(
        'force:disconnect clears the offline session and the supervisor\'s '
        'follow-up touch cannot re-write it', () async {
      await arrange(stored: session());
      final sync = container.read(syncServiceProvider);
      container.read(operatorProvider.notifier).state = op1();
      container.read(isAuthenticatedProvider.notifier).state = true;

      await sync.debugForceDisconnect('token_revoked');

      expect(await SessionService().getOfflineSession(), isNull);
      expect(container.read(isAuthenticatedProvider), isFalse);
      expect(container.read(operatorProvider), isNull);
      expect(container.read(forceDisconnectedProvider), isTrue);

      // What ConnectionSupervisor does on the disconnect edge it just caused.
      sync.touchOfflineSession(force: true);
      await sync.persistOfflineSession(force: true);
      expect(await SessionService().getOfflineSession(), isNull);
    });

    test('a new verified session lifts the revocation latch', () async {
      await arrange();
      final sync = container.read(syncServiceProvider);
      container.read(operatorProvider.notifier).state = op1();
      await sync.debugForceDisconnect('token_revoked');
      // Re-paired and verified again.
      container.read(forceDisconnectedProvider.notifier).state = false;
      container.read(operatorProvider.notifier).state = op1();
      sync.completeResume();
      await sync.persistOfflineSession(force: true);
      expect(await SessionService().getOfflineSession(), isNotNull);
    });

    test('clearPairing / clearOfflineSession end it', () async {
      await arrange(stored: session());
      expect(await SessionService().getOfflineSession(), isNotNull);
      await SessionService().clearOfflineSession();
      expect(await SessionService().getOfflineSession(), isNull);
    });
  });
}

class _SpyBiometric extends BiometricService {
  _SpyBiometric({this.enabled = false, this.passes = false});

  final bool enabled;
  final bool passes;
  int unlocks = 0;
  int enabledChecks = 0;

  @override
  Future<bool> isEnabled() async {
    enabledChecks++;
    return enabled;
  }

  @override
  Future<String?> unlock() async {
    unlocks++;
    return passes ? '1234' : null;
  }
}
