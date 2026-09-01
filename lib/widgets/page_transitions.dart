import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';

Page<void> liquidPage({
  LocalKey? key,
  required Widget child,
  Duration duration = const Duration(milliseconds: 360),
  bool fromBottom = false,
}) {
  if (fromBottom) {
    return CustomTransitionPage<void>(
      key: key,
      child: child,
      opaque: false,
      barrierColor: AppColors.scrim,
      barrierDismissible: true,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (AppPerf.reduceEffects(context)) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        }
        final tween = Tween<Offset>(
          begin: const Offset(0.0, 1.0),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic));
        return SlideTransition(
          position: animation.drive(tween),
          child: child,
        );
      },
    );
  }

  return CupertinoPage<void>(key: key, child: child);
}
