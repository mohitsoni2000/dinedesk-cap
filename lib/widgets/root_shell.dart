

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import 'liquid_chrome.dart';

class RootShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  const RootShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roomsEnabled = ref.watch(flagsProvider.select((f) => f.rooms));

    // (branchIndex, navItem) — branch order is fixed in router.dart, so
    // hiding a tab must not shift the goBranch() indices.
    final entries = <(int, LiquidNavItem)>[
      (0, const LiquidNavItem(icon: Icons.grid_view_rounded, label: 'TABLES')),
      if (roomsEnabled)
        (1, const LiquidNavItem(icon: Icons.hotel_outlined, label: 'ROOMS')),
      (2, const LiquidNavItem(icon: Icons.receipt_long, label: 'HISTORY')),
      (3, const LiquidNavItem(icon: Icons.person_outline, label: 'PROFILE')),
      (4, const LiquidNavItem(icon: Icons.settings_outlined, label: 'SETTINGS')),
    ];

    // flags.rooms turned off while the Rooms branch is active → bounce home.
    if (!roomsEnabled && navigationShell.currentIndex == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigationShell.goBranch(0);
      });
    }

    var current =
        entries.indexWhere((e) => e.$1 == navigationShell.currentIndex);
    if (current < 0) current = 0;

    return Column(
      children: [
        Expanded(child: RepaintBoundary(child: navigationShell)),
        SafeArea(
          top: false,
          child: LiquidBottomNav(
            currentIndex: current,
            items: [for (final e in entries) e.$2],
            onTap: (i) {
              ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
              final branch = entries[i].$1;
              navigationShell.goBranch(
                branch,
                initialLocation: branch == navigationShell.currentIndex,
              );
            },
          ),
        ),
      ],
    );
  }
}
