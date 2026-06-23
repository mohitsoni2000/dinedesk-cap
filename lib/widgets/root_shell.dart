// Persistent shell for the tab section (tables/history/profile/settings).
//
// Renders the StatefulNavigationShell (an IndexedStack of per-tab Navigators),
// so each tab keeps its own state and switching is instant — the iOS tab-bar
// model. Adds two authentic touches:
//   • a selection haptic tick on tab change
//   • re-tapping the already-active tab pops that branch back to its root
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../motion/motion.dart';
import 'liquid_chrome.dart';

class RootShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  const RootShell({super.key, required this.navigationShell});

  static const _items = [
    LiquidNavItem(icon: Icons.grid_view_rounded, label: 'TABLES'),
    LiquidNavItem(icon: Icons.receipt_long, label: 'HISTORY'),
    LiquidNavItem(icon: Icons.person_outline, label: 'PROFILE'),
    LiquidNavItem(icon: Icons.settings_outlined, label: 'SETTINGS'),
  ];

  void _onTap(WidgetRef ref, int index) {
    ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
    // initialLocation:true when re-tapping the current tab → pop branch to root.
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        // RepaintBoundary keeps tab-body repaints from leaking into the nav bar.
        Expanded(child: RepaintBoundary(child: navigationShell)),
        SafeArea(
          top: false,
          child: LiquidBottomNav(
            currentIndex: navigationShell.currentIndex,
            items: _items,
            onTap: (i) => _onTap(ref, i),
          ),
        ),
      ],
    );
  }
}
