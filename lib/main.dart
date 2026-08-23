import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/providers.dart';
import 'theme/tokens.dart';
import 'motion/app_scroll_behavior.dart';
import 'motion/motion.dart';
import 'router.dart';
import 'services/app_messenger.dart';
import 'services/platform_surfaces.dart';
import 'services/trace.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'theme/perf_scope.dart';
import 'theme/theme_mode_provider.dart';

void main() {
  Trace.reset();
  Trace.mark('app_start');
  WidgetsFlutterBinding.ensureInitialized();
  _lockOrientationForFormFactor();
  _capImageCache();

  final container = ProviderContainer();

  container.read(connectionBootstrapProvider.notifier).start();

  runApp(UncontrolledProviderScope(
    container: container,
    child: const RestroApp(),
  ));
}

void _capImageCache() {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = 60;
  cache.maximumSizeBytes = 24 << 20;
}

void _lockOrientationForFormFactor() {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final shortestSide = view.physicalSize.shortestSide / view.devicePixelRatio;

  SystemChrome.setPreferredOrientations(
    shortestSide < AppBreakpoints.tablet
        ? const [DeviceOrientation.portraitUp]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
  );
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdate();

      unawaited(Future.wait([
        ref.read(feedbackServiceProvider).init(),
        ref.read(readyAlertsProvider).init(),
        ref.read(widgetSyncProvider).init(),
      ]));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(socketServiceProvider).reconnectIfNeeded();
      _checkForUpdate();
    }
  }

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
        builder: (context, child) =>
            PerfScope(child: child ?? const SizedBox()),
      );
}
