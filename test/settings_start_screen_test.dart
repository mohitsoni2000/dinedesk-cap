import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/home_route.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/router.dart';
import 'package:restro/screens/settings_screen.dart';
import 'package:restro/services/biometric_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Settings screen's biometric row reads secure storage, which tests
/// have no plugin for.
class _NoBiometrics extends BiometricService {
  @override
  Future<bool> canUse() async => false;

  @override
  Future<bool> isEnabled() async => false;
}

/// Settings › Start screen: pin the screen the app opens on after the PIN and
/// on every "Back to …". Only offered when this user has more than one
/// screen to start from; picking one saves it and navigates nowhere.
void main() {
  final qsr = QsrConfig.tryParse(<String, dynamic>{'operating_mode': 'qsr'})!;
  // May check guests in; can also take money, so Tables stays the auto home.
  final gateUser = FeatureFlags.fromMap(<String, dynamic>{
    'flag_entry_tickets': 1,
    'flag_ticket_checkin': 1,
  });

  group('availableStartScreens', () {
    test('restaurant without gate rights: Tables only', () {
      expect(
          availableStartScreens(
              flags: const FeatureFlags(), qsr: QsrConfig.restaurant),
          <StartScreen>[StartScreen.tables]);
    });

    test('gate rights add the Gate; QSR adds the Counter before Tables', () {
      expect(availableStartScreens(flags: gateUser, qsr: QsrConfig.restaurant),
          <StartScreen>[StartScreen.tables, StartScreen.gate]);
      expect(availableStartScreens(flags: gateUser, qsr: qsr), <StartScreen>[
        StartScreen.counter,
        StartScreen.tables,
        StartScreen.gate
      ]);
      expect(availableStartScreens(flags: const FeatureFlags(), qsr: qsr),
          <StartScreen>[StartScreen.counter, StartScreen.tables]);
    });

    test('Automatic is always possible but never listed', () {
      expect(
          isStartScreenAvailable(StartScreen.auto,
              flags: const FeatureFlags(), qsr: qsr),
          isTrue);
      expect(
          availableStartScreens(flags: gateUser, qsr: qsr)
              .contains(StartScreen.auto),
          isFalse);
    });
  });

  group('Settings › Start screen', () {
    late ProviderContainer container;

    Future<void> pumpSettings(
      WidgetTester tester, {
      FeatureFlags flags = const FeatureFlags(),
      QsrConfig qsrConfig = QsrConfig.restaurant,
    }) async {
      // A phone held upright, as Crew runs.
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      container = ProviderContainer(overrides: [
        biometricServiceProvider.overrideWithValue(_NoBiometrics()),
      ]);
      addTearDown(container.dispose);
      container.read(flagsProvider.notifier).state = flags;
      container.read(qsrConfigProvider.notifier).state = qsrConfig;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    testWidgets('is hidden in plain restaurant mode with no gate rights',
        (tester) async {
      await pumpSettings(tester);
      expect(find.text('Change PIN'), findsOneWidget,
          reason: 'the DEVICE section itself is there');
      expect(find.text('Start screen'), findsNothing);
    });

    testWidgets('a QSR desk offers Automatic, Counter and Tables',
        (tester) async {
      await pumpSettings(tester, qsrConfig: qsr);
      expect(find.text('Automatic · opens on Counter'), findsOneWidget);

      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('Counter'), findsOneWidget);
      expect(find.text('Tables'), findsOneWidget);
      expect(find.text('Gate'), findsNothing, reason: 'no gate rights');
      expect(tester.getCenter(find.text('Counter')).dy,
          lessThan(tester.getCenter(find.text('Tables')).dy),
          reason: 'the QSR home screen comes first');
    });

    testWidgets('with gate rights it offers Automatic, Tables and Gate',
        (tester) async {
      await pumpSettings(tester, flags: gateUser);
      expect(find.text('Start screen'), findsOneWidget);
      expect(find.text('Automatic · opens on Tables'), findsOneWidget);

      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();

      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('Tables'), findsOneWidget);
      expect(find.text('Gate'), findsOneWidget);
      expect(find.text('Counter'), findsNothing,
          reason: 'only screens this user can open right now');
    });

    testWidgets('on a QSR desk with gate rights: Counter, Tables and Gate',
        (tester) async {
      await pumpSettings(tester, flags: gateUser, qsrConfig: qsr);
      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();
      expect(find.text('Counter'), findsOneWidget);
      expect(find.text('Tables'), findsOneWidget);
      expect(find.text('Gate'), findsOneWidget);
    });

    testWidgets('a QSR user can pin Tables', (tester) async {
      await pumpSettings(tester, qsrConfig: qsr);
      expect(container.read(homeRouteProvider), '/counter');
      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tables'));
      await tester.pumpAndSettle();
      expect(container.read(homeRouteProvider), '/tables');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('start_screen_v1'), 'tables');
    });

    testWidgets('picking Gate saves it and makes Gate the home, no navigation',
        (tester) async {
      await pumpSettings(tester, flags: gateUser);
      expect(container.read(homeRouteProvider), '/tables');

      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gate'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('start_screen_v1'), 'gate');
      expect(container.read(startScreenProvider), StartScreen.gate);
      expect(container.read(homeRouteProvider), '/gate');
      expect(find.byType(SettingsScreen), findsOneWidget,
          reason: 'the sheet closes; the next "go home" uses the choice');
      expect(find.text('Always opens on Gate'), findsOneWidget);
    });

    testWidgets(
        'inside the real router: picking a start screen stays on Settings',
        (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      container = ProviderContainer(overrides: [
        biometricServiceProvider.overrideWithValue(_NoBiometrics()),
      ]);
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: true, label: 'Connected');
      container.read(qsrConfigProvider.notifier).state = qsr;
      container.read(isAuthenticatedProvider.notifier).state = true;
      final router = container.read(routerProvider);
      String path() => router.routerDelegate.currentConfiguration.uri.path;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child:
            MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(path(), '/counter');

      router.go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tables'));
      await tester.pumpAndSettle();

      expect(container.read(homeRouteProvider), '/tables');
      expect(path(), '/settings',
          reason: "the new home re-runs the router's redirect, which must "
              'not move anyone: the next "go home" uses it');
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('Automatic clears the pin', (tester) async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'start_screen_v1': 'gate'});
      await pumpSettings(tester, flags: gateUser);
      expect(container.read(homeRouteProvider), '/gate');

      await tester.tap(find.text('Start screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('start_screen_v1'), isFalse);
      expect(container.read(startScreenProvider), StartScreen.auto);
      expect(container.read(homeRouteProvider), '/tables');
    });
  });
}
