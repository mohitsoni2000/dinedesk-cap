import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
/// print, and once all have, offers a reprint after a duplicate warning.
class SlipPrintButton extends ConsumerStatefulWidget {
  const SlipPrintButton({super.key, required this.slips});

  final List<TicketSlip> slips;

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
              'These slips have already printed. A second copy is harmless: '
              'each ticket still lets one guest in.',
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
    setState(() => _printing = true);
    try {
      final result = await printer.printSlips(batch);
      if (!mounted) return;
      if (result.allPrinted) {
        DynamicToast.success(context,
            'Printed ${result.printed.length} ${_slips(result.printed.length)}');
      } else {
        DynamicToast.warning(
            context,
            "${result.failed.length} ${_slips(result.failed.length)} didn't "
            'print — show the QR on screen, or try again');
      }
    } catch (error) {
      logE('[Gate]', 'slip print failed', error.runtimeType);
      if (mounted) DynamicToast.error(context, "Couldn't print the slips");
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  static String _slips(int n) => n == 1 ? 'slip' : 'slips';

  @override
  Widget build(BuildContext context) {
    final printer = ref.watch(slipPrinterProvider);
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
    final reprint = owed.isEmpty;
    final batch = reprint ? widget.slips : owed;
    final n = batch.length;
    return LiquidSecondaryButton(
      label: busy
          ? 'Printing…'
          : '${reprint ? 'Reprint' : 'Print'} $n ${_slips(n)}',
      leadingIcon: Icons.print_outlined,
      onPressed: busy || n == 0
          ? null
          : () => _print(printer, batch, reprint: reprint),
    );
  }
}
