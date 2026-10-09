import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/home_route.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/screens/order_success_screen.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets the start-screen notifier's SharedPreferences restore land.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Where the app lands (after the PIN, after an order, on "Back to …") and
/// which shell routes are open. Restaurant mode with no ticket flags must
/// stay exactly as before: always /tables.
void main() {
  const restaurant = QsrConfig.restaurant;
  final qsr = QsrConfig.tryParse(<String, dynamic>{'operating_mode': 'qsr'})!;

  /// [issue] / [checkin] are the two gate rights; either one turns the
  /// entry-ticket module on.
  FeatureFlags flags({
    bool issue = false,
    bool checkin = false,
    bool collectPayment = true,
    bool generateBill = true,
    bool rooms = false,
  }) =>
      FeatureFlags.fromMap(<String, dynamic>{
        'flag_entry_tickets': issue || checkin,
        'flag_ticket_issue': issue,
        'flag_ticket_checkin': checkin,
        'flag_collect_payment': collectPayment,
        'flag_generate_bill': generateBill,
        'flag_rooms': rooms,
      });

  // The desk's default waiter once a venue turns entry tickets on: may check
  // guests in, may not sell tickets, bill or take money.
  final defaultWaiter =
      flags(checkin: true, collectPayment: false, generateBill: false);

  group('homeRouteFor — auto', () {
    test('restaurant mode without tickets is always Tables', () {
      expect(homeRouteFor(flags: const FeatureFlags(), qsr: restaurant),
          '/tables');
      expect(homeRouteFor(flags: flags(), qsr: restaurant), '/tables');
      expect(
          homeRouteFor(
              flags: flags(collectPayment: false, generateBill: false),
              qsr: restaurant),
          '/tables',
          reason: 'no gate rights: a waiter stays on Tables');
    });

    test('QSR mode lands on the Counter', () {
      expect(homeRouteFor(flags: flags(), qsr: qsr), '/counter');
    });

    test('a ticket seller who cannot bill or take money is gate-first', () {
      final seller = flags(
          issue: true,
          checkin: true,
          collectPayment: false,
          generateBill: false);
      expect(homeRouteFor(flags: seller, qsr: restaurant), '/gate');
      expect(homeRouteFor(flags: seller, qsr: qsr), '/gate');
      expect(
          homeRouteFor(
              flags: flags(
                  issue: true, collectPayment: false, generateBill: false),
              qsr: restaurant),
          '/gate',
          reason: 'issue alone is enough');
    });

    test('a default waiter keeps Tables when entry tickets go on', () {
      expect(defaultWaiter.hasGate, isTrue,
          reason: 'check-in still opens the Gate tab');
      expect(homeRouteFor(flags: defaultWaiter, qsr: restaurant), '/tables');
      expect(homeLabelFor(homeRouteFor(flags: defaultWaiter, qsr: restaurant)),
          'Tables');
      expect(homeRouteFor(flags: defaultWaiter, qsr: qsr), '/counter');
    });

    test('a ticket seller who can also bill or take money keeps the floor home',
        () {
      expect(
          homeRouteFor(
              flags: flags(
                  issue: true,
                  checkin: true,
                  collectPayment: true,
                  generateBill: false),
              qsr: restaurant),
          '/tables');
      expect(
          homeRouteFor(
              flags: flags(
                  issue: true,
                  checkin: true,
                  collectPayment: false,
                  generateBill: true),
              qsr: restaurant),
          '/tables');
      expect(homeRouteFor(flags: flags(issue: true, checkin: true), qsr: qsr),
          '/counter');
    });

    test('entry tickets without issue or check-in rights is no gate', () {
      final noRights = FeatureFlags.fromMap(<String, dynamic>{
        'flag_entry_tickets': 1,
        'flag_collect_payment': 0,
        'flag_generate_bill': 0,
      });
      expect(homeRouteFor(flags: noRights, qsr: restaurant), '/tables');
    });
  });

  group('homeRouteFor — start-screen preference', () {
    test('is honoured when that screen is available', () {
      expect(
          homeRouteFor(
              flags: flags(checkin: true),
              qsr: restaurant,
              pref: StartScreen.gate),
          '/gate',
          reason: 'a scan-only user may pin the Gate');
      final seller =
          flags(issue: true, collectPayment: false, generateBill: false);
      expect(
          homeRouteFor(
              flags: seller, qsr: restaurant, pref: StartScreen.tables),
          '/tables');
      expect(homeRouteFor(flags: seller, qsr: qsr, pref: StartScreen.counter),
          '/counter');
    });

    test('a QSR user who pinned Tables lands on Tables', () {
      expect(homeRouteFor(flags: flags(), qsr: qsr), '/counter',
          reason: 'the automatic home stays the Counter');
      expect(homeRouteFor(flags: flags(), qsr: qsr, pref: StartScreen.tables),
          '/tables');
    });

    test('is ignored when that screen is not available', () {
      expect(
          homeRouteFor(
              flags: flags(), qsr: restaurant, pref: StartScreen.counter),
          '/tables');
      expect(
          homeRouteFor(flags: flags(), qsr: restaurant, pref: StartScreen.gate),
          '/tables');
    });
  });

  group('routeGuard', () {
    test('restaurant mode: Counter is closed, Tables open', () {
      final f = flags();
      expect(routeGuard(location: '/counter', flags: f, qsr: restaurant),
          '/tables');
      expect(routeGuard(location: '/counter/order', flags: f, qsr: restaurant),
          '/tables');
      expect(
          routeGuard(location: '/tables', flags: f, qsr: restaurant), isNull);
      expect(
          routeGuard(location: '/order/t1', flags: f, qsr: restaurant), isNull);
    });

    test('QSR mode keeps Tables open (hybrid), as well as the Counter', () {
      final f = flags();
      expect(routeGuard(location: '/tables', flags: f, qsr: qsr), isNull,
          reason: 'owner decision 6: the floor stays reachable in QSR mode');
      expect(routeGuard(location: '/counter', flags: f, qsr: qsr), isNull);
      expect(routeGuard(location: '/counter/order/token', flags: f, qsr: qsr),
          isNull);
      expect(routeGuard(location: '/history/o1', flags: f, qsr: qsr), isNull);
      expect(
          routeGuard(location: '/order/t1/review', flags: f, qsr: qsr), isNull);
    });

    test('the gate needs gate rights', () {
      expect(routeGuard(location: '/gate', flags: flags(), qsr: restaurant),
          '/tables');
      expect(routeGuard(location: '/gate/scan', flags: flags(), qsr: qsr),
          '/counter');
      expect(
          routeGuard(location: '/gate', flags: flags(checkin: true), qsr: qsr),
          isNull);
      expect(
          routeGuard(
              location: '/gate/issue', flags: defaultWaiter, qsr: restaurant),
          isNull,
          reason: 'not home, but still open from the Gate tab');
    });

    test('rooms keep their own rule and go home when switched off', () {
      for (final loc in <String>[
        '/rooms',
        '/order/room/r1',
        '/order/room/r1/review'
      ]) {
        expect(routeGuard(location: loc, flags: flags(), qsr: restaurant),
            '/tables',
            reason: loc);
        expect(routeGuard(location: loc, flags: flags(), qsr: qsr), '/counter',
            reason: loc);
        expect(routeGuard(location: loc, flags: flags(rooms: true), qsr: qsr),
            isNull,
            reason: loc);
      }
    });

    test('a route that only starts with a guarded name is not guarded', () {
      expect(routeGuard(location: '/gateway', flags: flags(), qsr: restaurant),
          isNull);
      expect(routeGuard(location: '/counters', flags: flags(), qsr: restaurant),
          isNull);
    });

    test('home is never redirected and no redirect lands on a guarded route',
        () {
      const locations = <String>[
        '/tables',
        '/rooms',
        '/counter',
        '/counter/order',
        '/gate',
        '/gate/scan',
        '/history',
        '/order/room/r1',
        '/settings',
      ];
      for (final cfg in <QsrConfig>[restaurant, qsr]) {
        for (final f in <FeatureFlags>[
          flags(),
          flags(checkin: true),
          defaultWaiter,
          flags(issue: true, collectPayment: false, generateBill: false),
          flags(rooms: true),
        ]) {
          for (final pref in StartScreen.values) {
            final home = homeRouteFor(flags: f, qsr: cfg, pref: pref);
            expect(routeGuard(location: home, flags: f, qsr: cfg, pref: pref),
                isNull,
                reason: 'home $home must be open');
            expect(
                routeGuard(location: '/tables', flags: f, qsr: cfg, pref: pref),
                isNull,
                reason: 'Tables are open in both modes');
            if (cfg.isQsr && pref != StartScreen.tables) {
              expect(home, isNot('/tables'),
                  reason: 'only a pinned Tables beats the QSR home');
            }
            for (final loc in locations) {
              final to =
                  routeGuard(location: loc, flags: f, qsr: cfg, pref: pref);
              if (to == null) continue;
              expect(to, home, reason: '$loc goes home');
              expect(routeGuard(location: to, flags: f, qsr: cfg, pref: pref),
                  isNull,
                  reason: 'no redirect loop from $loc');
            }
          }
        }
      }
    });
  });

  test('homeLabelFor names the button after the home screen', () {
    expect(homeLabelFor('/tables'), 'Tables');
    expect(homeLabelFor('/counter'), 'Counter');
    expect(homeLabelFor('/gate'), 'Gate');
  });

  testWidgets('a default waiter\'s success screen says "Back to Tables"',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(flagsProvider.notifier).state = defaultWaiter;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const OrderSuccessScreen(tableId: 't1'),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('Back to Tables'), findsOneWidget);
    expect(find.textContaining('Back to Gate'), findsNothing);

    // Unmount: stops the screen's auto-return countdown.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('providers', () {
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      container = ProviderContainer();
    });

    tearDown(() => container.dispose());

    test('homeRouteProvider follows the flags and the QSR setting', () {
      expect(container.read(homeRouteProvider), '/tables');
      container.read(qsrConfigProvider.notifier).state = qsr;
      expect(container.read(homeRouteProvider), '/counter');
      container.read(flagsProvider.notifier).state =
          flags(issue: true, collectPayment: false, generateBill: false);
      expect(container.read(homeRouteProvider), '/gate');
      container.read(flagsProvider.notifier).state = defaultWaiter;
      expect(container.read(homeRouteProvider), '/counter');
      container.read(qsrConfigProvider.notifier).state = restaurant;
      container.read(flagsProvider.notifier).state = flags();
      expect(container.read(homeRouteProvider), '/tables');
    });

    test('the start screen is remembered across restarts', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'start_screen_v1': 'gate'});
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(fresh.read(startScreenProvider), StartScreen.auto);
      await settle();
      expect(fresh.read(startScreenProvider), StartScreen.gate);

      await fresh.read(startScreenProvider.notifier).set(StartScreen.counter);
      expect(fresh.read(startScreenProvider), StartScreen.counter);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('start_screen_v1'), 'counter');
    });

    test('an unknown stored start screen reads as auto', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'start_screen_v1': 'kitchen'});
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      fresh.read(startScreenProvider);
      await settle();
      expect(fresh.read(startScreenProvider), StartScreen.auto);
    });

    test('homeRouteProvider applies an available stored preference', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'start_screen_v1': 'gate'});
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      fresh.read(flagsProvider.notifier).state = flags(checkin: true);
      fresh.read(homeRouteProvider);
      await settle();
      expect(fresh.read(homeRouteProvider), '/gate');
    });
  });
}
