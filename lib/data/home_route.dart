import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/feature_flags.dart';
import '../models/qsr_config.dart';
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
  auto,
  tables,
  counter,
  gate;

  static StartScreen? fromName(String? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}

/// This user's home on this desk.
///
/// - Tables are open only in restaurant mode, the Counter only in QSR mode,
///   the Gate only with gate rights ([FeatureFlags.hasGate]).
/// - [pref] wins when that screen is open.
/// - Otherwise a gate user who can neither bill nor take money starts on the
///   Gate; everyone else on the Counter (QSR) or Tables.
String homeRouteFor({
  required FeatureFlags flags,
  required QsrConfig qsr,
  StartScreen pref = StartScreen.auto,
}) {
  switch (pref) {
    case StartScreen.tables when !qsr.isQsr:
      return HomeRoutes.tables;
    case StartScreen.counter when qsr.isQsr:
      return HomeRoutes.counter;
    case StartScreen.gate when flags.hasGate:
      return HomeRoutes.gate;
    default:
      break;
  }
  final gateFirst =
      flags.hasGate && !flags.collectPayment && !flags.generateBill;
  if (gateFirst) return HomeRoutes.gate;
  return qsr.isQsr ? HomeRoutes.counter : HomeRoutes.tables;
}

/// Where [location] must go instead, or null when it is open to this user:
///
/// - `/counter…` needs QSR mode;
/// - `/gate…` needs gate rights;
/// - `/tables` is closed in QSR mode;
/// - `/rooms` and `/order/room…` need the rooms flag (as before).
///
/// Every redirect goes to home, which is always open, so it never loops.
String? routeGuard({
  required String location,
  required FeatureFlags flags,
  required QsrConfig qsr,
  StartScreen pref = StartScreen.auto,
}) {
  bool under(String root) => location == root || location.startsWith('$root/');
  final closed = (under(HomeRoutes.counter) && !qsr.isQsr) ||
      (under(HomeRoutes.gate) && !flags.hasGate) ||
      (under(HomeRoutes.tables) && qsr.isQsr) ||
      (!flags.rooms &&
          (location == '/rooms' || location.startsWith('/order/room')));
  return closed ? homeRouteFor(flags: flags, qsr: qsr, pref: pref) : null;
}

/// "Tables" / "Counter" / "Gate": how a button names a home route.
String homeLabelFor(String route) => switch (route) {
      HomeRoutes.counter => 'Counter',
      HomeRoutes.gate => 'Gate',
      _ => 'Tables',
    };

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
    } catch (_) {}
  }

  Future<void> set(StartScreen value) async {
    _chosen = true;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, value.name);
    } catch (_) {}
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
