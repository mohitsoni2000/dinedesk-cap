

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
    LiquidNavItem(icon: Icons.hotel_outlined, label: 'ROOMS'),
    LiquidNavItem(icon: Icons.receipt_long, label: 'HISTORY'),
    LiquidNavItem(icon: Icons.person_outline, label: 'PROFILE'),
    LiquidNavItem(icon: Icons.settings_outlined, label: 'SETTINGS'),
  ];

  void _onTap(WidgetRef ref, int index) {
    ref.read(feedbackServiceProvider).fire(const FeedbackSelection());

    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [

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
