import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/bt_printer_service.dart';
import '../services/escpos_slip.dart';
import '../services/pending_slips_store.dart';
import '../services/ticket_slip_builder.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/bt_printer_picker_sheet.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/slip_queue_sheet.dart';

/// Settings › Slip printer: the Bluetooth printer the gate prints entry
/// slips on. Choose it (Android: paired in system settings first; iPhone: a
/// BLE printer), print a test page, pick the paper, and say whether slips
/// print after every sale, cut, and draw the QR as an image for printers
/// that garble the native one. Saved on this phone (`bt_printer_v1`).
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() =>
      _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  BtAvailability? _availability;
  bool? _connected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final bluetooth = ref.read(bluetoothPrinterProvider);
    final availability = await bluetooth.availability();
    final linked = await bluetooth.isConnected;
    if (!mounted) return;
    setState(() {
      _availability = availability;
      _connected = linked;
    });
  }

  BtPrinterSettingsNotifier get _settings =>
      ref.read(btPrinterSettingsProvider.notifier);

  Future<void> _update(BtPrinterSettings next) => _settings.update(next);

  Future<void> _choose() async {
    final current = ref.read(btPrinterSettingsProvider);
    final picked =
        await BtPrinterPickerSheet.show(context, current: current.printer);
    if (picked == null || !mounted) return;
    await _update(current.copyWith(printer: picked));
    await _run(() async {
      final linked = await ref.read(btPrinterServiceProvider).connect(picked);
      if (!mounted) return;
      setState(() => _connected = linked);
      if (linked) {
        DynamicToast.success(context, 'Connected to ${picked.name}');
      } else {
        DynamicToast.warning(context,
            "Saved, but couldn't connect — is ${picked.name} on and close by?");
      }
    });
  }

  Future<void> _testPrint() async {
    final settings = ref.read(btPrinterSettingsProvider);
    final printer = settings.printer;
    if (printer == null) return;
    await _run(() async {
      final results = await ref
          .read(btPrinterServiceProvider)
          .printSlips(printer, <List<int>>[testSlipBytes(settings)]);
      if (!mounted) return;
      final ok = results.isNotEmpty && results.first.ok;
      setState(() => _connected = ok);
      if (ok) {
        DynamicToast.success(context, 'Test page sent');
      } else {
        DynamicToast.error(context,
            "Couldn't print — check the printer is on, has paper and is close by");
      }
    });
  }

  Future<void> _disconnect() => _run(() async {
        await ref.read(btPrinterServiceProvider).disconnect();
        if (mounted) setState(() => _connected = false);
      });

  Future<void> _forget() => _run(() async {
        await ref.read(btPrinterServiceProvider).disconnect();
        await _update(
            ref.read(btPrinterSettingsProvider).copyWith(clearPrinter: true));
        if (mounted) setState(() => _connected = false);
      });

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final settings = ref.watch(btPrinterSettingsProvider);
    final printer = settings.printer;
    final unprinted = ref.watch(unprintedSlipsProvider).length;
    final availability = _availability;

    return ColoredBox(
      color: palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: PageContentClamp(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(children: [
                    IconButton(
                      tooltip: 'Back',
                      icon: Icon(Icons.arrow_back, color: palette.ink70),
                      onPressed: () => context.canPop()
                          ? context.pop()
                          : context.go('/settings'),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child:
                          Text('Slip printer', style: AppTypography.sheetTitle),
                    ),
                  ]),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      if (availability != null &&
                          availability != BtAvailability.ready) ...[
                        AppCard(
                          background: AppColors.amber.withValues(alpha: 0.10),
                          border: Border.all(
                              color: AppColors.amber.withValues(alpha: 0.4)),
                          child: Row(children: [
                            const Icon(Icons.bluetooth_disabled,
                                color: AppColors.warn, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(btAvailabilityMessage(availability),
                                  style: AppTypography.bodyMd),
                            ),
                            TextButton(
                              onPressed: _busy ? null : _check,
                              child: const Text('Check again'),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _PrinterCard(
                        printer: printer,
                        connected: _connected,
                        busy: _busy,
                        onChoose: _choose,
                        onTest: _testPrint,
                        onDisconnect: _disconnect,
                        onForget: _forget,
                      ),
                      if (unprinted > 0) ...[
                        const SizedBox(height: 12),
                        AppCard(
                          onTap: () => SlipQueueSheet.show(context),
                          child: Row(children: [
                            const Icon(Icons.receipt_long_outlined,
                                color: AppColors.warn, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                  '$unprinted ${unprinted == 1 ? 'slip' : 'slips'} '
                                  'not printed',
                                  style: AppTypography.bodyMd
                                      .copyWith(fontWeight: FontWeight.w600)),
                            ),
                            Icon(Icons.chevron_right, color: palette.ink50),
                          ]),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Text('PAPER',
                          style: AppTypography.micro
                              .copyWith(letterSpacing: 1.4)),
                      const SizedBox(height: 8),
                      SegmentedButton<SlipPaper>(
                        segments: const <ButtonSegment<SlipPaper>>[
                          ButtonSegment<SlipPaper>(
                              value: SlipPaper.mm58, label: Text('58 mm (2")')),
                          ButtonSegment<SlipPaper>(
                              value: SlipPaper.mm80, label: Text('80 mm (3")')),
                        ],
                        selected: <SlipPaper>{settings.paper},
                        showSelectedIcon: false,
                        onSelectionChanged: (picked) =>
                            _update(settings.copyWith(paper: picked.first)),
                      ),
                      const SizedBox(height: 20),
                      Text('SLIPS',
                          style: AppTypography.micro
                              .copyWith(letterSpacing: 1.4)),
                      const SizedBox(height: 8),
                      AppCard(
                        padding: EdgeInsets.zero,
                        child: Column(children: [
                          SwitchListTile(
                            key: const ValueKey<String>('bt-auto-print'),
                            value: settings.autoPrint,
                            activeThumbColor: AppColors.terra500,
                            title: const Text('Print after each sale',
                                style: AppTypography.bodyMd),
                            subtitle: Text(
                                'Slips print as soon as the desk confirms '
                                'the sale',
                                style: palette.caption),
                            onChanged: (v) =>
                                _update(settings.copyWith(autoPrint: v)),
                          ),
                          Divider(height: 1, color: palette.hairline),
                          SwitchListTile(
                            key: const ValueKey<String>('bt-auto-cut'),
                            value: settings.cuts,
                            activeThumbColor: AppColors.terra500,
                            title: const Text('Cut after each slip',
                                style: AppTypography.bodyMd),
                            subtitle: Text(
                                'Off for a portable printer with a tear bar',
                                style: palette.caption),
                            onChanged: (v) =>
                                _update(settings.copyWith(autoCut: v)),
                          ),
                          Divider(height: 1, color: palette.hairline),
                          SwitchListTile(
                            key: const ValueKey<String>('bt-raster-qr'),
                            value: settings.qrMode == SlipQrMode.raster,
                            activeThumbColor: AppColors.terra500,
                            title: const Text('Print the QR as an image',
                                style: AppTypography.bodyMd),
                            subtitle: Text(
                                'Turn on if the QR prints as garbage or not '
                                'at all. Slower.',
                                style: palette.caption),
                            onChanged: (v) => _update(settings.copyWith(
                                qrMode:
                                    v ? SlipQrMode.raster : SlipQrMode.native)),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      Text(btPrinterHint, style: palette.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.printer,
    required this.connected,
    required this.busy,
    required this.onChoose,
    required this.onTest,
    required this.onDisconnect,
    required this.onForget,
  });

  final BtPrinterInfo? printer;
  final bool? connected;
  final bool busy;
  final VoidCallback onChoose;
  final VoidCallback onTest;
  final VoidCallback onDisconnect;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final printer = this.printer;
    if (printer == null) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('No printer yet', style: AppTypography.title),
            const SizedBox(height: 4),
            Text(
                'Until one is chosen, each ticket\'s QR shows on screen '
                'instead.',
                style: palette.caption),
            const SizedBox(height: 12),
            LiquidPrimaryButton(
              key: const ValueKey<String>('bt-choose'),
              label: 'Choose printer',
              leadingIcon: Icons.bluetooth_searching,
              fullWidth: true,
              onPressed: busy ? null : onChoose,
            ),
          ],
        ),
      );
    }
    final linked = connected == true;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.print_outlined, color: palette.ink70),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(printer.name, style: AppTypography.title),
                  Text(printer.address, style: palette.caption),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: linked
                    ? AppColors.success.withValues(alpha: 0.12)
                    : palette.ink05,
                borderRadius: const BorderRadius.all(AppRadii.pill),
              ),
              child: Text(linked ? 'Connected' : 'Not connected',
                  style: AppTypography.caption
                      .copyWith(fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: LiquidPrimaryButton(
                key: const ValueKey<String>('bt-test-print'),
                label: busy ? 'Working…' : 'Test print',
                leadingIcon: Icons.print_outlined,
                fullWidth: true,
                onPressed: busy ? null : onTest,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LiquidSecondaryButton(
                label: 'Change',
                leadingIcon: Icons.swap_horiz,
                onPressed: busy ? null : onChoose,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: linked
                  ? TextButton(
                      onPressed: busy ? null : onDisconnect,
                      child: const Text('Disconnect'),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: TextButton(
                onPressed: busy ? null : onForget,
                child: const Text('Forget printer'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
