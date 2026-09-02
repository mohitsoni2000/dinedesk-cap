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
