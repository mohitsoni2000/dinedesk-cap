import 'package:flutter/material.dart';

import '../router.dart';
import '../theme/tokens.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/pin_verify_sheet.dart';

/// Lets background services (sync_service.dart) with no BuildContext of
/// their own surface server-side action failures (error:validation /
/// error:permission) that a fire-and-forget emit() would otherwise drop
/// silently — routed through the same DynamicToast every screen uses.
void showAppToast(String message, {ToastKind kind = ToastKind.error}) {
  final context = rootNavigatorKey.currentContext;
  if (context == null) return;
  DynamicToast.show(context, message: message, kind: kind);
}

/// A KOT that genuinely failed to print (printer offline, no desktop window
/// to receive the job, etc.) needs a signal the operator can't miss the way
/// a 3-second toast can be — this blocks until acknowledged. Only one shows
/// at a time; a second failure while one is already up is dropped rather
/// than stacking dialogs, since the operator is already being told to check
/// the kitchen and a queue of near-identical dialogs adds nothing.
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

/// A reconnect's silent resync can come back rejected because the desktop's
/// (RAM-only, per-process) PIN-verified flag has genuinely lapsed — the only
/// case that should ever interrupt the operator. This asks for the PIN
/// in-place, over whatever screen they're already on, instead of the old
/// behaviour of clearing auth state and hard-navigating to the full login
/// screen. Only one prompt at a time; a second rejection while one is
/// already up is dropped rather than stacking sheets.
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
