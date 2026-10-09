import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/router.dart';
import 'package:restro/screens/tables_screen.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:restro/widgets/root_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The bottom bar / side rail: which tabs show for the desk's mode and the
/// user's rights, the home tab first, and the count badge on a tab.
void main() {
  final qsr = QsrConfig.tryParse(<String, dynamic>{'operating_mode': 'qsr'})!;

  group('shellTabsFor', () {
    test('restaurant mode is the old bar: Tables first, no Counter or Gate',
        () {
      expect(
          shellTabsFor(
              home: '/tables', isQsr: false, rooms: false, gate: false),
          <int>[
            ShellBranch.tables,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
      expect(
          shellTabsFor(home: '/tables', isQsr: false, rooms: true, gate: false),
          <int>[
            ShellBranch.tables,
            ShellBranch.rooms,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
    });

    test('QSR mode puts the Counter first and keeps Tables right after it', () {
      // Owner decision 6: QSR is hybrid; the floor stays reachable.
      expect(
          shellTabsFor(home: '/counter', isQsr: true, rooms: true, gate: true),
          <int>[
            ShellBranch.counter,
            ShellBranch.tables,
            ShellBranch.rooms,
            ShellBranch.gate,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
      expect(
          shellTabsFor(
              home: '/counter', isQsr: true, rooms: false, gate: false),
          <int>[
            ShellBranch.counter,
            ShellBranch.tables,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
    });

    test('a QSR user who pinned Tables gets Tables first, then the Counter',
        () {
      expect(
          shellTabsFor(home: '/tables', isQsr: true, rooms: false, gate: false),
          <int>[
            ShellBranch.tables,
            ShellBranch.counter,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
    });

    test('the home tab always comes first', () {
      expect(
          shellTabsFor(home: '/gate', isQsr: false, rooms: true, gate: true),
          <int>[
            ShellBranch.gate,
            ShellBranch.tables,
            ShellBranch.rooms,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
      expect(
          shellTabsFor(home: '/gate', isQsr: true, rooms: false, gate: true),
          <int>[
            ShellBranch.gate,
            ShellBranch.counter,
            ShellBranch.tables,
            ShellBranch.history,
            ShellBranch.profile,
            ShellBranch.settings,
          ]);
    });

    test('ShellBranch.ofHome maps each home route to its branch', () {
      expect(ShellBranch.ofHome('/tables'), ShellBranch.tables);
      expect(ShellBranch.ofHome('/counter'), ShellBranch.counter);
      expect(ShellBranch.ofHome('/gate'), ShellBranch.gate);
      for (var i = 0; i < ShellBranch.paths.length; i++) {
        expect(ShellBranch.paths[i].startsWith('/'), isTrue);
      }
    });
  });

  test('the router\'s shell branches sit at the ShellBranch indices', () {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final shell = container
        .read(routerProvider)
        .configuration
        .routes
        .whereType<StatefulShellRoute>()
        .single;
    expect(<String>[
      for (final branch in shell.branches)
        (branch.routes.first as GoRoute).path,
    ], ShellBranch.paths,
        reason: 'new branches are appended; existing indices never move');
    expect(ShellBranch.paths.indexOf('/gate'), 5);
    expect(ShellBranch.paths.indexOf('/counter'), 6);
  });

  group('RootShell', () {
    late ProviderContainer container;

    GoRouter testRouter(String initial) => GoRouter(
          initialLocation: initial,
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

    Future<GoRouter> pumpShell(
      WidgetTester tester, {
      String initial = '/tables',
      FeatureFlags flags = const FeatureFlags(),
      QsrConfig qsrConfig = QsrConfig.restaurant,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(flagsProvider.notifier).state = flags;
      container.read(qsrConfigProvider.notifier).state = qsrConfig;
      final router = testRouter(initial);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ));
      await tester.pumpAndSettle();
      return router;
    }

    double x(WidgetTester tester, String label) =>
        tester.getCenter(find.text(label)).dx;

    testWidgets('restaurant mode shows exactly the old tabs', (tester) async {
      await pumpShell(tester);
      for (final label in <String>[
        'TABLES',
        'HISTORY',
        'PROFILE',
        'SETTINGS'
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final label in <String>['ROOMS', 'COUNTER', 'GATE']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.text('page /tables'), findsOneWidget);
    });

    testWidgets('QSR mode: Counter first, then Tables; Gate for gate staff',
        (tester) async {
      await pumpShell(
        tester,
        initial: '/counter',
        qsrConfig: qsr,
        flags: FeatureFlags.fromMap(<String, dynamic>{
          'flag_rooms': 1,
          'flag_entry_tickets': 1,
          'flag_ticket_checkin': 1,
        }),
      );
      expect(x(tester, 'COUNTER'), lessThan(x(tester, 'TABLES')));
      expect(x(tester, 'TABLES'), lessThan(x(tester, 'ROOMS')));
      expect(x(tester, 'ROOMS'), lessThan(x(tester, 'GATE')));
      expect(x(tester, 'GATE'), lessThan(x(tester, 'HISTORY')));
      expect(find.text('page /counter'), findsOneWidget);
    });

    testWidgets('seven tabs still lay out on a small phone', (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpShell(
        tester,
        initial: '/counter',
        qsrConfig: qsr,
        flags: FeatureFlags.fromMap(<String, dynamic>{
          'flag_rooms': 1,
          'flag_entry_tickets': 1,
          'flag_ticket_checkin': 1,
        }),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(LiquidNavIcon), findsNWidgets(7));
    });

    testWidgets('a gate-first user gets the Gate tab first', (tester) async {
      await pumpShell(
        tester,
        initial: '/gate',
        flags: FeatureFlags.fromMap(<String, dynamic>{
          'flag_entry_tickets': 1,
          'flag_ticket_issue': 1,
          'flag_collect_payment': 0,
          'flag_generate_bill': 0,
        }),
      );
      expect(x(tester, 'GATE'), lessThan(x(tester, 'TABLES')));
    });

    testWidgets('tapping a tab opens its branch', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.text('HISTORY'));
      await tester.pumpAndSettle();
      expect(find.text('page /history'), findsOneWidget);
    });

    testWidgets('QSR mode turned on keeps an open Tables tab where it is',
        (tester) async {
      final router = await pumpShell(tester);
      container.read(qsrConfigProvider.notifier).state = qsr;
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/tables');
      expect(find.text('page /tables'), findsOneWidget);
      expect(x(tester, 'COUNTER'), lessThan(x(tester, 'TABLES')));
    });

    testWidgets('when the open tab goes away the shell falls back to home',
        (tester) async {
      final router =
          await pumpShell(tester, initial: '/counter', qsrConfig: qsr);
      expect(find.text('page /counter'), findsOneWidget);

      container.read(qsrConfigProvider.notifier).state = QsrConfig.restaurant;
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/tables');
      expect(find.text('page /tables'), findsOneWidget);
      expect(find.text('COUNTER'), findsNothing);
    });

    testWidgets('rooms switched off while on Rooms still falls back',
        (tester) async {
      final router = await pumpShell(
        tester,
        initial: '/rooms',
        flags: FeatureFlags.fromMap(<String, dynamic>{'flag_rooms': 1}),
      );
      container.read(flagsProvider.notifier).state = const FeatureFlags();
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/tables');
    });
  });

  group('the real router', () {
    late ProviderContainer container;
    late GoRouter router;

    Future<void> pumpApp(
      WidgetTester tester, {
      required QsrConfig qsrConfig,
      required FeatureFlags flags,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: true, label: 'Connected');
      container.read(flagsProvider.notifier).state = flags;
      container.read(qsrConfigProvider.notifier).state = qsrConfig;
      container.read(isAuthenticatedProvider.notifier).state = true;
      router = container.read(routerProvider);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ));
      await tester.pumpAndSettle();
    }

    String path() => router.routerDelegate.currentConfiguration.uri.path;

    final gateFirst = FeatureFlags.fromMap(<String, dynamic>{
      'flag_entry_tickets': 1,
      'flag_ticket_issue': 1,
      'flag_ticket_checkin': 1,
      'flag_collect_payment': 0,
      'flag_generate_bill': 0,
    });
    final gateAndTill = FeatureFlags.fromMap(<String, dynamic>{
      'flag_entry_tickets': 1,
      'flag_ticket_issue': 1,
      'flag_collect_payment': 1,
    });

    testWidgets(
        'a signed-in QSR user lands on the Counter, Tables one tab away',
        (tester) async {
      await pumpApp(tester, qsrConfig: qsr, flags: const FeatureFlags());
      expect(path(), '/counter');
      expect(find.text('TABLES'), findsOneWidget);
      // The router sent the PIN straight to the Counter: Tables was never
      // built on the way (a '/tables' landing would have built it).
      expect(find.byType(TablesScreen, skipOffstage: false), findsNothing);
    });

    testWidgets('losing gate rights while on the Gate goes home',
        (tester) async {
      await pumpApp(tester, qsrConfig: qsr, flags: gateAndTill);
      router.go('/gate');
      await tester.pumpAndSettle();
      expect(path(), '/gate');

      container.read(flagsProvider.notifier).state = const FeatureFlags();
      await tester.pumpAndSettle();
      expect(path(), '/counter');
    });

    testWidgets('QSR mode switched off while on the Counter goes home',
        (tester) async {
      await pumpApp(tester, qsrConfig: qsr, flags: gateFirst);
      expect(path(), '/gate', reason: 'gate-first even on a QSR desk');
      router.go('/counter');
      await tester.pumpAndSettle();
      expect(path(), '/counter');

      container.read(qsrConfigProvider.notifier).state = QsrConfig.restaurant;
      await tester.pumpAndSettle();
      expect(path(), '/gate');
    });
  });

  group('nav badge', () {
    Widget host(Widget child) => MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
              body: Align(alignment: Alignment.bottomCenter, child: child)),
        );

    testWidgets('a count shows on the tab, zero shows nothing', (tester) async {
      await tester.pumpWidget(host(LiquidBottomNav(
        currentIndex: 0,
        onTap: (_) {},
        items: const <LiquidNavItem>[
          LiquidNavItem(
              icon: Icons.storefront_outlined, label: 'COUNTER', badge: 3),
          LiquidNavItem(icon: Icons.receipt_long, label: 'HISTORY'),
        ],
      )));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.byType(LiquidNavBadge), findsOneWidget);
    });

    testWidgets('a big count is capped at 99+', (tester) async {
      await tester.pumpWidget(host(const LiquidNavIcon(
        item: LiquidNavItem(
            icon: Icons.confirmation_number_outlined,
            label: 'GATE',
            badge: 140),
        size: 22,
        color: Colors.black,
      )));
      expect(find.text('99+'), findsOneWidget);
    });

    test('defaults to no badge', () {
      const item =
          LiquidNavItem(icon: Icons.settings_outlined, label: 'SETTINGS');
      expect(item.badge, 0);
    });
  });
}
