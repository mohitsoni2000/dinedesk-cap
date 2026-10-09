import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bt_printer_service.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

bool get _iPhone => defaultTargetPlatform == TargetPlatform.iOS;

/// What to tell the usher when Bluetooth cannot be used.
String btAvailabilityMessage(BtAvailability availability) =>
    switch (availability) {
      BtAvailability.ready => 'Bluetooth is on.',
      BtAvailability.off => 'Bluetooth is off. Turn it on, then try again.',
      BtAvailability.denied => _iPhone
          ? 'Allow Bluetooth for Command.Crew in the iPhone Settings, then '
              'try again.'
          : 'Allow "Nearby devices" for Command.Crew in the phone Settings, '
              'then try again.',
      BtAvailability.unsupported =>
        'Bluetooth printing is not available on this device.',
    };

/// Where the printer has to be for the phone to see it.
String get btPrinterHint => _iPhone
    ? 'An iPhone only sees Bluetooth LE (BLE) printers. Switch the printer '
        'on and keep it close.'
    : 'Pair the printer in Android Bluetooth settings first (PIN is often '
        '0000 or 1234), then pick it here.';

/// Picks the slip printer: checks Bluetooth (asking for the permission the
/// first time), lists what the phone can see (Android: printers paired in
/// its Bluetooth settings; iPhone: BLE devices nearby, a few seconds'
/// search) and returns the one tapped, or null.
class BtPrinterPickerSheet {
  static Future<BtPrinterInfo?> show(BuildContext context,
      {BtPrinterInfo? current}) {
    return showModalBottomSheet<BtPrinterInfo>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => _PickerSheet(current: current),
    );
  }
}

class _PickerSheet extends ConsumerStatefulWidget {
  const _PickerSheet({this.current});

  final BtPrinterInfo? current;

  @override
  ConsumerState<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends ConsumerState<_PickerSheet> {
  bool _searching = true;
  BtAvailability? _availability;
  List<BtPrinterInfo> _found = const <BtPrinterInfo>[];

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final bluetooth = ref.read(bluetoothPrinterProvider);
    final availability = await bluetooth.availability();
    final found = availability == BtAvailability.ready
        ? await bluetooth.discover()
        : const <BtPrinterInfo>[];
    if (!mounted) return;
    setState(() {
      _searching = false;
      _availability = availability;
      // Named devices first: a printer is found by its name.
      _found = <BtPrinterInfo>[
        ...found.where((p) => p.name != 'Unnamed device'),
        ...found.where((p) => p.name == 'Unnamed device'),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final availability = _availability;
    final Widget body;
    if (_searching) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
          Text('Looking for printers…', style: palette.caption),
        ]),
      );
    } else if (availability != BtAvailability.ready) {
      body = _Notice(
        text: btAvailabilityMessage(availability ?? BtAvailability.unsupported),
        action: 'Try again',
        onAction: _search,
      );
    } else if (_found.isEmpty) {
      body = _Notice(
        text: 'No printers found. $btPrinterHint',
        action: 'Search again',
        onAction: _search,
      );
    } else {
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final printer in _found)
              ListTile(
                key: ValueKey<String>('bt-printer-${printer.address}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.print_outlined, color: palette.ink70),
                title: Text(printer.name, style: AppTypography.bodyMd),
                subtitle: Text(printer.address, style: palette.caption),
                trailing: printer == widget.current
                    ? const Icon(Icons.check_circle, color: AppColors.success)
                    : null,
                onTap: () => Navigator.of(context).pop(printer),
              ),
          ],
        ),
      );
    }

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
            const Text('Choose printer', style: AppTypography.sheetTitle),
            const SizedBox(height: 4),
            Text(btPrinterHint, style: palette.caption),
            const SizedBox(height: 12),
            body,
            if (!_searching && _found.isNotEmpty) ...[
              const SizedBox(height: 8),
              LiquidSecondaryButton(
                label: 'Search again',
                leadingIcon: Icons.refresh,
                onPressed: _search,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.text,
    required this.action,
    required this.onAction,
  });

  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: AppTypography.bodyMd),
          const SizedBox(height: 12),
          LiquidSecondaryButton(
            label: action,
            leadingIcon: Icons.refresh,
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}
