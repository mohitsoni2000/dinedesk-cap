import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../services/entry_ticket_service.dart';
import '../../services/log.dart';
import '../../services/pending_slips_store.dart';
import '../../services/slip_printer.dart';
import '../../theme/tokens.dart';
import '../dynamic_toast.dart';
import '../liquid_chrome.dart';

/// Print for [slips], through the [SlipPrinter] seam. Without a printer it
/// says so and opens the printer settings; the QR is on screen meanwhile.
/// While the slips are on their way to the printer (after a sale, with
/// auto-print) it waits; afterwards it prints only those that did not
/// print, and once all have, offers a reprint after a warning.
///
/// A reprint needs issue rights, and each slip that prints again goes on
/// the desk's audit trail (`ticket:log_reprint`): a copy works like the
/// original.
class SlipPrintButton extends ConsumerStatefulWidget {
  const SlipPrintButton({
    super.key,
    required this.slips,
    this.reprintOnly = false,
  });

  final List<TicketSlip> slips;

  /// Every print here copies a slip already handed out (today's list), so
  /// it is a reprint whatever this phone printed before.
  final bool reprintOnly;

  @override
  ConsumerState<SlipPrintButton> createState() => _SlipPrintButtonState();
}

class _SlipPrintButtonState extends ConsumerState<SlipPrintButton> {
  bool _printing = false;

  Future<void> _print(SlipPrinter printer, List<TicketSlip> batch,
      {required bool reprint}) async {
    if (_printing || batch.isEmpty) return;
    if (reprint) {
      final again = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          backgroundColor: dialog.palette.surface,
          title: const Text('Print again?', style: AppTypography.title),
          content: const Text(
              'A copy works like the original: whoever scans it first gets '
              'in, and can spend its cover. The reprint is recorded on the '
              'desk.',
              style: AppTypography.bodyMd),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Reprint'),
            ),
          ],
        ),
      );
      if (again != true || !mounted) return;
    }
    final tickets = ref.read(entryTicketServiceProvider);
    // The app's own overlay: the result still shows if this sheet closed.
    final overlay = Overlay.of(context, rootOverlay: true);
    void toast(String message, ToastKind kind) {
      if (overlay.mounted) {
        DynamicToast.showOn(overlay, message: message, kind: kind);
      }
    }

    setState(() => _printing = true);
    try {
      final result = await printer.printSlips(batch);
      // After the print, never before: only a copy that exists is logged.
      final unrecorded =
          reprint ? await _logReprints(tickets, result.printed) : 0;
      const notRecorded = "The desk didn't record the reprint.";
      if (!result.allPrinted) {
        final n = result.failed.length;
        toast(
            "$n ${_slips(n)} didn't print — show the QR on screen, or try "
            'again${unrecorded > 0 ? '. $notRecorded' : ''}',
            ToastKind.warning);
      } else if (unrecorded > 0) {
        final n = result.printed.length;
        toast('Printed $n ${_slips(n)}. $notRecorded', ToastKind.warning);
      } else {
        final n = result.printed.length;
        toast('Printed $n ${_slips(n)}', ToastKind.success);
      }
    } catch (error) {
      logE('[Gate]', 'slip print failed', error.runtimeType);
      toast("Couldn't print the slips", ToastKind.error);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  /// Puts each slip that printed again on the desk's audit trail, one entry
  /// (and one request id) per slip; how many the desk did not record.
  static Future<int> _logReprints(
      EntryTicketService tickets, List<String> printed) async {
    var unrecorded = 0;
    for (final ticketId in printed) {
      if (!await tickets.logReprint(TicketReprintLog(ticketId: ticketId))) {
        unrecorded++;
      }
    }
    if (unrecorded > 0) {
      logE('[Gate]', '$unrecorded reprint(s) not recorded on the desk');
    }
    return unrecorded;
  }

  static String _slips(int n) => n == 1 ? 'slip' : 'slips';

  @override
  Widget build(BuildContext context) {
    final printer = ref.watch(slipPrinterProvider);
    final canCopy = ref.watch(flagsProvider.select((f) => f.canCopyTickets));
    if (!printer.isReady) {
      return LiquidSecondaryButton(
        label: 'Set up printer',
        leadingIcon: Icons.print_disabled_outlined,
        onPressed: () => context.push('/printer-settings'),
      );
    }
    final byTicket = <String, SlipJob>{
      for (final job in ref.watch(slipJobsProvider)) job.ticketId: job,
    };
    final busy = _printing ||
        widget.slips.any((s) => byTicket[s.ticketId]?.isPrintingNow ?? false);
    // Only the slips still owed print again; once every one has printed,
    // a reprint of them all, after a warning.
    final owed = <TicketSlip>[
      for (final slip in widget.slips)
        if (byTicket[slip.ticketId]?.state != SlipJobState.printed) slip,
    ];
    final reprint = widget.reprintOnly || owed.isEmpty;
    final batch = reprint ? widget.slips : owed;
    final n = batch.length;
    // A copy needs issue rights: check-in rights alone never print one.
    final allowed = !reprint || canCopy;
    return LiquidSecondaryButton(
      label: busy
          ? 'Printing…'
          : '${reprint ? 'Reprint' : 'Print'} $n ${_slips(n)}',
      leadingIcon: Icons.print_outlined,
      onPressed: busy || n == 0 || !allowed
          ? null
          : () => _print(printer, batch, reprint: reprint),
    );
  }
}
