import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/providers.dart';
import 'motion/app_scroll_behavior.dart';
import 'motion/motion.dart';
import 'router.dart';
import 'services/app_messenger.dart';
import 'services/platform_surfaces.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'theme/theme_mode_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  final feedback = container.read(feedbackServiceProvider);
  await feedback.init();
  await container.read(readyAlertsProvider).init();
  await container.read(widgetSyncProvider).init();
  runApp(UncontrolledProviderScope(
    container: container,
    child: const RestroApp(),
  ));
}

class RestroApp extends ConsumerStatefulWidget {
  const RestroApp({super.key});
  @override
  ConsumerState<RestroApp> createState() => _RestroAppState();
}

class _RestroAppState extends ConsumerState<RestroApp>
    with WidgetsBindingObserver {
  final _updateService = UpdateService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The background socket auto-reconnects on its own, but the OS can
    // freeze/thaw networking in ways that leave it sitting idle for a while
    // after we're actually back in front of the user — give it a nudge the
    // instant the app is interactive again instead of waiting on its own
    // heartbeat/backoff timers.
    if (state == AppLifecycleState.resumed) {
      ref.read(socketServiceProvider).reconnectIfNeeded();
      _checkForUpdate();
    }
  }

  // A fixed-mount POS tablet can sit on the same app launch for days, so a
  // once-at-cold-start check alone would miss updates published in between —
  // re-checking on every foreground resume catches those without needing a
  // background timer running the rest of the time.
  Future<void> _checkForUpdate() async {
    final result = await _updateService.check();
    if (!result.available || !mounted) return;

    if (result.androidInfo != null) {
      final info = result.androidInfo!;
      showUpdateAvailableDialog(
        onUpdateNow: () => _updateService.startAndroidUpdate(info),
      );
    } else if (result.iosStoreUrl != null) {
      final url = result.iosStoreUrl!;
      showUpdateAvailableDialog(
        onUpdateNow: () => _updateService.openStoreUrl(url),
      );
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Commond.Crew',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ref.watch(themeModeProvider),
        scrollBehavior: const AppScrollBehavior(),
        routerConfig: ref.watch(routerProvider),
      );
}
