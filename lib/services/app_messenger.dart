import 'package:flutter/material.dart';

import '../router.dart';
import '../theme/tokens.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/pin_verify_sheet.dart';

void showAppToast(String message, {ToastKind kind = ToastKind.error}) {
  final context = rootNavigatorKey.currentContext;
  if (context == null) return;
  DynamicToast.show(context, message: message, kind: kind);
}

bool _printFailedAlertShowing = false;

void showKotPrintFailedAlert({
  required String tableOrOrderLabel,
  required String? kotNumber,
}) {
  final context = rootNavigatorKey.currentContext;
  if (context == null || _printFailedAlertShowing) return;
  _printFailedAlertShowing = true;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: dialogContext.palette.surface,
      icon: const Icon(Icons.print_disabled_rounded,
          color: AppColors.danger, size: 32),
      title: const Text('KOT did not print', style: AppTypography.title),
      content: Text(
        kotNumber != null
            ? '$kotNumber for $tableOrOrderLabel never reached the kitchen printer. '
                'Please check with the kitchen and confirm the order manually.'
            : 'A KOT for $tableOrOrderLabel never reached the kitchen printer. '
                'Please check with the kitchen and confirm the order manually.',
        style: AppTypography.bodyMd,
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  ).then((_) => _printFailedAlertShowing = false);
}

bool _pinReverifyShowing = false;

Future<bool> promptPinReverify() async {
  final context = rootNavigatorKey.currentContext;
  if (context == null || _pinReverifyShowing) return false;
  _pinReverifyShowing = true;
  try {
    final result = await PinVerifySheet.show(context, action: 'resync');
    return result == true;
  } finally {
    _pinReverifyShowing = false;
  }
}

bool _batteryOptAlertShowing = false;

/// Asked once per install, only on Android, and only when the OS says this app
/// is still subject to battery optimization.
///
/// The foreground service is what keeps the desk connection alive with the
/// screen off, but on the OEM skins that dominate this app's install base
/// (Xiaomi, Oppo, Vivo, Samsung) the battery manager will freeze or kill even a
/// foreground service unless the app is exempt. Without this the operator's
/// symptom is the one this whole feature exists to remove: orders stop arriving
/// while the phone is in a pocket.
void showBatteryOptimizationDialog({required VoidCallback onOpenSettings}) {
  final context = rootNavigatorKey.currentContext;
  if (context == null || _batteryOptAlertShowing) return;
  _batteryOptAlertShowing = true;

  showDialog<void>(
    context: context,
    barrierDismissible: true,
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
            onOpenSettings();
          },
          child: const Text('Open settings'),
        ),
      ],
    ),
  ).then((_) => _batteryOptAlertShowing = false);
}

bool _updateAlertShowing = false;

void showUpdateAvailableDialog({required VoidCallback onUpdateNow}) {
  final context = rootNavigatorKey.currentContext;
  if (context == null || _updateAlertShowing) return;
  _updateAlertShowing = true;

  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: dialogContext.palette.surface,
      icon: const Icon(Icons.system_update_rounded,
          color: AppColors.terra, size: 32),
      title: const Text('Update Available', style: AppTypography.title),
      content: const Text(
        'A new version of Command.Crew is available with the latest fixes. '
        'Update now to stay up to date.',
        style: AppTypography.bodyMd,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            onUpdateNow();
          },
          child: const Text('Update Now'),
        ),
      ],
    ),
  ).then((_) => _updateAlertShowing = false);
}
