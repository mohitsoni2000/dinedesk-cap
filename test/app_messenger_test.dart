import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/router.dart';
import 'package:restro/services/app_messenger.dart';
import 'package:restro/theme/app_theme.dart';

/// Toasts raised from outside any screen (the sync service's refused KOTs
/// and orders) show on the root navigator, as the app is built: a router
/// whose navigator has no overlay above it.
void main() {
  testWidgets('a toast from the root navigator shows', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      navigatorKey: rootNavigatorKey,
      home: const Scaffold(body: Text('home')),
    ));

    showAppToast('A KOT could not be sent: printer offline');
    await tester.pump();
    expect(
        find.text('A KOT could not be sent: printer offline'), findsOneWidget);

    // A second replaces the first.
    showAppToast('An order could not be sent: item unavailable');
    await tester.pump();
    expect(find.text('An order could not be sent: item unavailable'),
        findsOneWidget);
    expect(find.text('A KOT could not be sent: printer offline'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(
        find.text('An order could not be sent: item unavailable'), findsNothing,
        reason: 'it goes by itself');
  });

  testWidgets('before the app is up it does nothing', (tester) async {
    await tester.pumpWidget(const SizedBox());
    showAppToast('too early');
    await tester.pump();
    expect(find.text('too early'), findsNothing);
  });
}
