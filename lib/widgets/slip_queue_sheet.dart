import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/pending_slips_store.dart';
import '../services/slip_printer.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

/// How a slip still owed to a guest reads in the list.
String slipJobLabel(SlipJob job) {
  if (job.isUnknown) return 'May have printed';
  return switch (job.state) {
    SlipJobState.pending => 'Not printed yet',
    SlipJobState.failed => "Didn't print",
    SlipJobState.printing => 'Printing…',
    SlipJobState.printed => 'Printed',
  };
}

/// The slips this phone still owes guests: not printed yet, failed, or
/// unknown (the app stopped mid-print, so they may have printed). Print them
/// again, or remove one once it is handled (the QR on screen, or Recent).
class SlipQueueSheet {
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => const _SlipQueueSheet(),
    );
  }
}

class _SlipQueueSheet extends ConsumerStatefulWidget {
  const _SlipQueueSheet();

  @override
  ConsumerState<_SlipQueueSheet> createState() => _SlipQueueSheetState();
}

class _SlipQueueSheetState extends ConsumerState<_SlipQueueSheet> {
  bool _printing = false;

  Future<void> _printAll(List<SlipJob> jobs) async {
    if (_printing || jobs.isEmpty) return;
    if (jobs.any((j) => j.isUnknown)) {
      final again = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          backgroundColor: dialog.palette.surface,
          title: const Text('Print again?', style: AppTypography.title),
          content: const Text(
              'Some of these may already have printed. A second copy works '
              'like the first: whoever scans it first gets in, and can '
              'spend its cover.',
              style: AppTypography.bodyMd),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Print'),
            ),
          ],
        ),
      );
      if (again != true || !mounted) return;
    }
    setState(() => _printing = true);
    final result = await ref
        .read(slipPrinterProvider)
        .printSlips(<TicketSlip>[for (final job in jobs) job.toSlip()]);
    if (!mounted) return;
    setState(() => _printing = false);
    if (result.allPrinted) {
      DynamicToast.success(context, 'Printed ${result.printed.length}');
    } else {
      DynamicToast.warning(context,
          "${result.failed.length} didn't print — check the printer and try again");
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final jobs = ref.watch(unprintedSlipsProvider);
    final printer = ref.watch(slipPrinterProvider);
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + context.sheetBottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            const Text('Slips not printed', style: AppTypography.sheetTitle),
            const SizedBox(height: 4),
            Text(
                'Sold, but their slips did not print on this phone. Each '
                "ticket's QR also shows on screen from Recent.",
                style: palette.caption),
            const SizedBox(height: 8),
            if (jobs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('Every slip has printed.',
                    style: AppTypography.bodyMd.copyWith(color: palette.ink70)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final job in jobs)
                      ListTile(
                        key: ValueKey<String>('slip-job-${job.ticketId}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(job.ticketNumber,
                            style: AppTypography.bodyMd
                                .copyWith(fontWeight: FontWeight.w700)),
                        subtitle: Text(slipJobLabel(job),
                            style: palette.caption.copyWith(
                                color: job.isUnknown
                                    ? AppColors.warn
                                    : palette.ink50)),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: Icon(Icons.close, color: palette.ink50),
                          onPressed: _printing
                              ? null
                              : () => ref
                                  .read(slipJobsProvider.notifier)
                                  .remove(<String>[job.ticketId]),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (!printer.isReady)
              LiquidSecondaryButton(
                label: 'Set up printer',
                leadingIcon: Icons.print_outlined,
                onPressed: () {
                  final router = GoRouter.of(context);
                  Navigator.of(context).pop();
                  unawaited(router.push('/printer-settings'));
                },
              )
            else if (jobs.isNotEmpty)
              LiquidPrimaryButton(
                key: const ValueKey<String>('slip-queue-print'),
                label: _printing ? 'Printing…' : 'Print ${jobs.length}',
                leadingIcon: Icons.print_outlined,
                fullWidth: true,
                onPressed: _printing ? null : () => _printAll(jobs),
              ),
          ],
        ),
      ),
    );
  }
}
