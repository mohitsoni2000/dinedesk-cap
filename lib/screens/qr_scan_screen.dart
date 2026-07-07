// QR Scan Screen — entry point for device pairing.
//
// Operator scans the rotating pairing QR shown on the admin desktop. On a
// successful scan we navigate to /connecting which simulates the WS handshake
// and then continues to /auth for username + PIN.
//
// Design: "maître d' podium" — full-bleed camera under a cinematic vignette,
// the scan frame biased upward with breathing ember brackets, and a glass
// console anchored at the bottom carrying the serif welcome + the two
// first-class actions (Help / Try Demo). Status (align hint, errors,
// success) appears in a pill directly under the frame, where the eyes are.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/help_sheet.dart';

enum _ScanError { invalid, expired, used }

class QrScanScreen extends ConsumerStatefulWidget {
  const QrScanScreen({super.key});
  @override
  ConsumerState<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends ConsumerState<QrScanScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _torchOn = false;
  bool _processing = false;
  _ScanError? _error;

  // Entrance animation
  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _entranceCtrl.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _entranceCtrl.dispose();
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
    ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());

    SessionService()
        .savePairing(PairingInfo(host: host, port: port, token: token))
        .then((_) {
      if (!mounted) return;
      context.go('/connecting');
    });
  }

  void _showError(_ScanError err) {
    ref.read(feedbackServiceProvider).fire(const FeedbackError());
    setState(() => _error = err);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _error = null);
    });
  }

  // Lets anyone without a paired admin desktop (most notably App Store /
  // Play Store reviewers) explore the app on fixture data — see demo_data.dart.
  void _demoScan() {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
    ref.read(restaurantProvider.notifier).state = const RestaurantInfo(
      name: 'Command.Crew Demo Kitchen',
      address: 'MG Road, Bengaluru',
      adminDeviceLabel: 'Demo Admin Desktop',
      adminIp: '',
    );

    SessionService()
        .savePairing(
      const PairingInfo(host: 'localhost', port: 8080, token: 'demo-token'),
    )
        .then((_) {
      if (!mounted) return;
      context.go('/connecting');
    });
  }

  String _errorLabel(_ScanError err) => switch (err) {
        _ScanError.invalid => 'Not a valid Restro pairing QR',
        _ScanError.expired => 'QR expired — ask for a fresh one',
        _ScanError.used => 'QR already used — get a new one',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(
        children: [
          // Camera fills the screen
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (_, __) => const _CameraUnavailable(),
            ),
          ),

          // Cinematic vignette — heavier at the bottom to seat the console.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.25),
                    radius: 1.0,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.72),
                    ],
                    stops: const [0.42, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // Animated scan target overlay: cutout, brackets, sweep, status pill.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _entranceCtrl,
              builder: (_, child) => Opacity(
                opacity: _entranceCtrl.value,
                child: child,
              ),
              child: _ScanTargetOverlay(
                processing: _processing,
                errorLabel: _error != null ? _errorLabel(_error!) : null,
              ),
            ),
          ),

          // Faint ember tint behind the chrome. Static — the drift would be
          // invisible at 12% opacity, so don't pay for its controller.
          const IgnorePointer(
            child: Opacity(
              opacity: 0.12,
              child: LiquidMeshBackground(
                  dark: true, animate: false, child: SizedBox.shrink()),
            ),
          ),

          // Top chrome — logo + torch only; the title lives in the console.
          SafeArea(
            child: AnimatedBuilder(
              animation: _entranceCtrl,
              builder: (_, child) => Opacity(
                opacity: _entranceCtrl.value,
                child: Transform.translate(
                  offset: Offset(0, -16 * (1 - _entranceCtrl.value)),
                  child: child,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Hero(
                      tag: HeroTags.appLogo,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: AppColors.logoBg,
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          boxShadow: AppShadows.terraGlow,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Image.asset(
                            'assets/images/appicon_cream.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    _GlassIcon(
                      icon: _torchOn
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                      active: _torchOn,
                      onTap: () {
                        _controller.toggleTorch();
                        setState(() => _torchOn = !_torchOn);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Processing overlay — shown while navigating
          if (_processing)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor:
                                AlwaysStoppedAnimation(AppColors.terra400),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Pairing…',
                          style: AppTypography.caption
                              .copyWith(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Bottom console — the "maître d' podium": serif welcome + actions.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: AnimatedBuilder(
                animation: _entranceCtrl,
                builder: (_, child) => Opacity(
                  opacity: _entranceCtrl.value,
                  child: Transform.translate(
                    offset: Offset(0, 28 * (1 - _entranceCtrl.value)),
                    child: child,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: LiquidGlassSurface(
                    borderRadius: const BorderRadius.all(AppRadii.xl),
                    blur: 30,
                    thickness: 14,
                    tint: Colors.white.withValues(alpha: 0.07),
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Pair this device',
                          style: TextStyle(
                            fontFamily: AppTypography.cormorant,
                            fontWeight: FontWeight.w600,
                            fontSize: 26,
                            height: 1.1,
                            color: Colors.white,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Scan the rotating QR on the admin desktop screen',
                          style: AppTypography.caption.copyWith(
                            color: Colors.white.withValues(alpha: 0.60),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _ConsoleButton(
                                icon: Icons.help_outline_rounded,
                                label: 'Need help?',
                                onTap: () => HelpSheet.show(context),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _ConsoleButton(
                                icon: Icons.auto_awesome,
                                label: 'Try demo',
                                emphasis: true,
                                onTap: _demoScan,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Camera-permission fallback

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.ink,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                color: Colors.white54, size: 52),
            const SizedBox(height: 20),
            Text('Camera unavailable',
                style: AppTypography.title.copyWith(color: Colors.white)),
            const SizedBox(height: 8),
            Text('Allow camera access in Settings to pair this device.',
                textAlign: TextAlign.center,
                style: AppTypography.caption
                    .copyWith(color: Colors.white.withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Animated scan target: cutout, breathing ember brackets, sweep, status pill

class _ScanTargetOverlay extends StatefulWidget {
  final bool processing;
  final String? errorLabel;
  const _ScanTargetOverlay({this.processing = false, this.errorLabel});

  @override
  State<_ScanTargetOverlay> createState() => _ScanTargetOverlayState();
}

class _ScanTargetOverlayState extends State<_ScanTargetOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scanCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _scanCtrl.dispose();
    super.dispose();
  }

  bool get _hasError => widget.errorLabel != null;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final size = c.maxWidth * 0.66;
      // Frame sits above centre so the bottom console gets breathing room.
      final centerY = c.maxHeight * 0.40;
      final centerX = c.maxWidth / 2;
      final frameTop = centerY - size / 2;

      final bracketColor = _hasError
          ? AppColors.danger
          : widget.processing
              ? AppColors.success
              : AppColors.terra400;

      final frameCenter = Alignment(
        0,
        (centerY - c.maxHeight / 2) / (c.maxHeight / 2),
      );

      return Stack(
        children: [
          // Dark overlay with cutout
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

          // Scan line — animated ember sweep
          if (!widget.processing && !_hasError)
            AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, __) {
                final progress = Curves.easeInOut.transform(_scanCtrl.value);
                final lineY = frameTop + 20 + (size - 40) * progress;
                return Positioned(
                  left: centerX - size / 2 + 20,
                  top: lineY,
                  child: Container(
                    width: size - 40,
                    height: 2,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          AppColors.terra400.withValues(alpha: 0.9),
                          AppColors.terra400,
                          AppColors.terra400.withValues(alpha: 0.9),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.2, 0.5, 0.8, 1.0],
                      ),
                      borderRadius: BorderRadius.circular(1),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.terra400.withValues(alpha: 0.6),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          // Success glow when processing
          if (widget.processing)
            Align(
              alignment: frameCenter,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: AppColors.success.withValues(alpha: 0.5),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.success.withValues(alpha: 0.25),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
              ),
            ),

          // Corner brackets — breathing scale rides the same controller as
          // the sweep, so the frame feels alive at zero extra cost.
          Align(
            alignment: frameCenter,
            child: AnimatedBuilder(
              animation: _scanCtrl,
              builder: (_, child) {
                final breath = widget.processing || _hasError
                    ? 1.0
                    : 1.0 + 0.012 * Curves.easeInOut.transform(_scanCtrl.value);
                return Transform.scale(scale: breath, child: child);
              },
              child: SizedBox(
                width: size,
                height: size,
                child: CustomPaint(
                  painter: _BracketPainter(color: bracketColor),
                ),
              ),
            ),
          ),

          // Status pill under the frame — hint / error / success, in place.
          Positioned(
            left: 0,
            right: 0,
            top: frameTop + size + 18,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _hasError
                    ? _StatusPill(
                        key: const ValueKey('err'),
                        icon: Icons.error_outline_rounded,
                        label: widget.errorLabel!,
                        tint: AppColors.danger,
                      )
                    : widget.processing
                        ? const _StatusPill(
                            key: ValueKey('ok'),
                            icon: Icons.check_circle_outline_rounded,
                            label: 'Paired — connecting…',
                            tint: AppColors.success,
                          )
                        : Text(
                            'Align QR within the frame',
                            key: const ValueKey('hint'),
                            style: AppTypography.caption.copyWith(
                              color: Colors.white.withValues(alpha: 0.5),
                              letterSpacing: 0.3,
                            ),
                          ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _BracketPainter extends CustomPainter {
  final Color color;
  _BracketPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Soft ember glow pass under the crisp stroke.
    final glow = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    const arm = 28.0;
    const r = 6.0; // inner corner radius
    final w = size.width, h = size.height;

    void drawBrackets(Paint p) {
      // top-left
      canvas.drawLine(Offset(0, arm), Offset(0, r), p);
      canvas.drawArc(
          Rect.fromLTWH(0, 0, r * 2, r * 2), 3.14159, -1.5708, false, p);
      canvas.drawLine(Offset(r, 0), Offset(arm, 0), p);

      // top-right
      canvas.drawLine(Offset(w - arm, 0), Offset(w - r, 0), p);
      canvas.drawArc(
          Rect.fromLTWH(w - r * 2, 0, r * 2, r * 2), 4.7124, -1.5708, false, p);
      canvas.drawLine(Offset(w, r), Offset(w, arm), p);

      // bottom-left
      canvas.drawLine(Offset(0, h - arm), Offset(0, h - r), p);
      canvas.drawArc(
          Rect.fromLTWH(0, h - r * 2, r * 2, r * 2), 1.5708, 1.5708, false, p);
      canvas.drawLine(Offset(r, h), Offset(arm, h), p);

      // bottom-right
      canvas.drawLine(Offset(w - arm, h), Offset(w - r, h), p);
      canvas.drawArc(Rect.fromLTWH(w - r * 2, h - r * 2, r * 2, r * 2), 0,
          1.5708, false, p);
      canvas.drawLine(Offset(w, h - r), Offset(w, h - arm), p);
    }

    drawBrackets(glow);
    drawBrackets(paint);
  }

  @override
  bool shouldRepaint(covariant _BracketPainter old) => old.color != color;
}

// ────────────────────────────────────────────────────────────────────────────
// Chrome pieces

class _GlassIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _GlassIcon(
      {required this.icon, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(AppRadii.sm),
        boxShadow: active
            ? [
                BoxShadow(
                  color: AppColors.amber.withValues(alpha: 0.35),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.sm),
        blur: 22,
        thickness: 10,
        tint: active
            ? AppColors.amber.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.08),
        padding: const EdgeInsets.all(13),
        onTap: onTap,
        child: Icon(icon,
            color: active ? AppColors.amber : Colors.white, size: 22),
      ),
    );
  }
}

/// Console action — ghost by default, ember-tinted when [emphasis] is set.
class _ConsoleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool emphasis;
  final VoidCallback onTap;
  const _ConsoleButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasis = false,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.md),
      blur: 20,
      thickness: 10,
      skipBlur: true, // sits on the console's own blur — don't stack passes
      tint: emphasis
          ? AppColors.terra400.withValues(alpha: 0.30)
          : Colors.white.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(vertical: 13),
      onTap: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon,
              color: emphasis ? AppColors.terra100 : Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: emphasis ? AppColors.terra100 : Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  const _StatusPill({
    super.key,
    required this.icon,
    required this.label,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.pill),
      blur: 24,
      thickness: 12,
      tint: tint.withValues(alpha: 0.24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: AppTypography.caption.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
