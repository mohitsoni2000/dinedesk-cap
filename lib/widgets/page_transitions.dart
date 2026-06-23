// Page transitions for go_router.
//
// Two presentation styles, both tuned to feel like native iOS:
//
//  • liquidPage(...)            → horizontal "push". Uses CupertinoPage, which
//                                 gives the real iOS interactive *edge-swipe-back*
//                                 gesture AND the parallax where the outgoing
//                                 page slides ~1/3 left and dims under the
//                                 incoming one. This is the signature iOS feel
//                                 and you get it for free (gesture + curve).
//
//  • liquidPage(fromBottom:true)→ modal "present". Slides up from the bottom over
//                                 a scrim while the page underneath scales down
//                                 slightly — the iOS sheet/cover presentation.
//
// The signature is unchanged from the previous slide+fade version, so existing
// call sites keep working; only the feel upgrades.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// A push (`fromBottom: false`) or modal present (`fromBottom: true`) page.
Page<void> liquidPage({
  LocalKey? key,
  required Widget child,
  Duration duration = const Duration(milliseconds: 360),
  bool fromBottom = false,
}) {
  if (fromBottom) {
    return _ModalSheetPage<void>(key: key, child: child, duration: duration);
  }
  // CupertinoPage carries the interactive back-gesture + parallax internally.
  return CupertinoPage<void>(key: key, child: child);
}

/// iOS-style modal presentation: incoming page rises from the bottom with a
/// soft decelerate; the route beneath gets a subtle scale-down + scrim so the
/// new surface reads as floating above it.
class _ModalSheetPage<T> extends Page<T> {
  const _ModalSheetPage({
    required this.child,
    this.duration = const Duration(milliseconds: 360),
    super.key,
  });

  final Widget child;
  final Duration duration;

  @override
  Route<T> createRoute(BuildContext context) {
    return PageRouteBuilder<T>(
      settings: this,
      transitionDuration: duration,
      reverseTransitionDuration: const Duration(milliseconds: 280),
      opaque: false, // let the scaled-down page show through the corners
      barrierColor: const Color(0x33000000),
      fullscreenDialog: true,
      pageBuilder: (_, __, ___) => child,
      transitionsBuilder: (_, animation, secondaryAnimation, page) {
        // Incoming: slide up from 8% of screen height + decelerate.
        final incoming = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(incoming);

        // Underlying page (drives secondaryAnimation): shrink to 0.94 + dim.
        final underScale = Tween<double>(begin: 1.0, end: 0.94).animate(
          CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOut),
        );

        return ScaleTransition(
          scale: underScale,
          child: FadeTransition(
            opacity: incoming,
            child: SlideTransition(position: slide, child: page),
          ),
        );
      },
    );
  }
}
