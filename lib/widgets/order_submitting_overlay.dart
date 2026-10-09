import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';

/// The blocking "sending…" card shown while an order goes to the desk.
///
/// It closes when [completer] completes, or with `false` after [timeout].
/// The default 15s suits a KOT send; a money event's acks run longer (an
/// adaptive ack timeout reaches 24s), so a money overlay passes
/// [moneyTimeout] and never gives up before its own ack does.
class OrderSubmittingOverlay {
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// For overlays over a money event (`qsr:checkout`, payments).
  static const Duration moneyTimeout = Duration(seconds: 30);

  static Future<bool> show(
    BuildContext context, {
    required Completer<bool> completer,
    Duration timeout = defaultTimeout,
    String title = 'Sending to kitchen\u2026',
    String subtitle = 'Printing KOTs',
  }) async {
    final nav = Navigator.of(context, rootNavigator: true);

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });

    final dialogFuture = showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => _Overlay(title: title, subtitle: subtitle),
      transitionBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    );

    unawaited(completer.future.then((ok) {
      timer.cancel();
      if (nav.canPop()) nav.pop(ok);
    }));

    return await dialogFuture ?? false;
  }
}

class _Overlay extends StatefulWidget {
  const _Overlay({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  State<_Overlay> createState() => _OverlayState();
}

class _OverlayState extends State<_Overlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Center(
        child: AppSurface(
          borderRadius: const BorderRadius.all(AppRadii.lg),
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RotationTransition(
                turns: _spin,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    color: AppColors.terra,
                    shape: BoxShape.circle,
                    boxShadow: AppShadows.terraGlow,
                  ),
                  child: const Icon(Icons.restaurant_menu,
                      color: Colors.white, size: 26),
                ),
              ),
              const SizedBox(height: 20),
              Text(widget.title, style: AppTypography.sheetTitle),
              const SizedBox(height: 6),
              Text(widget.subtitle, style: AppTypography.caption),
            ],
          ),
        ),
      ),
    );
  }
}
