import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/tokens.dart';
import 'app_surface.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

/// Gets one code from the operator: scanned with the camera, or typed (a
/// ticket number when the QR is torn or the camera is not allowed). Returns
/// it trimmed, or null when dismissed. The camera only starts when asked.
class QrCapture {
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String hint,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _QrCaptureSheet(title: title, hint: hint),
    );
  }
}

class _QrCaptureSheet extends StatefulWidget {
  final String title;
  final String hint;

  const _QrCaptureSheet({required this.title, required this.hint});

  @override
  State<_QrCaptureSheet> createState() => _QrCaptureSheetState();
}

class _QrCaptureSheetState extends State<_QrCaptureSheet> {
  final TextEditingController _typed = TextEditingController();
  MobileScannerController? _scanner;
  bool _done = false;

  void _finish(String? raw) {
    final code = raw?.trim() ?? '';
    if (_done || code.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(code);
  }

  void _startScan() {
    setState(() => _scanner = MobileScannerController(
          detectionSpeed: DetectionSpeed.noDuplicates,
          formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
        ));
  }

  @override
  void dispose() {
    _scanner?.dispose();
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scanner = _scanner;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + context.sheetBottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            Text(widget.title, style: AppTypography.sheetTitle),
            const SizedBox(height: 12),
            if (scanner != null)
              ClipRRect(
                borderRadius: const BorderRadius.all(AppRadii.md),
                child: SizedBox(
                  height: 220,
                  child: MobileScanner(
                    controller: scanner,
                    onDetect: (capture) {
                      for (final code in capture.barcodes) {
                        final raw = code.rawValue;
                        if (raw != null && raw.trim().isNotEmpty) {
                          _finish(raw);
                          return;
                        }
                      }
                    },
                    errorBuilder: (_, __) => ColoredBox(
                      color: AppColors.ink,
                      child: Center(
                        child: Text(
                          'Camera unavailable — type the code instead',
                          textAlign: TextAlign.center,
                          style: AppTypography.caption
                              .copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              LiquidSecondaryButton(
                label: 'Scan QR',
                leadingIcon: Icons.qr_code_scanner,
                onPressed: _startScan,
              ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: context.palette.surface,
                    borderRadius: const BorderRadius.all(AppRadii.sm),
                    border:
                        Border.all(color: context.palette.hairline, width: 1.5),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _typed,
                    style: AppTypography.bodyMd,
                    cursorColor: AppColors.terra,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    onSubmitted: _finish,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: widget.hint,
                      hintStyle: AppTypography.caption,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              LiquidPrimaryButton(
                label: 'Use',
                onPressed: () => _finish(_typed.text),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
