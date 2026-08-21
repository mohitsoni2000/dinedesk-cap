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
  // CC-LAT-010: the pairing read and the socket connect race start here,
  // before a single widget has built. The old flow paid for that
  // sequencing serially — splash mounts, reads the pairing, connecting
  // mounts, calls connect() — 300-450ms of pure waiting before a packet
  // went out. By the time SplashScreen's first frame paints, this is
  // typically already past the pairing read and into the connect attempt.
  container.read(connectionBootstrapProvider.notifier).start();

  // Nothing is awaited here on purpose. These three inits are platform-channel
  // round trips (an audio player pool, local notifications — which can raise
  // the OS permission dialog) and awaiting them in sequence delayed the very
  // first frame. They now run in parallel once the app is on screen; see
  // _RestroAppState.initState.
  runApp(UncontrolledProviderScope(
    container: container,
    child: const RestroApp(),
  ));
}

/// Flutter's decoded-image cache defaults to 1000 entries / 100MB.
///
/// That default is sized for a flagship. On a 2GB device it is a large slice
/// of the whole heap and, once it fills, it triggers texture thrashing and GC
/// pauses that show up as scroll jank — the Flutter issue tracker has a long
/// history of exactly this on low-RAM hardware.
///
/// This app is not image-heavy (three bundled PNGs, no network images today),
/// so a much smaller cache costs nothing and removes the ceiling risk if
/// item photos are ever added to the menu.
void _capImageCache() {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = 60;
  cache.maximumSizeBytes = 24 << 20; // 24MB
}

/// Phones stay portrait; tablets rotate freely.
///
/// A waiter holds a phone one-handed and never wants it flipping mid-order,
/// and phone landscape leaves too little height for a screen with a keypad on
/// it. A tablet is just as likely to sit in a landscape stand, so it keeps
/// every orientation.
///
/// Keyed off the *physical* shortest side, which doesn't change when the
/// device rotates — reading a width from MediaQuery here would flip with
/// orientation and misclassify the device half the time.
void _lockOrientationForFormFactor() {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final shortestSide =
      view.physicalSize.shortestSide / view.devicePixelRatio;

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
      // Safe to defer: FeedbackService.fire() no-ops until initialised, and
      // the operator has to get through splash → connecting → auth before
      // anything can ask for a sound.
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
        // Sits under MaterialApp so it can read MediaQuery, and above every
        // route so ambient effects can reach it via AppPerf.reduceEffects().
        builder: (context, child) => PerfScope(child: child ?? const SizedBox()),
      );
}
