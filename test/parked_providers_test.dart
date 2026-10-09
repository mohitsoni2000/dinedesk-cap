// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:restro/data/parked_providers.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/parked_drafts_store.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:restro/widgets/root_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/parked_fixtures.dart';

/// Storage that holds what it was given but refuses every write.
class _RefusingStore extends InMemorySharedPreferencesStore {
  _RefusingStore(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

/// A bootstrap whose pairing the test can swap, the way a re-pair does:
/// the new pairing first, then a new outcome.
class _TestBootstrap extends ConnectionBootstrap {
  _TestBootstrap(super.ref);

  void repair(PairingInfo pairing) {
    debugSetPairing(pairing);
    state = BootstrapConnecting(pairing);
  }
}

PairingInfo pairingTo(String? deskId) => PairingInfo(
    host: '192.168.1.20', port: 4100, token: 'tok', deskInstanceId: deskId);

Operator operatorWith(String id) =>
    Operator(name: 'Op $id', role: 'Cashier', shift: 'Day', id: id);

/// The parked drafts as the app wires them: who is signed in, which desk the
/// phone is paired to, and the counts the shell shows on its tabs.
void main() {
  const key = 'parked_drafts_v1';

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A container as the app has it: signed in as [operatorId] on [deskId].
  ProviderContainer app({
    String? operatorId = 'op-asha',
    String? deskId = 'desk-1',
  }) {
    final container = ProviderContainer(overrides: [
      connectionBootstrapProvider.overrideWith((ref) => _TestBootstrap(ref)),
    ]);
    addTearDown(container.dispose);
    final bootstrap =
        container.read(connectionBootstrapProvider.notifier) as _TestBootstrap;
    if (deskId != null) bootstrap.debugSetPairing(pairingTo(deskId));
    if (operatorId != null) {
      container.read(operatorProvider.notifier).state =
          operatorWith(operatorId);
    }
    return container;
  }

  _TestBootstrap bootstrapOf(ProviderContainer c) =>
      c.read(connectionBootstrapProvider.notifier) as _TestBootstrap;

  int carts(ProviderContainer c) =>
      c.read(parkedCountProvider(ParkedKind.counterCart));
  int tickets(ProviderContainer c) =>
      c.read(parkedCountProvider(ParkedKind.ticketIssue));

  group('the scope: who is parking', () {
    test('is the signed-in operator on the paired desk', () {
      final c = app();
      expect(c.read(parkedScopeProvider),
          const ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-1'));
    });

    test('is nobody without an operator', () {
      expect(app(operatorId: null).read(parkedScopeProvider), isNull);
    });

    test('is nobody without a pairing', () {
      expect(app(deskId: null).read(parkedScopeProvider), isNull);
    });

    test(
        'a phone paired before desks had ids parks under the pairing\'s '
        'address instead', () async {
      const legacy = ParkedScope(
          operatorId: 'op-asha', deskInstanceId: 'pairing:192.168.1.20:4100');
      expect(app(deskId: '').read(parkedScopeProvider), legacy);

      final c = app(deskId: null);
      bootstrapOf(c).repair(
          const PairingInfo(host: '192.168.1.20', port: 4100, token: 'tok'));
      await pumpEventQueue();
      expect(c.read(parkedScopeProvider), legacy);

      final draft =
          await c.read(parkedDraftsProvider.notifier).park(cartDraft());
      expect(draft.label, 'P1', reason: 'parking is never refused for it');
      expect(draft.scope, legacy);
      expect(carts(c), 1);
    });

    test('follows the operator and the pairing as they change', () async {
      final c = app();
      final seen = <ParkedScope?>[];
      c.listen(parkedScopeProvider, (_, next) => seen.add(next));

      c.read(operatorProvider.notifier).state = operatorWith('op-ravi');
      await pumpEventQueue();
      bootstrapOf(c).repair(pairingTo('desk-2'));
      await pumpEventQueue();
      c.read(operatorProvider.notifier).state = null;
      await pumpEventQueue();

      expect(seen, <ParkedScope?>[
        const ParkedScope(operatorId: 'op-ravi', deskInstanceId: 'desk-1'),
        const ParkedScope(operatorId: 'op-ravi', deskInstanceId: 'desk-2'),
        null,
      ]);
    });

    test('does not ripple when the pairing moves but the desk is the same',
        () async {
      final c = app();
      var changes = 0;
      c.listen(parkedScopeProvider, (_, __) => changes++);
      bootstrapOf(c).repair(pairingTo('desk-1'));
      await pumpEventQueue();
      bootstrapOf(c).repair(pairingTo('desk-1'));
      await pumpEventQueue();
      expect(changes, 0);
    });
  });

  group('the parked drafts', () {
    test('park, list and count per kind for the signed-in operator', () async {
      final c = app();
      final parked = c.read(parkedDraftsProvider.notifier);

      final first = await parked.park(cartDraft());
      await parked.park(cartDraft());
      final gate = await parked.park(ticketDraft());

      expect(first.label, 'P1');
      expect(first.scope, asha, reason: 'stamped from the pairing');
      expect(carts(c), 2);
      expect(tickets(c), 1);
      expect(
          c.read(parkedByKindProvider(ParkedKind.counterCart)), hasLength(2));
      expect(c.read(parkedByKindProvider(ParkedKind.ticketIssue)).single.id,
          gate.id);
    });

    test('resuming and discarding update the lists and counts', () async {
      final c = app();
      final parked = c.read(parkedDraftsProvider.notifier);
      final a = await parked.park(cartDraft());
      final b = await parked.park(cartDraft());

      expect((await parked.resume(a.id))?.id, a.id);
      expect(await parked.resume(a.id), isNull,
          reason: 'it is gone once resumed');
      expect(carts(c), 1);
      expect(await parked.discard(b.id), isTrue);
      expect(await parked.discard(b.id), isFalse);
      expect(carts(c), 0);
    });

    test(
        'resume tells a draft that is gone from a write that failed, and a '
        'failed write keeps the draft', () async {
      final c = app();
      final parked = c.read(parkedDraftsProvider.notifier);
      final a = await parked.park(cartDraft());
      final onDisk = (await SharedPreferences.getInstance()).getString(key)!;

      SharedPreferencesStorePlatform.instance =
          _RefusingStore(<String, Object>{'flutter.$key': onDisk});
      await expectLater(
          parked.resume(a.id), throwsA(isA<ParkedDraftsException>()),
          reason: 'not a quiet null: the cashier must hear of it');
      expect(carts(c), 1, reason: 'still parked, so nothing was resumed');

      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.withData(
              <String, Object>{'flutter.$key': onDisk});
      expect((await parked.resume(a.id))?.id, a.id);
      expect(await parked.resume('pk-nowhere'), isNull,
          reason: 'not there is not an error');
      expect(carts(c), 0);
    });

    test('the cap and other store errors reach the caller', () async {
      final c = app();
      final parked = c.read(parkedDraftsProvider.notifier);
      for (var i = 0; i < ParkedDraftsStore.maxPerKind; i++) {
        await parked.park(cartDraft());
      }
      await expectLater(
          parked.park(cartDraft()), throwsA(isA<ParkedCapReached>()));
      expect(carts(c), ParkedDraftsStore.maxPerKind);
    });

    test('nothing can be parked with nobody signed in', () async {
      final c = app(operatorId: null);
      await expectLater(c.read(parkedDraftsProvider.notifier).park(cartDraft()),
          throwsA(isA<ParkedDraftsException>()));
      expect(carts(c), 0);
    });

    test(
        'a different operator signing in sees none of them, and they come '
        'back for the first', () async {
      final c = app();
      final parked = c.read(parkedDraftsProvider.notifier);
      await parked.park(cartDraft());
      await parked.park(cartDraft());
      await parked.park(ticketDraft());
      expect((carts(c), tickets(c)), (2, 1));

      c.read(operatorProvider.notifier).state = operatorWith('op-ravi');
      await pumpEventQueue();
      expect((carts(c), tickets(c)), (0, 0));
      expect(c.read(parkedDraftsProvider), isEmpty);

      await c.read(parkedDraftsProvider.notifier).park(cartDraft());
      expect(carts(c), 1);

      c.read(operatorProvider.notifier).state = operatorWith('op-asha');
      await pumpEventQueue();
      expect((carts(c), tickets(c)), (2, 1));
    });

    test('pairing the phone to another desk hides them until it is back',
        () async {
      final c = app();
      await c.read(parkedDraftsProvider.notifier).park(cartDraft());
      expect(carts(c), 1);

      bootstrapOf(c).repair(pairingTo('desk-2'));
      await pumpEventQueue();
      expect(carts(c), 0);

      bootstrapOf(c).repair(pairingTo('desk-1'));
      await pumpEventQueue();
      expect(carts(c), 1);
    });

    test('they survive the app being closed and opened again', () async {
      final first = app();
      await first.read(parkedDraftsProvider.notifier).park(cartDraft());
      await first.read(parkedDraftsProvider.notifier).park(ticketDraft());

      final second = app();
      second.read(parkedDraftsProvider);
      await pumpEventQueue();
      expect((carts(second), tickets(second)), (1, 1));
    });

    test('a fresh phone with nothing parked has no state to write', () async {
      final c = app();
      c.read(parkedDraftsProvider);
      await pumpEventQueue();
      expect(carts(c), 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(key), isFalse,
          reason: 'reading must not create the key');
    });
  });

  group('the shell badges', () {
    final qsr = QsrConfig.tryParse(<String, dynamic>{'operating_mode': 'qsr'})!;
    final gateStaff = FeatureFlags.fromMap(<String, dynamic>{
      'flag_entry_tickets': 1,
      'flag_ticket_checkin': 1,
    });

    GoRouter shellRouter() => GoRouter(
          initialLocation: '/counter',
          routes: <RouteBase>[
            StatefulShellRoute.indexedStack(
              builder: (context, state, shell) =>
                  RootShell(navigationShell: shell),
              branches: <StatefulShellBranch>[
                for (final path in ShellBranch.paths)
                  StatefulShellBranch(routes: <RouteBase>[
                    GoRoute(
                      path: path,
                      builder: (_, __) => Center(child: Text('page $path')),
                    ),
                  ]),
              ],
            ),
          ],
        );

    int badge(WidgetTester tester, String label) => tester
        .widgetList<LiquidNavIcon>(find.byType(LiquidNavIcon))
        .firstWhere((icon) => icon.item.label == label)
        .item
        .badge;

    Future<ProviderContainer> pumpShell(WidgetTester tester,
        {List<ParkedDraft> parked = const <ParkedDraft>[]}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        if (parked.isNotEmpty)
          key: envelopeJson(<Object?>[for (final d in parked) d.toJson()]),
      });
      final c = app();
      c.read(qsrConfigProvider.notifier).state = qsr;
      c.read(flagsProvider.notifier).state = gateStaff;
      final router = shellRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    List<ParkedDraft> seeded() {
      final at = DateTime.now().subtract(const Duration(minutes: 20));
      return <ParkedDraft>[
        for (var i = 1; i <= 3; i++)
          draftOf(cartDraft(), createdAt: at, seq: i),
        for (var i = 1; i <= 2; i++)
          draftOf(ticketDraft(), createdAt: at, seq: i),
        for (var i = 1; i <= 4; i++)
          draftOf(cartDraft(), scope: ravi, createdAt: at, seq: i),
        draftOf(cartDraft(), scope: ashaElsewhere, createdAt: at, seq: 1),
      ];
    }

    testWidgets(
        'the Counter tab shows the parked carts, the Gate tab the '
        'parked ticket sales', (tester) async {
      await pumpShell(tester, parked: seeded());

      expect(badge(tester, 'COUNTER'), 3);
      expect(badge(tester, 'GATE'), 2);
      expect(badge(tester, 'TABLES'), 0);
      expect(badge(tester, 'HISTORY'), 0);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets(
        'the badge goes to 0 when a different operator logs in, and '
        'returns for the first', (tester) async {
      final c = await pumpShell(tester, parked: seeded());
      expect(badge(tester, 'COUNTER'), 3);

      c.read(operatorProvider.notifier).state = operatorWith('op-new');
      await tester.pumpAndSettle();
      expect(badge(tester, 'COUNTER'), 0);
      expect(badge(tester, 'GATE'), 0);
      expect(find.byType(LiquidNavBadge), findsNothing);

      c.read(operatorProvider.notifier).state = operatorWith('op-ravi');
      await tester.pumpAndSettle();
      expect(badge(tester, 'COUNTER'), 4);
      expect(badge(tester, 'GATE'), 0);

      c.read(operatorProvider.notifier).state = operatorWith('op-asha');
      await tester.pumpAndSettle();
      expect(badge(tester, 'COUNTER'), 3);
      expect(badge(tester, 'GATE'), 2);
    });

    testWidgets('signing out clears them', (tester) async {
      final c = await pumpShell(tester, parked: seeded());
      c.read(operatorProvider.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.byType(LiquidNavBadge), findsNothing);
    });

    testWidgets('parking and resuming move the badge', (tester) async {
      final c = await pumpShell(tester);
      expect(find.byType(LiquidNavBadge), findsNothing,
          reason: 'with nothing parked the bar is exactly as before');

      final parked = c.read(parkedDraftsProvider.notifier);
      late ParkedDraft draft;
      await tester.runAsync(() async => draft = await parked.park(cartDraft()));
      await tester.pumpAndSettle();
      expect(badge(tester, 'COUNTER'), 1);

      await tester.runAsync(() => parked.resume(draft.id));
      await tester.pumpAndSettle();
      expect(find.byType(LiquidNavBadge), findsNothing);
    });
  });
}
