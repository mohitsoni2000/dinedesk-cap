import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/home_route.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import 'liquid_chrome.dart';

/// The shell's branches, in the order router.dart declares them. New
/// branches are only ever appended, so an index never changes meaning.
abstract final class ShellBranch {
  static const int tables = 0;
  static const int rooms = 1;
  static const int history = 2;
  static const int profile = 3;
  static const int settings = 4;
  static const int gate = 5;
  static const int counter = 6;

  /// Each branch's route, by index.
  static const List<String> paths = <String>[
    '/tables',
    '/rooms',
    '/history',
    '/profile',
    '/settings',
    '/gate',
    '/counter',
  ];

  /// The branch a home route lives on.
  static int ofHome(String route) => switch (route) {
        HomeRoutes.counter => counter,
        HomeRoutes.gate => gate,
        _ => tables,
      };
}

/// The tabs to show, as branch indices: Tables (restaurant mode) or Counter
/// (QSR mode), Rooms and Gate when allowed, then History, Profile, Settings,
/// with the [home] tab moved to the front.
List<int> shellTabsFor({
  required String home,
  required bool isQsr,
  required bool rooms,
  required bool gate,
}) {
  final tabs = <int>[
    if (!isQsr) ShellBranch.tables,
    if (rooms) ShellBranch.rooms,
    if (isQsr) ShellBranch.counter,
    if (gate) ShellBranch.gate,
    ShellBranch.history,
    ShellBranch.profile,
    ShellBranch.settings,
  ];
  final homeBranch = ShellBranch.ofHome(home);
  if (tabs.remove(homeBranch)) tabs.insert(0, homeBranch);
  return tabs;
}

LiquidNavItem _navItemFor(int branch) => switch (branch) {
      ShellBranch.tables =>
        const LiquidNavItem(icon: Icons.grid_view_rounded, label: 'TABLES'),
      ShellBranch.rooms =>
        const LiquidNavItem(icon: Icons.hotel_outlined, label: 'ROOMS'),
      ShellBranch.counter =>
        const LiquidNavItem(icon: Icons.storefront_outlined, label: 'COUNTER'),
      ShellBranch.gate => const LiquidNavItem(
          icon: Icons.confirmation_number_outlined, label: 'GATE'),
      ShellBranch.history =>
        const LiquidNavItem(icon: Icons.receipt_long, label: 'HISTORY'),
      ShellBranch.profile =>
        const LiquidNavItem(icon: Icons.person_outline, label: 'PROFILE'),
      _ =>
        const LiquidNavItem(icon: Icons.settings_outlined, label: 'SETTINGS'),
    };

class RootShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  const RootShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roomsEnabled = ref.watch(flagsProvider.select((f) => f.rooms));
    final gateEnabled = ref.watch(flagsProvider.select((f) => f.hasGate));
    final isQsr = ref.watch(qsrConfigProvider.select((q) => q.isQsr));
    final home = ref.watch(homeRouteProvider);

    final entries = <(int, LiquidNavItem)>[
      for (final branch in shellTabsFor(
        home: home,
        isQsr: isQsr,
        rooms: roomsEnabled,
        gate: gateEnabled,
      ))
        (branch, _navItemFor(branch)),
    ];

    // The open tab went away (rooms switched off, QSR mode turned on, gate
    // rights removed): fall back to this user's home tab.
    if (!entries.any((e) => e.$1 == navigationShell.currentIndex)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigationShell.goBranch(ShellBranch.ofHome(home));
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
      final bool wide = box.isTwoPane;
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
                      LiquidNavIcon(
                        item: items[i],
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
