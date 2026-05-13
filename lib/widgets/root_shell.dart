// Persistent shell for tab routes (tables/history/profile/settings).
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'liquid_chrome.dart';

class RootShell extends ConsumerWidget {
  final Widget child;
  const RootShell({super.key, required this.child});

  static const _items = [
    LiquidNavItem(icon: Icons.grid_view_rounded, label: 'TABLES'),
    LiquidNavItem(icon: Icons.receipt_long, label: 'HISTORY'),
    LiquidNavItem(icon: Icons.person_outline, label: 'PROFILE'),
    LiquidNavItem(icon: Icons.settings_outlined, label: 'SETTINGS'),
  ];

  static const _routes = ['/tables', '/history', '/profile', '/settings'];

  int _indexFromLocation(String loc) {
    for (int i = 0; i < _routes.length; i++) {
      if (loc.startsWith(_routes[i])) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = GoRouterState.of(context).uri.path;
    final idx = _indexFromLocation(loc);
    return SafeArea(
      child: Column(
        children: [
          Expanded(child: child),
          LiquidBottomNav(
            currentIndex: idx,
            items: _items,
            onTap: (i) => context.go(_routes[i]),
          ),
        ],
      ),
    );
  }
}
