

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/help_sheet.dart';
import '../widgets/manual_entry_sheet.dart';

enum _ScanError { invalid, expired, unreachable }

enum _ScanStage { idle, checking, verified }

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
  _ScanStage _stage = _ScanStage.idle;
  int _shakeTrigger = 0;

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

  void _onDetect(BarcodeCapture capture) async {
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
      _stage = _ScanStage.checking;
    });

    final result = await SocketService.probe(host, port, token);
    if (!mounted) return;

    switch (result) {
      case ProbeResult.ok:
        setState(() => _stage = _ScanStage.verified);
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
        await SessionService()
            .savePairing(PairingInfo(host: host, port: port, token: token));
        if (!mounted) return;
        context.go('/connecting');
      case ProbeResult.authRejected:
        _showError(_ScanError.expired);
      case ProbeResult.unreachable:
        _showError(_ScanError.unreachable);
    }
  }

  void _showError(_ScanError err) {
    ref.read(feedbackServiceProvider).fire(const FeedbackError());
    setState(() {
      _error = err;
      _stage = _ScanStage.idle;
      _shakeTrigger++;
    });
    Future.delayed(const Duration(milliseconds: 2600), () {
      if (!mounted) return;
      setState(() {
        _error = null;
        _processing = false;
      });
    });
  }

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
        _ScanError.expired => 'QR expired — ask the admin for a fresh one',
        _ScanError.unreachable => "Can't reach the server — same Wi-Fi?",
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(
        children: [

          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (_, __) => const _CameraUnavailable(),
            ),
          ),

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

          Positioned.fill(
            child: AnimatedBuilder(
              animation: _entranceCtrl,
              builder: (_, child) => Opacity(
                opacity: _entranceCtrl.value,
                child: child,
              ),
              child: _ScanTargetOverlay(
                stage: _stage,
                errorLabel: _error != null ? _errorLabel(_error!) : null,
                shakeTrigger: _shakeTrigger,
              ),
            ),
          ),

          const IgnorePointer(
            child: Opacity(
              opacity: 0.12,
              child: LiquidMeshBackground(
                  dark: true, animate: false, child: SizedBox.shrink()),
            ),
          ),

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
                          'Point at the rotating QR on the admin desktop — '
                          'verified with the server before anything is saved.',
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
                                icon: Icons.keyboard_outlined,
                                label: 'Enter code instead',
                                emphasis: true,
                                onTap: () => ManualEntrySheet.show(context),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: GestureDetector(
                            onTap: _demoScan,
                            child: RichText(
                              text: TextSpan(
                                style: AppTypography.caption.copyWith(
                                  color: Colors.white.withValues(alpha: 0.42),
                                ),
                                children: [
                                  const TextSpan(text: 'No server around? '),
                                  TextSpan(
                                    text: 'Explore the demo kitchen',
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.6),
                                      decoration: TextDecoration.underline,
                                      decorationColor: Colors.white
                                          .withValues(alpha: 0.4),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
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

class _ScanTargetOverlay extends StatefulWidget {
  final _ScanStage stage;
  final String? errorLabel;
  final int shakeTrigger;
  const _ScanTargetOverlay({
    this.stage = _ScanStage.idle,
    this.errorLabel,
    this.shakeTrigger = 0,
  });

  @override
  State<_ScanTargetOverlay> createState() => _ScanTargetOverlayState();
}

class _ScanTargetOverlayState extends State<_ScanTargetOverlay>
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
  void didUpdateWidget(covariant _ScanTargetOverlay old) {
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
      widget.stage == _ScanStage.checking || widget.stage == _ScanStage.verified;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final size = c.maxWidth * 0.66;

      final centerY = c.maxHeight * 0.40;
      final centerX = c.maxWidth / 2;
      final frameTop = centerY - size / 2;

      final bracketColor = _hasError
          ? AppColors.danger
          : widget.stage == _ScanStage.verified
              ? AppColors.success
              : widget.stage == _ScanStage.checking
                  ? AppColors.terra400
                  : AppColors.terra400;

      final frameCenter = Alignment(
        0,
        (centerY - c.maxHeight / 2) / (c.maxHeight / 2),
      );

      return Stack(
        children: [

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

          if (!_isBusy && !_hasError)
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

          if (widget.stage == _ScanStage.verified)
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

          Align(
            alignment: frameCenter,
            child: AnimatedBuilder(
              animation: Listenable.merge([_scanCtrl, _shakeCtrl]),
              builder: (_, child) {
                final breath = _isBusy || _hasError
                    ? 1.0
                    : 1.0 + 0.012 * Curves.easeInOut.transform(_scanCtrl.value);
                final shakeT = _shakeCtrl.value;
                final shakeOffset = shakeT == 0 || shakeT == 1
                    ? 0.0
                    : math.sin(shakeT * math.pi * 5) * 10 * (1 - shakeT);
                return Transform.translate(
                  offset: Offset(shakeOffset, 0),
                  child: Transform.scale(scale: breath, child: child),
                );
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
                    : switch (widget.stage) {
                        _ScanStage.checking => const _StatusPill(
                            key: ValueKey('checking'),
                            busy: true,
                            label: 'Checking with the server…',
                            tint: AppColors.terra400,
                          ),
                        _ScanStage.verified => const _StatusPill(
                            key: ValueKey('verified'),
                            icon: Icons.check_circle_outline_rounded,
                            label: 'Verified — pairing saved',
                            tint: AppColors.success,
                          ),
                        _ScanStage.idle => Text(
                            'Align the QR…',
                            key: const ValueKey('hint'),
                            style: AppTypography.caption.copyWith(
                              color: Colors.white.withValues(alpha: 0.5),
                              letterSpacing: 0.3,
                            ),
                          ),
                      },
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
    const r = 6.0;
    final w = size.width, h = size.height;

    void drawBrackets(Paint p) {

      canvas.drawLine(Offset(0, arm), Offset(0, r), p);
      canvas.drawArc(
          Rect.fromLTWH(0, 0, r * 2, r * 2), 3.14159, -1.5708, false, p);
      canvas.drawLine(Offset(r, 0), Offset(arm, 0), p);

      canvas.drawLine(Offset(w - arm, 0), Offset(w - r, 0), p);
      canvas.drawArc(
          Rect.fromLTWH(w - r * 2, 0, r * 2, r * 2), 4.7124, -1.5708, false, p);
      canvas.drawLine(Offset(w, r), Offset(w, arm), p);

      canvas.drawLine(Offset(0, h - arm), Offset(0, h - r), p);
      canvas.drawArc(
          Rect.fromLTWH(0, h - r * 2, r * 2, r * 2), 1.5708, 1.5708, false, p);
      canvas.drawLine(Offset(r, h), Offset(arm, h), p);

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
      skipBlur: true,
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
  final IconData? icon;
  final bool busy;
  final String label;
  final Color tint;
  const _StatusPill({
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
      blur: 24,
      thickness: 12,
      tint: tint.withValues(alpha: 0.24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          else
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
