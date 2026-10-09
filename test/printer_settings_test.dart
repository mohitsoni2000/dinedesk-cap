import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/screens/printer_settings_screen.dart';
import 'package:restro/screens/settings_screen.dart';
import 'package:restro/services/biometric_service.dart';
import 'package:restro/services/bt_printer_service.dart';
import 'package:restro/services/escpos_slip.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bluetooth_printer.dart';

class _NoBiometrics extends BiometricService {
  @override
  Future<bool> canUse() async => false;

  @override
  Future<bool> isEnabled() async => false;
}

/// Settings › Slip printer on a phone held upright: choose the printer the
/// phone can see, test it, pick the paper and the slip options; all saved
/// on the phone.
void main() {
  const rpp = BtPrinterInfo(name: 'RPP02N', address: '66:02:BD:06:18:7B');
  late FakeBluetoothPrinter printer;

  Future<ProviderContainer> pump(WidgetTester tester, Widget screen,
      {FeatureFlags flags = const FeatureFlags()}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      bluetoothPrinterProvider.overrideWithValue(printer),
      btPrinterServiceProvider.overrideWith(
          (ref) => BtPrinterService(printer, interSlipPause: Duration.zero)),
      biometricServiceProvider.overrideWithValue(_NoBiometrics()),
    ]);
    addTearDown(container.dispose);
    container.read(flagsProvider.notifier).state = flags;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light(), home: screen),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Future<BtPrinterSettings> saved() async {
    final prefs = await SharedPreferences.getInstance();
    return BtPrinterSettings.fromJson(
        jsonDecode(prefs.getString(BtPrinterSettings.prefsKey)!));
  }

  setUp(() {
    printer = FakeBluetoothPrinter()
      ..nearby = const <BtPrinterInfo>[
        BtPrinterInfo(name: 'Unnamed device', address: 'AA:BB'),
        rpp,
      ];
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('choose a printer, then a test page prints on it',
      (tester) async {
    final container = await pump(tester, const PrinterSettingsScreen());
    expect(find.text('No printer yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('bt-choose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('bt-printer-66:02:BD:06:18:7B')),
        findsOneWidget);
    expect(
        tester.getCenter(find.text('RPP02N')).dy,
        lessThan(tester.getCenter(find.text('Unnamed device')).dy),
        reason: 'named printers first');
    await tester.tap(find.text('RPP02N'));
    await tester.pumpAndSettle();

    expect((await saved()).printer, rpp);
    expect(container.read(btPrinterSettingsProvider).printer, rpp);
    expect(printer.calls, contains('connect'));
    expect(find.text('Connected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('bt-test-print')));
    await tester.pumpAndSettle();
    expect(printer.written, hasLength(1));
    expect(latin1.decode(printer.written.single), contains('Printer check'));
    expect(latin1.decode(printer.written.single), isNot(contains('CDT:')),
        reason: 'the test QR is not a ticket');
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('paper and slip options are saved; 80 mm cuts by default',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      BtPrinterSettings.prefsKey:
          jsonEncode(const BtPrinterSettings(printer: rpp).toJson()),
    });
    await pump(tester, const PrinterSettingsScreen());
    expect(find.text('RPP02N'), findsOneWidget);

    await tester.tap(find.text('80 mm (3")'));
    await tester.pumpAndSettle();
    var s = await saved();
    expect(s.paper, SlipPaper.mm80);
    expect(s.cuts, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('bt-raster-qr')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('bt-auto-print')));
    await tester.pumpAndSettle();
    s = await saved();
    expect(s.qrMode.wire, 'raster');
    expect(s.autoPrint, isFalse);

    await tester.tap(find.text('Forget printer'));
    await tester.pumpAndSettle();
    expect((await saved()).printer, isNull);
    expect(find.text('No printer yet'), findsOneWidget);
  });

  testWidgets('Bluetooth off: says so, and checks again on request',
      (tester) async {
    printer.answer = BtAvailability.off;
    await pump(tester, const PrinterSettingsScreen());
    expect(find.textContaining('Bluetooth is off'), findsOneWidget);
    printer.answer = BtAvailability.ready;
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bluetooth is off'), findsNothing);
  });

  testWidgets('Settings shows the Slip printer row only with gate rights',
      (tester) async {
    await pump(tester, const SettingsScreen());
    expect(find.text('Slip printer'), findsNothing);

    SharedPreferences.setMockInitialValues(<String, Object>{
      BtPrinterSettings.prefsKey: jsonEncode(
          const BtPrinterSettings(printer: rpp, paper: SlipPaper.mm80)
              .toJson()),
    });
    await pump(tester, const SettingsScreen(),
        flags: FeatureFlags.fromMap(<String, dynamic>{
          'flag_entry_tickets': 1,
          'flag_ticket_checkin': 1,
        }));
    expect(find.text('Slip printer'), findsOneWidget);
    expect(find.text('RPP02N · 80 mm'), findsOneWidget);
    expect(find.text('Start screen'), findsOneWidget,
        reason: "K1's row is still there, just above");
    expect(
        tester.getCenter(find.text('Start screen')).dy,
        lessThan(tester.getCenter(find.text('Slip printer')).dy));
  });
}
