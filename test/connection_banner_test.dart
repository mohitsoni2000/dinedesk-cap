import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/link_monitor.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/connection_banner.dart';

/// The banner is three quiet, debounced pills — never a blocking bar, never a
/// countdown, never a redirect.
void main() {
  late ProviderContainer container;

  Future<void> pumpBanner(WidgetTester tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: true, label: 'Connected');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: ConnectionBanner(child: Center(child: Text('content'))),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> elapse(WidgetTester tester, Duration d) async {
    await tester.pump(d);
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('healthy: nothing is shown', (tester) async {
    await pumpBanner(tester);
    expect(find.text('content'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
    expect(find.text('Weak connection'), findsNothing);
  });

  testWidgets('offline shows only after 2.5s, with the queue size and Retry',
      (tester) async {
    await pumpBanner(tester);
    container.read(outboxPendingCountProvider.notifier).state = 3;
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: false, label: 'Reconnecting...');
    await tester.pump();

    await elapse(tester, const Duration(milliseconds: 2000));
    expect(find.textContaining('Offline'), findsNothing,
        reason: 'a blip must not flash a banner');

    await elapse(tester, const Duration(milliseconds: 800));
    expect(find.text('Offline · 3 queued'), findsOneWidget);
    expect(find.text('Retry now'), findsOneWidget);
    // Non-blocking: the content underneath is still there and tappable.
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('a blip that heals inside the debounce never shows',
      (tester) async {
    await pumpBanner(tester);
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: false, label: 'Reconnecting...');
    await tester.pump();
    await elapse(tester, const Duration(milliseconds: 1500));
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: true, label: 'Connected');
    await tester.pump();
    await elapse(tester, const Duration(seconds: 3));
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('the pill disappears when the connection returns',
      (tester) async {
    await pumpBanner(tester);
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: false, label: 'x');
    await tester.pump();
    await elapse(tester, const Duration(seconds: 3));
    expect(find.text('Offline'), findsOneWidget);

    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: true, label: 'Connected');
    await tester.pump();
    await elapse(tester, const Duration(milliseconds: 400));
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('suspect shows "Weak connection" only after 3s', (tester) async {
    await pumpBanner(tester);
    container.read(linkHealthProvider.notifier).state = LinkHealth.suspect;
    await tester.pump();

    await elapse(tester, const Duration(milliseconds: 2500));
    expect(find.text('Weak connection'), findsNothing);
    await elapse(tester, const Duration(milliseconds: 800));
    expect(find.text('Weak connection'), findsOneWidget);

    container.read(linkHealthProvider.notifier).state = LinkHealth.healthy;
    await tester.pump();
    await elapse(tester, const Duration(milliseconds: 400));
    expect(find.text('Weak connection'), findsNothing);
  });

  testWidgets('stale data adds "Showing saved data" while offline',
      (tester) async {
    await pumpBanner(tester);
    container.read(isFloorDataStaleProvider.notifier).state = true;
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: false, label: 'x');
    await tester.pump();
    await elapse(tester, const Duration(seconds: 3));
    expect(find.text('Showing saved data'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('no countdown, no redirect: still just a pill after minutes',
      (tester) async {
    await pumpBanner(tester);
    container.read(connectionProvider.notifier).state =
        const ConnectionStatus(online: false, label: 'x');
    await tester.pump();
    await elapse(tester, const Duration(minutes: 20));
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
    expect(find.textContaining('remaining'), findsNothing);
  });
}
