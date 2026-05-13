// PIN Guard — helper that checks feature flags and shows PIN verification
// before sensitive actions.
//
// Usage:
//   final ok = await requirePinIfNeeded(context, ref, 'kot');
//   if (!ok) return; // user cancelled or PIN failed

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../widgets/pin_verify_sheet.dart';

/// Returns true if the action is allowed to proceed (PIN verified or not
/// required), false if the user cancelled or verification failed.
Future<bool> requirePinIfNeeded(
  BuildContext context,
  WidgetRef ref,
  String action,
) async {
  final flags = ref.read(flagsProvider);

  // PIN auth disabled globally — always allow.
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
      required = flags.operatorPinKotEdit;
      break;
    case 'quick_settle':
      required = flags.operatorPinQuickSettle;
      break;
    default:
      return true;
  }

  if (!required) return true;

  // Show PIN sheet — returns true/false/null (null when dismissed).
  final result = await PinVerifySheet.show(context, action: action);
  return result ?? false;
}
