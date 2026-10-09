import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/server_models.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:restro/widgets/payment_sheet.dart';

/// A text field by its hint.
Finder fieldWithHint(String hint) => find
    .byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);

/// The payment sheet opened the way the order screen opens it, over a fake
/// desk: every ack comes from [answer], and everything emitted is in [sent].
class PaymentSheetHarness {
  PaymentSheetHarness._(this.socket, this.container);

  final SocketService socket;
  final ProviderContainer container;
  final List<({String event, Map<String, dynamic> data})> sent =
      <({String event, Map<String, dynamic> data})>[];
  FutureOr<Map<String, dynamic>> Function(
          String event, Map<String, dynamic> data) answer =
      (_, __) => <String, dynamic>{'kind': 'success'};

  /// What [PaymentSheet.show] returned; null while the sheet is open.
  bool? result;
  bool closed = false;

  static Future<PaymentSheetHarness> open(
    WidgetTester tester, {
    required List<ServerBill> bills,
    FeatureFlags flags = const FeatureFlags(),
    bool hasCustomer = false,
    TicketConfig ticketConfig = TicketConfig.none,
    List<PayMode> listedModes = const <PayMode>[],
    BillDues? dues,
  }) async {
    // Wide enough for the test font, which draws every glyph a full em
    // wide: these tests pin what is sent and shown, not the layout.
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final socket = SocketService()..debugSetState(SocketState.verified);
    addTearDown(socket.dispose);
    final container = ProviderContainer(
        overrides: [socketServiceProvider.overrideWithValue(socket)]);
    addTearDown(container.dispose);
    container.read(flagsProvider.notifier).state = flags;
    container.read(ticketConfigProvider.notifier).state = ticketConfig;
    container.read(listedPayModesProvider.notifier).state = listedModes;

    final h = PaymentSheetHarness._(socket, container);
    socket.rawEmitOverride = (event, data, timeout) async {
      h.sent.add((event: event, data: Map<String, dynamic>.from(data)));
      return h.answer(event, data);
    };

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(PaymentSheet.show(context,
                      bills: bills, hasCustomer: hasCustomer, dues: dues)
                  .then((r) {
                h.result = r;
                h.closed = true;
              })),
              child: const Text('open sheet'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    return h;
  }

  LiquidPrimaryButton payButton(WidgetTester tester) =>
      tester.widget<LiquidPrimaryButton>(
          find.widgetWithText(LiquidPrimaryButton, 'Pay'));

  Future<void> pay(WidgetTester tester) async {
    final button = find.widgetWithText(LiquidPrimaryButton, 'Pay');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// The `bill:payment` payloads sent, without their request ids.
  List<Map<String, dynamic>> payloads() => <Map<String, dynamic>>[
        for (final s in sent)
          if (s.event == 'bill:payment')
            <String, dynamic>{...s.data}..remove('client_request_id'),
      ];

  /// Lets every toast run out, so no timer outlives the test.
  Future<void> drainToasts(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(seconds: 5));
}
