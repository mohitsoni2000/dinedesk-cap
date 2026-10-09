/// Parking and resuming ticket sales at the gate, for the Gate home and the
/// issue screen.
///
/// A parked sale lives on this phone (see ParkedDraftsStore), kind
/// [ParkedKind.ticketIssue]. Resuming one over a sale already on screen asks
/// first: park the current one and resume, replace it, or cancel. The parked
/// sheet takes the draft off the phone before it hands it back, and it is
/// applied at once (take, then apply).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/gate_providers.dart';
import '../../data/parked_providers.dart';
import '../../data/providers.dart';
import '../../models/parked_draft.dart';
import '../../services/parked_drafts_store.dart';
import '../../theme/tokens.dart';
import '../dynamic_toast.dart';
import '../parked_sheet.dart';

enum _SaleInProgress { parkAndResume, replace }

/// Parks the sale on screen and empties the form. Returns the parked
/// draft's label ("P3"), or null when nothing was parked; the reason has
/// been shown and the form is untouched.
Future<String?> parkTicketSale(BuildContext context, WidgetRef ref) async {
  final form = ref.read(ticketIssueFormProvider);
  final draft = ticketDraftOf(form, ref.read(ticketTypesProvider));
  if (draft.isEmpty) return null;
  try {
    final parked = await ref.read(parkedDraftsProvider.notifier).park(draft);
    if (identical(ref.read(ticketIssueFormProvider), form)) {
      ref.read(ticketIssueFormProvider.notifier).clear();
    }
    if (context.mounted) {
      DynamicToast.show(context,
          message: 'Parked as ${parked.label}', kind: ToastKind.success);
    }
    return parked.label;
  } on ParkedDraftsException catch (error) {
    if (context.mounted) DynamicToast.error(context, error.message);
    return null;
  }
}

/// Opens the parked ticket sales. A resumed one becomes the issue form.
/// Returns true when a sale was resumed.
///
/// The notifier is read up front and the draft applied with nothing awaited
/// after the sheet hands it back, so a screen that went away meanwhile
/// cannot lose it.
Future<bool> resumeTicketSale(BuildContext context, WidgetRef ref) async {
  final form = ref.read(ticketIssueFormProvider.notifier);
  if (ref.read(pendingTicketIssueProvider) != null) {
    DynamicToast.warning(context,
        'The last sale is not confirmed yet — retry or drop it first');
    return false;
  }
  final resumed = await showParkedSheet(
    context,
    kind: ParkedKind.ticketIssue,
    beforeResume: (draft) => _makeRoom(context, ref, draft),
  );
  final sale = resumed?.tickets;
  if (resumed == null || sale == null) return false;
  form.load(sale);
  if (context.mounted) {
    DynamicToast.show(context,
        message: resumed.resolved.needsAttention
            ? 'Resumed ${resumed.draft.label} with changes'
            : 'Resumed ${resumed.draft.label}',
        kind: ToastKind.success);
  }
  return true;
}

/// The parked sheet's "before resume" question, when a sale is on screen.
/// True lets the resume go on.
Future<bool> _makeRoom(
    BuildContext context, WidgetRef ref, ParkedDraft draft) async {
  final current = ref.read(ticketIssueFormProvider);
  final types = ref.read(ticketTypesProvider);
  final lines = current.linesOn(types);
  if (lines.isEmpty) return true;
  final units = lines.fold<int>(0, (sum, line) => sum + line.qty);
  final choice = await showDialog<_SaleInProgress>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: dialog.palette.surface,
      title: const Text('Sale in progress', style: AppTypography.title),
      content: Text(
          'There ${units == 1 ? 'is 1 ticket' : 'are $units tickets'} on '
          'screen. Park them before ${draft.label} comes back?',
          style: AppTypography.bodyMd),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(_SaleInProgress.replace),
          child:
              const Text('Replace', style: TextStyle(color: AppColors.danger)),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialog).pop(_SaleInProgress.parkAndResume),
          child: const Text('Park current and resume'),
        ),
      ],
    ),
  );
  if (choice == null) return false;
  if (choice == _SaleInProgress.replace) return true;
  // A full parking lot throws (ParkedCapReached): the sheet shows why and
  // nothing changes.
  await ref
      .read(parkedDraftsProvider.notifier)
      .park(ticketDraftOf(current, types));
  // Parked: empty the screen now, so a resume that then fails leaves it
  // parked, not both parked and on screen.
  if (identical(ref.read(ticketIssueFormProvider), current)) {
    ref.read(ticketIssueFormProvider.notifier).clear();
  }
  return true;
}
