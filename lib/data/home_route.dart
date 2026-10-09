import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/feature_flags.dart';
import '../models/qsr_config.dart';
import '../services/log.dart';
import 'providers.dart';

/// The screens the app can treat as "home": where it lands after the PIN,
/// after an order, and on every "Back to …".
abstract final class HomeRoutes {
  static const String tables = '/tables';
  static const String counter = '/counter';
  static const String gate = '/gate';
}

/// The user's explicit start-screen choice; [auto] lets [homeRouteFor] pick.
enum StartScreen {
  auto('Automatic', null),
  tables('Tables', HomeRoutes.tables),
  counter('Counter', HomeRoutes.counter),
  gate('Gate', HomeRoutes.gate);

  const StartScreen(this.label, this.route);
  final String label;

  /// The screen's route; null for [auto].
  final String? route;

  static StartScreen? fromName(String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}

/// Whether [screen] opens for this user on this desk: Tables always (QSR
/// mode is hybrid, the floor stays reachable), the Counter only in QSR mode,
/// the Gate only with gate rights ([FeatureFlags.hasGate]).
/// [StartScreen.auto] always does.
bool isStartScreenAvailable(
  StartScreen screen, {
  required FeatureFlags flags,
  required QsrConfig qsr,
}) =>
    switch (screen) {
      StartScreen.auto => true,
      StartScreen.tables => true,
      StartScreen.counter => qsr.isQsr,
      StartScreen.gate => flags.hasGate,
    };

/// The screens this user could pin as their start (Automatic is not one of
/// them), the desk's main screen first: Counter, Tables, Gate in QSR mode;
/// Tables, Gate otherwise. Settings offers the choice only when there are
/// two or more.
List<StartScreen> availableStartScreens({
  required FeatureFlags flags,
  required QsrConfig qsr,
}) =>
    <StartScreen>[
      for (final screen in qsr.isQsr
          ? const <StartScreen>[
              StartScreen.counter,
              StartScreen.tables,
              StartScreen.gate
            ]
          : const <StartScreen>[
              StartScreen.tables,
              StartScreen.counter,
              StartScreen.gate
            ])
        if (isStartScreenAvailable(screen, flags: flags, qsr: qsr)) screen,
    ];

/// This user's home on this desk.
///
/// - [pref] wins when that screen is available ([isStartScreenAvailable]);
///   a QSR user may pin Tables.
/// - Otherwise staff who sell tickets but can neither bill nor take money
///   start on the Gate. Check-in alone is not enough: the desk's default
///   waiter may check guests in, and must keep landing on Tables.
/// - Everyone else starts on the Counter (QSR) or Tables.
String homeRouteFor({
  required FeatureFlags flags,
  required QsrConfig qsr,
  StartScreen pref = StartScreen.auto,
}) {
  final pinned = pref.route;
  if (pinned != null && isStartScreenAvailable(pref, flags: flags, qsr: qsr)) {
    return pinned;
  }
  final gateFirst = flags.hasGate &&
      flags.ticketIssue &&
      !flags.collectPayment &&
      !flags.generateBill;
  if (gateFirst) return HomeRoutes.gate;
  return qsr.isQsr ? HomeRoutes.counter : HomeRoutes.tables;
}

/// Where [location] must go instead, or null when it is open to this user.
/// A home screen's routes follow [isStartScreenAvailable]:
///
/// - `/counter…` needs QSR mode;
/// - `/gate…` needs gate rights;
/// - `/tables` is always open (QSR mode is hybrid);
/// - `/rooms` and `/order/room…` need the rooms flag (as before).
///
/// Every redirect goes to home, which is always open, so it never loops.
String? routeGuard({
  required String location,
  required FeatureFlags flags,
  required QsrConfig qsr,
  StartScreen pref = StartScreen.auto,
}) {
  bool shut(StartScreen screen) {
    final root = screen.route;
    if (root == null) return false;
    final under = location == root || location.startsWith('$root/');
    return under && !isStartScreenAvailable(screen, flags: flags, qsr: qsr);
  }

  final closed = StartScreen.values.any(shut) ||
      (!flags.rooms &&
          (location == '/rooms' || location.startsWith('/order/room')));
  return closed ? homeRouteFor(flags: flags, qsr: qsr, pref: pref) : null;
}

/// "Tables" / "Counter" / "Gate": how a button names a home route.
String homeLabelFor(String route) {
  for (final screen in StartScreen.values) {
    if (screen.route == route) return screen.label;
  }
  return StartScreen.tables.label;
}

/// The start-screen choice, remembered on the phone (`start_screen_v1`).
final startScreenProvider =
    StateNotifierProvider<StartScreenNotifier, StartScreen>(
        (_) => StartScreenNotifier());

class StartScreenNotifier extends StateNotifier<StartScreen> {
  StartScreenNotifier() : super(StartScreen.auto) {
    unawaited(_restore());
  }

  static const String prefsKey = 'start_screen_v1';

  /// Set once the user chose: a slow restore must not undo the choice.
  bool _chosen = false;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = StartScreen.fromName(prefs.getString(prefsKey));
      if (saved != null && mounted && !_chosen) state = saved;
    } catch (error) {
      // Opens on the automatic choice; worth knowing when a pin "forgets".
      logE('[StartScreen]', 'could not read the start screen',
          error.runtimeType);
    }
  }

  /// Saves [value]; [StartScreen.auto] clears the pin. It takes effect at
  /// the next "go home", never by navigating now.
  Future<void> set(StartScreen value) async {
    _chosen = true;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == StartScreen.auto) {
        await prefs.remove(prefsKey);
      } else {
        await prefs.setString(prefsKey, value.name);
      }
    } catch (error) {
      // Holds for this run; the next start opens on the old choice.
      logE('[StartScreen]', 'could not save the start screen',
          error.runtimeType);
    }
  }
}

/// This user's home route; changes with the flags, the desk's mode and the
/// start-screen choice.
final homeRouteProvider = Provider<String>((ref) => homeRouteFor(
      flags: ref.watch(flagsProvider),
      qsr: ref.watch(qsrConfigProvider),
      pref: ref.watch(startScreenProvider),
    ));

/// Back to this user's home screen.
void goHome(BuildContext context, WidgetRef ref) =>
    context.go(ref.read(homeRouteProvider));
