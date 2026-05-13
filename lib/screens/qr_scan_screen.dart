// QR Scan Screen — entry point for device pairing.
//
// Operator scans the rotating pairing QR shown on the admin desktop. On a
// successful scan we navigate to /connecting which simulates the WS handshake
// and then continues to /auth for username + PIN.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/help_sheet.dart';

enum _ScanError { invalid, expired, used }

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});
  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _torchOn = false;
  bool _processing = false;
  _ScanError? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_processing) return;
    final raw =
        capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null) return;

    if (!raw.startsWith('restroapp://pair?')) {
      _showError(_ScanError.invalid);
      return;
    }

    // Parse host, port, token from QR URI.
    final uri = Uri.parse(raw);
    final host = uri.queryParameters['host'];
    final portStr = uri.queryParameters['port'];
    final token = uri.queryParameters['token'];

    if (host == null || portStr == null || token == null) {
      _showError(_ScanError.invalid);
      return;
    }

    final port = int.tryParse(portStr);
    if (port == null) {
      _showError(_ScanError.invalid);
      return;
    }

    setState(() {
      _processing = true;
      _error = null;
    });
    HapticFeedback.mediumImpact();

    // Save pairing info then navigate.
    SessionService().savePairing(PairingInfo(host: host, port: port, token: token)).then((_) {
      if (!mounted) return;
      context.go('/connecting');
    });
  }

  void _showError(_ScanError err) {
    setState(() => _error = err);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _error = null);
    });
  }

  // Demo bypass — tap top-right to simulate a successful scan even without a real QR.
  void _demoScan() {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    HapticFeedback.mediumImpact();

    // Save test pairing info for demo mode.
    SessionService().savePairing(
      const PairingInfo(host: 'localhost', port: 3111, token: 'demo-token'),
    ).then((_) {
      if (!mounted) return;
      context.go('/connecting');
    });
  }

  String _errorLabel(_ScanError err) => switch (err) {
        _ScanError.invalid => 'Not a Restro pairing QR',
        _ScanError.expired => 'QR expired — ask for a fresh one',
        _ScanError.used => 'QR already used — get a new one',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(
        children: [
          // Camera fills the screen.
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (_, __) => Container(
                color: AppColors.ink,
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.no_photography_outlined,
                          color: Colors.white70, size: 48),
                      const SizedBox(height: 16),
                      Text('Camera unavailable',
                          style: AppTypography.title
                              .copyWith(color: Colors.white)),
                      const SizedBox(height: 8),
                      Text(
                          'Allow camera access in Settings to pair this device.',
                          textAlign: TextAlign.center,
                          style: AppTypography.caption.copyWith(
                              color: Colors.white.withValues(alpha: 0.7))),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Dimming layer + scan target cutout.
          const Positioned.fill(child: _ScanTargetOverlay()),

          // Drifting mesh tint behind chrome (subtle).
          const IgnorePointer(
            child: Opacity(
              opacity: 0.18,
              child: LiquidMeshBackground(
                  dark: true, child: SizedBox.shrink()),
            ),
          ),

          // Top chrome — title, torch, demo bypass.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pair Device',
                            style: AppTypography.displayMd
                                .copyWith(color: Colors.white)),
                        const SizedBox(height: 4),
                        Text('Scan the QR shown on the admin desktop',
                            style: AppTypography.caption.copyWith(
                                color: Colors.white.withValues(alpha: 0.7))),
                      ],
                    ),
                  ),
                  _GlassIcon(
                    icon: _torchOn ? Icons.flash_on : Icons.flash_off,
                    onTap: () {
                      _controller.toggleTorch();
                      setState(() => _torchOn = !_torchOn);
                    },
                  ),
                  const SizedBox(width: 8),
                  _GlassIcon(icon: Icons.touch_app_outlined, onTap: _demoScan),
                ],
              ),
            ),
          ),

          // Bottom chrome — help link + inline error toast.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null)
                      _ErrorToast(label: _errorLabel(_error!)),
                    if (_error != null) const SizedBox(height: 12),
                    LiquidGlassSurface(
                      borderRadius: const BorderRadius.all(AppRadii.md),
                      blur: 24,
                      thickness: 12,
                      tint: Colors.white.withValues(alpha: 0.06),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      onTap: () => HelpSheet.show(context),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.help_outline,
                              color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Text('Need help?',
                              style: AppTypography.bodyMd
                                  .copyWith(color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanTargetOverlay extends StatelessWidget {
  const _ScanTargetOverlay();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final size = c.maxWidth * 0.66;
      return Stack(
        alignment: Alignment.center,
        children: [
          // Dim everything outside the target.
          ColorFiltered(
            colorFilter: ColorFilter.mode(
              Colors.black.withValues(alpha: 0.55),
              BlendMode.srcOut,
            ),
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    backgroundBlendMode: BlendMode.dstOut,
                  ),
                ),
                Center(
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Corner brackets.
          SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _BracketPainter()),
          ),
        ],
      );
    });
  }
}

class _BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.terra400
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    const arm = 26.0;
    final w = size.width, h = size.height;

    // top-left
    canvas.drawLine(const Offset(0, arm), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(arm, 0), paint);
    // top-right
    canvas.drawLine(Offset(w - arm, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, arm), paint);
    // bottom-left
    canvas.drawLine(Offset(0, h - arm), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(arm, h), paint);
    // bottom-right
    canvas.drawLine(Offset(w - arm, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - arm), paint);
  }

  @override
  bool shouldRepaint(_) => false;
}

class _GlassIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassIcon({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      blur: 22,
      thickness: 10,
      tint: Colors.white.withValues(alpha: 0.08),
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

class _ErrorToast extends StatelessWidget {
  final String label;
  const _ErrorToast({required this.label});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.md),
      blur: 24,
      thickness: 12,
      tint: AppColors.danger.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label,
                style: AppTypography.bodyMd.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
