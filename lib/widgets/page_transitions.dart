// Page-transition helper for go_router.
//
// Provides a soft slide-up + fade for child routes (the "spatial push")
// without losing the back-swipe affordance.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

CustomTransitionPage<void> liquidPage({
  LocalKey? key,
  required Widget child,
  Duration duration = const Duration(milliseconds: 360),
  bool fromBottom = false,
}) {
  return CustomTransitionPage<void>(
    key: key,
    transitionDuration: duration,
    reverseTransitionDuration: const Duration(milliseconds: 240),
    child: child,
    transitionsBuilder: (_, anim, __, c) {
      final eased = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeIn,
      );
      final offset = Tween<Offset>(
        begin: fromBottom ? const Offset(0, 0.06) : const Offset(0.05, 0),
        end: Offset.zero,
      ).animate(eased);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(position: offset, child: c),
      );
    },
  );
}
