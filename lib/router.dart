// Routing — go_router (Navigator 2.0).
//
// Boot flow:   /splash → /scan → /connecting → /auth → /tables
// On disconnect:  banner overlay → /disconnected (after 2-min grace)
// On force-kick:  /force-disconnected
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'screens/splash_screen.dart';
import 'screens/qr_scan_screen.dart';
import 'screens/connecting_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/tables_screen.dart';
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
import 'widgets/connection_banner.dart';
import 'widgets/liquid_mesh_background.dart';
import 'widgets/page_transitions.dart';
import 'widgets/root_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // Rebuild the redirect logic whenever auth state changes.
  final authed = ref.watch(isAuthenticatedProvider);

  return GoRouter(
    initialLocation: '/splash',
    redirect: (context, state) {
      final loc = state.matchedLocation;
      const authFlow = ['/splash', '/scan', '/connecting', '/auth'];
      final onAuthFlow = authFlow.any((p) => loc.startsWith(p));
      final onDisconnect = loc == '/disconnected' || loc == '/force-disconnected';
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
    GoRoute(path: '/splash',     pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const SplashScreen())),
    GoRoute(path: '/scan',       pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const QrScanScreen())),
    GoRoute(path: '/connecting', pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const ConnectingScreen())),
    GoRoute(path: '/auth',       pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const AuthScreen())),
    ShellRoute(
      builder: (_, __, child) => LiquidMeshBackground(
        child: ConnectionBanner(child: RootShell(child: child)),
      ),
      routes: [
        GoRoute(path: '/tables',  pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const TablesScreen())),
        GoRoute(path: '/history', pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const HistoryScreen())),
        GoRoute(path: '/profile', pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const ProfileScreen())),
        GoRoute(path: '/settings',pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const SettingsScreen())),
      ],
    ),
    GoRoute(path: '/order/:tableId', pageBuilder: (_, s) =>
      liquidPage(key: s.pageKey, child: OrderBuilderScreen(tableId: s.pathParameters['tableId']!))),
    GoRoute(path: '/order/:tableId/review', pageBuilder: (_, s) =>
      liquidPage(key: s.pageKey, child: OrderReviewScreen(tableId: s.pathParameters['tableId']!))),
    GoRoute(path: '/order/:tableId/success', pageBuilder: (_, s) =>
      liquidPage(key: s.pageKey, fromBottom: true, child: OrderSuccessScreen(tableId: s.pathParameters['tableId']!))),
    GoRoute(path: '/history/:orderId', pageBuilder: (_, s) =>
      liquidPage(key: s.pageKey, child: OrderDetailScreen(orderId: s.pathParameters['orderId']!))),
    GoRoute(path: '/change-pin',         pageBuilder: (_, s) => liquidPage(key: s.pageKey, fromBottom: true, child: const ChangePinScreen())),
    GoRoute(path: '/disconnected',       pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const DisconnectedScreen())),
    GoRoute(path: '/force-disconnected', pageBuilder: (_, s) => liquidPage(key: s.pageKey, child: const ForceDisconnectedScreen())),
  ],
  );
});
