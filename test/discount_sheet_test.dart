// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/discount_sheet.dart';
import 'package:restro/widgets/liquid_chrome.dart';

/// The Apply Discount sheet as a waiter uses it: type a percentage or a flat
/// amount and Apply must light up. A desk with no discount presets shows only
/// the custom fields, and Apply has to work there too.
void main() {
  const preset = <String, dynamic>{
    'id': 'preset-staff',
    'name': 'Staff',
    'type': 'percent',
    'value': 10,
  };

  /// What this phone put on the wire as `discount:apply`.
  final sent = <Map<String, dynamic>>[];

  /// How long the fake desk takes to answer.
  var deskDelay = Duration.zero;

  SocketService deskSocket() {
    final socket = SocketService()..debugSetState(SocketState.verified);
    socket.rawEmitOverride = (event, data, timeout) async {
      if (event == 'discount:apply') sent.add(data);
      if (deskDelay > Duration.zero) await Future<void>.delayed(deskDelay);
      return <String, dynamic>{'kind': 'success', 'order': <String, dynamic>{}};
    };
    addTearDown(socket.dispose);
    return socket;
  }

  setUp(() {
    sent.clear();
    deskDelay = Duration.zero;
  });

  Future<void> openSheet(
    WidgetTester tester, {
    required List<Map<String, dynamic>> presets,
    Money total = const Money.rupees(500),
  }) async {
    tester.view.physicalSize = const Size(1024, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(overrides: [
      socketServiceProvider.overrideWithValue(deskSocket()),
    ]);
    addTearDown(container.dispose);
    container.read(discountsProvider.notifier).state = presets;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                  DiscountSheet.show(context, orderId: 'o1', orderTotal: total)),
              child: const Text('open sheet'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
  }

  bool applyEnabled(WidgetTester tester) => tester
      .widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Apply Discount'))
      .onPressed != null;

  Future<void> typeValue(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
  }

  group('a desk with no discount presets', () {
    testWidgets('lets a percentage be applied', (tester) async {
      await openSheet(tester, presets: const []);
      expect(applyEnabled(tester), isFalse, reason: 'nothing typed yet');

      await typeValue(tester, '10');

      expect(applyEnabled(tester), isTrue);
    });

    testWidgets('lets a flat amount within the total be applied',
        (tester) async {
      await openSheet(tester, presets: const []);
      await tester.tap(find.text('Flat (₹)'));
      await tester.pump();

      await typeValue(tester, '100');

      expect(applyEnabled(tester), isTrue);
    });

    testWidgets('refuses a flat amount above the order total', (tester) async {
      await openSheet(tester, presets: const []);
      await tester.tap(find.text('Flat (₹)'));
      await tester.pump();

      await typeValue(tester, '600');

      expect(applyEnabled(tester), isFalse);
    });

    testWidgets('refuses a percentage above 100', (tester) async {
      await openSheet(tester, presets: const []);

      await typeValue(tester, '101');

      expect(applyEnabled(tester), isFalse);
    });

    testWidgets('sends the typed percentage, not an empty preset id',
        (tester) async {
      await openSheet(tester, presets: const []);
      await typeValue(tester, '10');

      await tester
          .tap(find.widgetWithText(LiquidPrimaryButton, 'Apply Discount'));
      // Outlast the sheet's own 30s backstop timer.
      await tester.pump(const Duration(seconds: 31));

      expect(sent, hasLength(1));
      expect(sent.single['order_id'], 'o1');
      expect(sent.single['custom'],
          <String, dynamic>{'type': 'percentage', 'value': 10.0});
      expect(sent.single.containsKey('discount_id'), isFalse);
    });
  });

  group('a desk with discount presets', () {
    testWidgets('keeps Apply off until a preset is chosen', (tester) async {
      await openSheet(tester, presets: const [preset]);

      expect(applyEnabled(tester), isFalse);

      await tester.tap(find.text('Staff'));
      await tester.pump();

      expect(applyEnabled(tester), isTrue);
    });

    testWidgets('lets a custom percentage be applied from the Custom tab',
        (tester) async {
      await openSheet(tester, presets: const [preset]);
      await tester.tap(find.text('Custom'));
      await tester.pump();

      await typeValue(tester, '10');

      expect(applyEnabled(tester), isTrue);
    });
  });

  testWidgets(
      'a slow desk that answers within the ack time is not called a timeout',
      (tester) async {
    deskDelay = const Duration(seconds: 12);
    await openSheet(tester, presets: const []);
    await typeValue(tester, '10');

    await tester
        .tap(find.widgetWithText(LiquidPrimaryButton, 'Apply Discount'));
    await tester.pump(const Duration(seconds: 11));

    expect(find.text('Discount request timed out — please retry'),
        findsNothing,
        reason: 'the request is still running; a retry now could apply a '
            'second, different discount');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 30));
    expect(sent, hasLength(1));
  });
}
