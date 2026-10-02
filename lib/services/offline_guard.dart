import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../widgets/dynamic_toast.dart';
import 'socket_service.dart';

/// What the operator is told when they reach for something only the desk can do.
const String kNeedsDeskMessage = 'Needs the desk — will work when the desk is back';

/// Tail of every "queued on this phone" message: one phrasing, shared with
/// [kNeedsDeskMessage], the banner and the offline KOT messages ("…when the
/// desk is back"). Compose as `'… will send $kAutoWhenDeskBack'`.
const String kAutoWhenDeskBack = 'automatically when the desk is back.';

/// True when the desk cannot vouch for an action right now: the socket is not
/// verified (down, still connecting, or connected but not yet re-verified).
/// Taking an order and sending its KOT is NOT such an action — it queues in the
/// outbox — but a bill, a payment, a cancel, a table shift or a discount must
/// be confirmed by the desk and never be faked offline. A demo pairing has no
/// real socket and is never "offline".
bool isDeskOffline(WidgetRef ref) {
  if (ref.read(socketServiceProvider).state == SocketState.verified) {
    return false;
  }
  final pairing = ref.read(connectionBootstrapProvider.notifier).currentPairing;
  return pairing?.token != 'demo-token';
}

/// Gate for a desk-only action: returns true to proceed, or shows the
/// immediate "needs the desk" message and returns false. Before this existed
/// these paths waited (up to minutes) for a reconnect behind a spinner.
bool requireDesk(BuildContext context, WidgetRef ref) {
  if (!isDeskOffline(ref)) return true;
  DynamicToast.show(context,
      message: kNeedsDeskMessage,
      kind: ToastKind.warning,
      duration: const Duration(seconds: 2));
  return false;
}
