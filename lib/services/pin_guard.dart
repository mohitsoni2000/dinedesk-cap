

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../widgets/pin_verify_sheet.dart';

/// Client-side PIN gate.
///
/// This is **UX only**. It decides when to *prompt*; it does not decide what
/// is *allowed*. Both the gate and the session window live on the phone, so a
/// modified build skips every one of them — comp, void, discount, reprint.
/// The desk must re-check the operator's PIN session on every mutating
/// handler regardless of what this returns. Tracked as audit issue #16.
Future<bool> requirePinIfNeeded(
  BuildContext context,
  WidgetRef ref,
  String action,
) async {
  final flags = ref.read(flagsProvider);

  if (!flags.operatorPinAuth) return true;

  bool required = false;
  switch (action) {
    case 'kot':
      required = flags.operatorPinKot;
      break;
    case 'hold':
      required = flags.operatorPinHold;
      break;
    case 'kot_and_bill':
      required = flags.operatorPinKotAndBill;
      break;
    case 'cancel_order':
      required = flags.operatorPinCancelOrder;
      break;
    case 'generate_bill':
      required = flags.operatorPinGenerateBill;
      break;
    case 'payment':
      required = flags.operatorPinPayment;
      break;
    case 'kot_edit':
    // Shifting a fired round mutates the same KOT the edit gate protects, so
    // it reuses that gate rather than adding a toggle admins must find.
    case 'kot_shift':
      required = flags.operatorPinKotEdit;
      break;
    case 'quick_settle':
      required = flags.operatorPinQuickSettle;
      break;
    case 'kot_reprint':
      required = flags.operatorPinKotReprint;
      break;
    case 'bill_reprint':
      required = flags.operatorPinBillReprint;
      break;
    case 'rename_table':
      required = flags.operatorPinRenameTable;
      break;
    case 'table_shift':
    case 'table_merge':
      required = flags.operatorPinKot;
      break;
    default:
      // Unknown action. The old code let it through; an action name typo in
      // a new call site therefore silently disabled its PIN gate. Fail
      // closed instead — a spurious prompt is recoverable, a missing one
      // is not.
      required = true;
  }

  if (!required) return true;

  if (flags.operatorPinMode == 'session') {
    final verifiedAt = ref.read(pinVerifiedAtProvider);
    final minutes = flags.operatorPinSessionMinutes;
    if (verifiedAt != null &&
        DateTime.now().difference(verifiedAt).inMinutes < minutes) {
      return true;
    }
  }

  final result = await PinVerifySheet.show(context, action: action);
  if (result == true && flags.operatorPinMode == 'session') {
    ref.read(pinVerifiedAtProvider.notifier).state = DateTime.now();
  }
  return result ?? false;
}
