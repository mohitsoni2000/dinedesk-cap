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
import 'services/socket_service.dart';
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
      unawaited(_verifyConnectionOnResume());
      _checkForUpdate();
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

  /// Android can suspend the isolate while this app is backgrounded and kill
  /// the socket transport underneath it without ever running onDisconnect —
  /// `SocketService.state` then keeps claiming "verified" after resume even
  /// though nothing is actually listening on the other end.
  /// `reconnectIfNeeded()` alone can't catch that (its guard trusts the same
  /// stale `state`), so first confirm the connection is real with a live
  /// resync — which also refreshes tables and flushes queued
  /// orders/KOTs as a bonus if it succeeds. `SocketService.emitAck` flips
  /// `state` to disconnected on a genuine ack timeout, so a dead socket
  /// surfaces here as `state == disconnected` afterward and gets a full,
  /// clean reconnect through the same path the manual "retry" button uses.
  Future<void> _verifyConnectionOnResume() async {
    final socket = ref.read(socketServiceProvider);
    // Mid-PIN (the operator switched apps with the verify in flight): a
    // concurrent resync would race it, and its timeout would rebuild the
    // socket out from under it. The verify settles the link state itself.
    if (socket.isVerifyInFlight) return;
    if (socket.state == SocketState.disconnected) {
      socket.reconnectIfNeeded();
      return;
    }
    await ref.read(syncServiceProvider).requestResync();
    if (ref.read(socketServiceProvider).state == SocketState.disconnected) {
      ref.read(connectionBootstrapProvider.notifier).retry();
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
