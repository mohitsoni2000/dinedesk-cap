/// Parking and resuming counter carts, for the Counter home and the builder.
///
/// A parked cart lives on this phone (see ParkedDraftsStore). Resuming one
/// with a cart already on screen asks first: park the current one and
/// resume, replace it, or cancel (blueprint §4.6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/counter_providers.dart';
import '../data/parked_providers.dart';
import '../data/providers.dart';
import '../models/parked_draft.dart';
import '../services/parked_drafts_store.dart';
import '../theme/tokens.dart';
import 'dynamic_toast.dart';
import 'parked_sheet.dart';

/// What to do with the cart on screen before a parked one comes back.
enum _CartInProgress { parkAndResume, replace }

/// At the parking cap: what to do instead of parking the cart on screen.
enum _AtCap { replace, discardFirst }

CounterCartDraft _draftOfCart(WidgetRef ref, List<CartLine> cart) =>
    CounterCartDraft.fromCart(
      cart,
      notes: ref.read(orderNotesProvider),
      fulfillment: ref.read(counterFulfillmentProvider),
    );

/// Empties the cart, unless it changed since [was] was read.
void _clearIfUnchanged(WidgetRef ref, List<CartLine> was) {
  if (!identical(ref.read(cartProvider), was)) return;
  ref.read(cartProvider.notifier).clear();
  ref.read(orderNotesProvider.notifier).state = '';
}

/// Parks the cart on screen, with its note and how it leaves, and empties
/// it. Returns the parked draft's label ("P3"), or null when nothing was
/// parked; the reason has been shown and the cart is untouched.
Future<String?> parkCounterCart(BuildContext context, WidgetRef ref) async {
  final cart = ref.read(cartProvider);
  if (cart.isEmpty) return null;
  try {
    final draft = await ref
        .read(parkedDraftsProvider.notifier)
        .park(_draftOfCart(ref, cart));
    _clearIfUnchanged(ref, cart);
    if (context.mounted) {
      DynamicToast.show(context,
          message: 'Parked as ${draft.label}', kind: ToastKind.success);
    }
    return draft.label;
  } on ParkedDraftsException catch (error) {
    if (context.mounted) DynamicToast.error(context, error.message);
    return null;
  }
}

/// Opens the parked carts. A resumed one becomes the cart, with its note and
/// how it leaves. Returns true when a cart was resumed.
///
/// The sheet has already taken the draft off the phone when it hands it
/// back, so it is applied at once, with nothing awaited in between; the
/// notifiers are read up front so a screen that went away meanwhile cannot
/// lose it.
Future<bool> resumeCounterCart(BuildContext context, WidgetRef ref) async {
  final cartNotifier = ref.read(cartProvider.notifier);
  final notes = ref.read(orderNotesProvider.notifier);
  final fulfillment = ref.read(counterFulfillmentProvider.notifier);
  final resumed = await showParkedSheet(
    context,
    kind: ParkedKind.counterCart,
    beforeResume: (draft) => _makeRoom(context, ref, draft),
  );
  final cart = resumed?.cart;
  if (resumed == null || cart == null) return false;
  cartNotifier.replaceAll(cart.lines);
  notes.state = cart.notes;
  final leaves = cart.fulfillment;
  if (leaves != null) await fulfillment.set(leaves);
  if (context.mounted) {
    DynamicToast.show(context,
        message: resumed.resolved.needsAttention
            ? 'Resumed ${resumed.draft.label} with changes'
            : 'Resumed ${resumed.draft.label}',
        kind: ToastKind.success);
  }
  return true;
}

/// The parked sheet's "before resume" question, when a cart is on screen.
/// True lets the resume go on.
Future<bool> _makeRoom(
    BuildContext context, WidgetRef ref, ParkedDraft draft) async {
  final current = ref.read(cartProvider);
  if (current.isEmpty) return true;
  final count = current.fold<int>(0, (sum, line) => sum + line.qty);
  final choice = await showDialog<_CartInProgress>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: dialog.palette.surface,
      title: const Text('Cart in progress', style: AppTypography.title),
      content: Text(
          'There ${count == 1 ? 'is 1 item' : 'are $count items'} in the '
          'cart. Park them before ${draft.label} comes back?',
          style: AppTypography.bodyMd),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(_CartInProgress.replace),
          child:
              const Text('Replace', style: TextStyle(color: AppColors.danger)),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialog).pop(_CartInProgress.parkAndResume),
          child: const Text('Park current and resume'),
        ),
      ],
    ),
  );
  if (choice == null) return false;
  if (choice == _CartInProgress.replace) return true;
  try {
    await ref
        .read(parkedDraftsProvider.notifier)
        .park(_draftOfCart(ref, current));
  } on ParkedCapReached catch (cap) {
    if (!context.mounted) return false;
    return await _replaceAtCap(context, draft, cap.limit);
  }
  // It is parked: empty the screen now, so a resume that then fails leaves
  // it parked, not both parked and on screen.
  _clearIfUnchanged(ref, current);
  return true;
}

/// Every parking slot is taken, so the cart on screen cannot be parked.
/// True replaces it with [draft]; false keeps everything as it is, so the
/// cashier can discard a parked cart in the sheet first.
Future<bool> _replaceAtCap(
    BuildContext context, ParkedDraft draft, int limit) async {
  final choice = await showDialog<_AtCap>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: dialog.palette.surface,
      title: const Text('Parking is full', style: AppTypography.title),
      content: Text(
          'You already have $limit parked carts, so the cart on screen '
          "can't be parked. Replace it with ${draft.label} (the cart on "
          'screen is lost), or discard a parked cart first.',
          style: AppTypography.bodyMd),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(_AtCap.discardFirst),
          child: const Text('Discard a parked cart first'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(_AtCap.replace),
          child: const Text('Replace current cart',
              style: TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  return choice == _AtCap.replace;
}
