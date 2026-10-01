import 'package:flutter/material.dart';

import '../router.dart';
import '../services/network_keepalive.dart';
import '../theme/tokens.dart';

bool _showing = false;

/// One-time, dismissible nudge to exempt the app from battery optimisation.
///
/// The foreground service keeps the desk connection alive with the screen off,
/// but aggressive OEM skins (Xiaomi, Oppo, Vivo, Samsung) freeze or kill even a
/// foreground service unless the app is exempt. Opens the system list rather
/// than the direct request intent, which Play policy restricts. Marked as shown
/// immediately, so "Not now" and a tap outside both mean never ask again.
Future<void> maybeShowBatteryOptimizationDialog() async {
  if (_showing) return;
  if (!await NetworkKeepAlive.shouldPromptBatteryOptimization()) return;
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  _showing = true;
  await NetworkKeepAlive.markBatteryPrompted();
  if (!context.mounted) {
    _showing = false;
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: dialogContext.palette.surface,
      icon: const Icon(Icons.battery_saver_rounded,
          color: AppColors.terra, size: 32),
      title: const Text('Keep the desk connected', style: AppTypography.title),
      content: const Text(
        "Your phone's battery saver can disconnect this app from the billing "
        'desk while the screen is off, so new orders and ready alerts stop '
        'arriving.\n\nTo stop that, find Command.Crew in the list on the next '
        'screen and set it to "Not optimised".',
        style: AppTypography.bodyMd,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            NetworkKeepAlive.openBatteryOptimizationSettings();
          },
          child: const Text('Open settings'),
        ),
      ],
    ),
  );
  _showing = false;
}
