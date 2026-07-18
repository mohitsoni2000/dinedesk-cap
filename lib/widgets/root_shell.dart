

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
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

    void go(int i) {
      ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
      final branch = entries[i].$1;
      navigationShell.goBranch(
        branch,
        initialLocation: branch == navigationShell.currentIndex,
      );
    }

    return LayoutBuilder(builder: (context, box) {
      final bool wide = box.maxWidth >= AppBreakpoints.expanded;
      if (wide) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SafeArea(
              right: false,
              child: _SideNavRail(
                items: [for (final e in entries) e.$2],
                currentIndex: current,
                onTap: go,
              ),
            ),
            Container(width: 1, color: context.palette.hairline),
            Expanded(child: RepaintBoundary(child: navigationShell)),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: RepaintBoundary(child: navigationShell)),
          SafeArea(
            top: false,
            child: LiquidBottomNav(
              currentIndex: current,
              items: [for (final e in entries) e.$2],
              onTap: go,
            ),
          ),
        ],
      );
    });
  }
}

/// Vertical navigation for tablets / desktop — same entries and branch
/// logic as the bottom nav, laid out as a left rail so the floor grid
/// keeps its full height.
class _SideNavRail extends StatelessWidget {
  final List<LiquidNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  const _SideNavRail({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 86,
      color: palette.navBar,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Pressable(
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  curve: AppMotion.entrance,
                  width: 70,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: i == currentIndex
                        ? palette.terraSoft
                        : Colors.transparent,
                    borderRadius: const BorderRadius.all(AppRadii.md),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        items[i].icon,
                        size: 22,
                        color: i == currentIndex
                            ? AppColors.terraDeep
                            : palette.ink50,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        items[i].label,
                        style: AppTypography.pill.copyWith(
                          fontSize: 8.5,
                          color: i == currentIndex
                              ? AppColors.terraDeep
                              : palette.ink50,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}
