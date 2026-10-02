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
import 'services/network_keepalive.dart';
import 'services/session_service.dart';
import 'services/platform_surfaces.dart';
import 'services/trace.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'theme/perf_scope.dart';
import 'theme/theme_mode_provider.dart';
import 'widgets/battery_optimization_dialog.dart';

void main() {
  Trace.reset();
  Trace.mark('app_start');
  WidgetsFlutterBinding.ensureInitialized();
  _lockOrientationForFormFactor();
  _capImageCache();

  final container = ProviderContainer();

  // Before bootstrap: the supervisor installs the adaptive timeout policy and
  // the RTT hook on SocketService, and the very first connect() should already
  // be using them.
  container.read(connectionSupervisorProvider).start();
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      unawaited(_checkForUpdate());
      unawaited(NetworkKeepAlive.setLowLatencyLock(true));
      unawaited(_syncKeepAlive());

      try {
        await ref.read(feedbackServiceProvider).init();
        await ref.read(readyAlertsProvider).init();
        await ref.read(widgetSyncProvider).init();
      } catch (err, st) {
        debugPrint('Startup init error: $err\n$st');
      } finally {
        if (mounted) {
          ref.read(startupPermissionsCompleteProvider.notifier).state = true;
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// When the app last left the foreground, or null while it is in it.
  DateTime? _backgroundedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref
        .read(connectionSupervisorProvider)
        .setAppForeground(state == AppLifecycleState.resumed);
    // Low-latency Wi-Fi lock only while on screen (the OS ignores it
    // otherwise); the foreground service's own lock covers screen-off.
    unawaited(NetworkKeepAlive.setLowLatencyLock(
        state == AppLifecycleState.resumed));
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncKeepAlive());
      _onResumed();
      _checkForUpdate();
    } else {
      _backgroundedAt ??= DateTime.now();
    }
  }

  /// Runs the keep-alive foreground service while paired (and the settings
  /// toggle is on; `start` checks it). Called only from the foreground, since
  /// Android 12+ refuses a foreground-service start from the background. Stop
  /// on unpair lives in `SessionService.clearPairing`, which every unpair and
  /// logout path goes through.
  Future<void> _syncKeepAlive() async {
    try {
      final paired = await SessionService().getSavedPairing() != null;
      if (!paired) {
        await NetworkKeepAlive.stop();
        return;
      }
      if (NetworkKeepAlive.isRunning) return;
      final started = await NetworkKeepAlive.start(
          restaurant: ref.read(restaurantProvider)?.name);
      if (started) unawaited(maybeShowBatteryOptimizationDialog());
    } catch (err) {
      debugPrint('Keep-alive sync error: $err');
    }
  }

  /// Android can suspend the isolate while the app is backgrounded and kill the
  /// socket transport underneath it without ever running onDisconnect, so
  /// `SocketService.state` can keep claiming "verified" after resume.
  ///
  /// This used to answer that with a full resync on every resume — a multi-
  /// hundred-KB payload down a link that might be dead, and (because a timed-out
  /// ack then flipped the state) a full socket teardown if it was merely slow.
  /// Now the link monitor decides: after a long absence it probes (a one-line
  /// heartbeat plus an HTTP ping) and only escalates if the link is proven
  /// dead; a short absence costs nothing; a socket that is already down gets
  /// poked and its recovery ladder restarted. A PIN verify in flight is
  /// respected by every step the monitor can take.
  void _onResumed() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    final away = since == null ? Duration.zero : DateTime.now().difference(since);
    ref.read(connectionSupervisorProvider).monitor.onResume(away);
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
