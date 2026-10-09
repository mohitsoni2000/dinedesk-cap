import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/log.dart';
import '../../services/slip_printer.dart';
import '../dynamic_toast.dart';
import '../liquid_chrome.dart';

/// Print for [slips], through the [SlipPrinter] seam. Until a printer is set
/// up it stays disabled and says so; the QR is on screen meanwhile.
class SlipPrintButton extends ConsumerStatefulWidget {
  const SlipPrintButton({super.key, required this.slips});

  final List<TicketSlip> slips;

  @override
  ConsumerState<SlipPrintButton> createState() => _SlipPrintButtonState();
}

class _SlipPrintButtonState extends ConsumerState<SlipPrintButton> {
  bool _printing = false;

  Future<void> _print(SlipPrinter printer) async {
    if (_printing || widget.slips.isEmpty) return;
    setState(() => _printing = true);
    try {
      final result = await printer.printSlips(widget.slips);
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
      return const LiquidSecondaryButton(
        label: 'Set up printer',
        leadingIcon: Icons.print_disabled_outlined,
        onPressed: null,
      );
    }
    final n = widget.slips.length;
    return LiquidSecondaryButton(
      label: _printing ? 'Printing…' : 'Print $n ${_slips(n)}',
      leadingIcon: Icons.print_outlined,
      onPressed: _printing || n == 0 ? null : () => _print(printer),
    );
  }
}
