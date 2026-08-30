import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/qr_scan_controller.dart';
import '../../theme/tokens.dart';
import '../liquid_glass_surface.dart';

class QrScanTargetOverlay extends StatefulWidget {
  final ScanStage stage;
  final String? errorLabel;
  final int shakeTrigger;

  const QrScanTargetOverlay({
    super.key,
    this.stage = ScanStage.idle,
    this.errorLabel,
    this.shakeTrigger = 0,
  });

  @override
  State<QrScanTargetOverlay> createState() => _QrScanTargetOverlayState();
}

class _QrScanTargetOverlayState extends State<QrScanTargetOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _scanCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  @override
  void didUpdateWidget(covariant QrScanTargetOverlay old) {
    super.didUpdateWidget(old);
    if (widget.shakeTrigger != old.shakeTrigger) {
      _shakeCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  bool get _hasError => widget.errorLabel != null;

  bool get _isBusy =>
      widget.stage == ScanStage.checking ||
      widget.stage == ScanStage.verified;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (_, c) {
          final size = c.maxWidth * 0.66;
          final centerY = c.maxHeight * 0.40;
          final frameTop = centerY - size / 2;

          final frameColor = _hasError
              ? AppColors.danger
              : widget.stage == ScanStage.verified
                  ? AppColors.success
                  : AppColors.terra400;

          final frameCenter = Alignment(
            0,
            (centerY - c.maxHeight / 2) / (c.maxHeight / 2),
          );

          return Stack(
            children: [
              // Cutout Hole Layer (24px rounded corners)
              ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.60),
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
                    Align(
                      alignment: frameCenter,
                      child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Viewfinder Frame & Animated Scan Line
              Align(
                alignment: frameCenter,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_scanCtrl, _shakeCtrl]),
                  builder: (_, child) {
                    final breath = _isBusy || _hasError
                        ? 1.0
                        : 1.0 +
                            0.012 * Curves.easeInOut.transform(_scanCtrl.value);
                    final shakeT = _shakeCtrl.value;
                    final shakeOffset = shakeT == 0 || shakeT == 1
                        ? 0.0
                        : math.sin(shakeT * math.pi * 5) * 10 * (1 - shakeT);
                    return Transform.translate(
                      offset: Offset(shakeOffset, 0),
                      child: Transform.scale(scale: breath, child: child),
                    );
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: frameColor,
                        width: 2.5,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(21.5),
                      child: Stack(
                        children: [
                          if (!_isBusy && !_hasError)
                            AnimatedBuilder(
                              animation: _scanCtrl,
                              builder: (_, __) {
                                final progress =
                                    Curves.easeInOut.transform(_scanCtrl.value);
                                const inset = 16.0;
                                final lineY =
                                    inset + (size - (2 * inset) - 2) * progress;
                                return Positioned(
                                  left: inset,
                                  right: inset,
                                  top: lineY,
                                  child: Container(
                                    height: 2,
                                    decoration: BoxDecoration(
                                      color: AppColors.terra400,
                                      borderRadius: BorderRadius.circular(1),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Status Message Pill
              Positioned(
                left: 20,
                right: 20,
                top: frameTop + size + math.max(26.0, c.maxHeight * 0.035),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _hasError
                        ? ScanStatusPill(
                            key: const ValueKey('err'),
                            icon: Icons.error_outline_rounded,
                            label: widget.errorLabel!,
                            tint: AppColors.danger,
                          )
                        : switch (widget.stage) {
                            ScanStage.checking => const ScanStatusPill(
                                key: ValueKey('checking'),
                                busy: true,
                                label: 'Checking with the server…',
                                tint: AppColors.terra400,
                              ),
                            ScanStage.verified => const ScanStatusPill(
                                key: ValueKey('verified'),
                                icon: Icons.check_circle_outline_rounded,
                                label: 'Verified — pairing saved',
                                tint: AppColors.success,
                              ),
                            ScanStage.idle => const ScanStatusPill(
                                key: ValueKey('idle'),
                                icon: Icons.qr_code_scanner_rounded,
                                label: 'Align QR code',
                                tint: Colors.black45,
                              ),
                          },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ScanStatusPill extends StatelessWidget {
  final IconData? icon;
  final bool busy;
  final String label;
  final Color tint;

  const ScanStatusPill({
    super.key,
    this.icon,
    this.busy = false,
    required this.label,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.pill),
      tint: tint,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
