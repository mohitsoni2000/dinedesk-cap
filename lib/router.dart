import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'services/session_service.dart';
import 'screens/splash_screen.dart';
import 'screens/qr_scan_screen.dart';
import 'screens/connecting_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/tables_screen.dart';
import 'screens/rooms_screen.dart';
import 'screens/order_builder_screen.dart';
import 'screens/order_review_screen.dart';
import 'screens/order_success_screen.dart';
import 'screens/order_detail_screen.dart';
import 'screens/history_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/change_pin_screen.dart';
import 'screens/disconnected_screen.dart';
import 'screens/force_disconnected_screen.dart';
import 'theme/tokens.dart';
import 'widgets/connection_banner.dart';
import 'widgets/page_transitions.dart';
import 'widgets/ready_orders_banner.dart';
import 'widgets/rejected_kots_banner.dart';
import 'widgets/root_shell.dart';

/// Lets code with no BuildContext of its own (background services like
/// sync_service.dart) reach the root Overlay — e.g. to show a DynamicToast.
final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final authed = ref.watch(isAuthenticatedProvider);
  final forceDisconnected = ref.watch(forceDisconnectedProvider);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    redirect: (context, state) {
      final loc = state.matchedLocation;
      const authFlow = ['/splash', '/scan', '/connecting', '/auth'];
      final onAuthFlow = authFlow.any((p) => loc.startsWith(p));
      final onDisconnect =
          loc == '/disconnected' || loc == '/force-disconnected';
      if (forceDisconnected && loc != '/force-disconnected') {
        return '/force-disconnected';
      }
      if (!ref.read(flagsProvider).rooms &&
          (loc == '/rooms' || loc.startsWith('/order/room'))) {
        return '/tables';
      }
      if (!authed && !onAuthFlow && !onDisconnect) return '/auth';
      if (authed && onAuthFlow) return '/tables';
      return null;
    },
    errorBuilder: (context, state) => const Scaffold(
      backgroundColor: Colors.black87,
      body: Center(
        child: Text('Page not found',
            style: TextStyle(color: Colors.white70, fontSize: 18)),
      ),
    ),
    routes: [
      GoRoute(
          path: '/splash',
          pageBuilder: (_, s) =>
              liquidPage(key: s.pageKey, child: const SplashScreen())),
      GoRoute(
          path: '/scan',
          pageBuilder: (_, s) =>
              liquidPage(key: s.pageKey, child: const QrScanScreen())),
      GoRoute(
          path: '/connecting',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              child: ConnectingScreen(
                  initialPairing:
                      s.extra is PairingInfo ? s.extra as PairingInfo : null))),
      GoRoute(
          path: '/auth',
          pageBuilder: (_, s) =>
              liquidPage(key: s.pageKey, child: const AuthScreen())),
      StatefulShellRoute.indexedStack(
        // The shell's own chrome — nav rail/bar and the two banners — sits
        // outside every branch's Scaffold, so without a Material ancestor its
        // text renders in Flutter's "you forgot Material" style (yellow double
        // underline). `transparency` supplies the ancestor without painting
        // over the background colour behind it.
        builder: (context, state, navigationShell) => Material(
          type: MaterialType.transparency,
          // The app background: one colour. `SizedBox.expand` is load-bearing
          // — a bare ColoredBox passes its constraints through loosely and the
          // shell would shrink-wrap instead of filling the screen.
          child: ColoredBox(
            color: context.palette.paper,
            child: SizedBox.expand(
              child: ConnectionBanner(
                child: ReadyOrdersBanner(
                  // Outermost of the three so it is never covered: a KOT the
                  // kitchen never received outranks both the connection state
                  // and a ready-to-serve nudge.
                  child: RejectedKotsBanner(
                    child: RootShell(navigationShell: navigationShell),
                  ),
                ),
              ),
            ),
          ),
        ),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/tables', builder: (_, __) => const TablesScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/rooms', builder: (_, __) => const RoomsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/history', builder: (_, __) => const HistoryScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/profile', builder: (_, __) => const ProfileScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/settings', builder: (_, __) => const SettingsScreen()),
          ]),
        ],
      ),
      GoRoute(
          path: '/order/:tableId',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              child: ConnectionBanner(
                  child: OrderBuilderScreen(
                      tableId: s.pathParameters['tableId']!)))),
      GoRoute(
          path: '/order/:tableId/review',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              child: ConnectionBanner(
                  child: OrderReviewScreen(
                      tableId: s.pathParameters['tableId']!,
                      autoSend: s.extra == true)))),
      GoRoute(
          path: '/order/:tableId/success',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              fromBottom: true,
              child: ConnectionBanner(
                  child: OrderSuccessScreen(
                      tableId: s.pathParameters['tableId']!)))),
      GoRoute(
          path: '/order/room/:roomId',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              child: ConnectionBanner(
                  child: OrderBuilderScreen(
                      tableId: s.pathParameters['roomId']!, isRoom: true)))),
      GoRoute(
          path: '/order/room/:roomId/review',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              child: ConnectionBanner(
                  child: OrderReviewScreen(
                      tableId: s.pathParameters['roomId']!,
                      isRoom: true,
                      autoSend: s.extra == true)))),
      GoRoute(
          path: '/order/room/:roomId/success',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              fromBottom: true,
              child: ConnectionBanner(
                  child: OrderSuccessScreen(
                      tableId: s.pathParameters['roomId']!, isRoom: true)))),
      GoRoute(
          path: '/history/:orderId',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              fromBottom: true,
              child: ConnectionBanner(
                  child: OrderDetailScreen(
                      orderId: s.pathParameters['orderId']!)))),
      GoRoute(
          path: '/change-pin',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey,
              fromBottom: true,
              child: const ConnectionBanner(child: ChangePinScreen()))),
      GoRoute(
          path: '/disconnected',
          pageBuilder: (_, s) =>
              liquidPage(key: s.pageKey, child: const DisconnectedScreen())),
      GoRoute(
          path: '/force-disconnected',
          pageBuilder: (_, s) => liquidPage(
              key: s.pageKey, child: const ForceDisconnectedScreen())),
    ],
  );
});
