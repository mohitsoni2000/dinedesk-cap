

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

Page<void> liquidPage({
  LocalKey? key,
  required Widget child,
  Duration duration = const Duration(milliseconds: 360),
  bool fromBottom = false,
}) {
  if (fromBottom) {
    return _ModalSheetPage<void>(key: key, child: child, duration: duration);
  }

  return CupertinoPage<void>(key: key, child: child);
}

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
      opaque: false,
      barrierColor: AppColors.scrim,
      fullscreenDialog: true,
      pageBuilder: (_, __, ___) => child,
      transitionsBuilder: (_, animation, secondaryAnimation, page) {

        final incoming = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(incoming);

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
