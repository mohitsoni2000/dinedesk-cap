import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/app_settings.dart';
import '../services/pairing_uri.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/help_sheet.dart';
import '../widgets/manual_entry_sheet.dart';

enum _ScanError { invalid, expired, unreachable, offNetwork }

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

  /// True once the scanner reports it cannot open the camera.
  ///
  /// The scan-target overlay — corner brackets, sweeping line, "Align the
  /// QR…" — is instruction for aiming at something. With no camera there is
  /// nothing to aim, and it was drawing straight over the placeholder's
  /// message and its Open Settings button.
  bool _cameraFailed = false;

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

    // Parsed and *constrained* in one place. The old inline version used
    // Uri.parse, which throws on input like `restroapp://pair?host=[bad` and
    // escaped this `void ... async` to the zone as an unhandled error; it
    // also placed no constraint on the host at all, so a sticker taped over
    // the real one at the POS station could point the phone anywhere and
    // harvest operator PINs.
    final parsed = parsePairingUri(raw);
    final PairingInfo pairing;
    switch (parsed) {
      case PairingUriOk(pairing: final ok):
        pairing = ok;
      case PairingUriOffNetwork():
        _showError(_ScanError.offNetwork);
        return;
      case PairingUriInvalid():
        _showError(_ScanError.invalid);
        return;
    }
    final host = pairing.host;
    final port = pairing.port;
    final token = pairing.token;

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

  /// Debug builds only — see the matching guards in connecting_screen and
  /// auth_screen. This writes a real pairing carrying `demo-token` into
  /// secure storage, after which the app is fully navigable with no socket
  /// and no PIN. A waiter could also fall into it by mistap during a WiFi
  /// outage and take orders that went nowhere.
  void _demoScan() {
    if (!kDebugMode) return;
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
        _ScanError.offNetwork =>
          'That QR points off the restaurant network — check with your admin',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      // `SizedBox.expand` is load-bearing. Scaffold hands its body *loose*
      // constraints, and a Stack sizes itself to its largest NON-positioned
      // child — here that is only the SafeArea top bar, about 113pt. Every
      // other child is Positioned and contributes nothing to sizing, so the
      // whole screen collapsed into a band at the top and the camera
      // placeholder inside a Positioned.fill overflowed by 22px.
      //
      // This used to be held up by accident: a decorative 12%-opacity mesh
      // overlay sat here as a non-positioned child wrapping a full-size box.
      // The height now comes from the body itself, not from a decoration.
      body: SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (_, __) {
                  // errorBuilder runs during build, so the flag is raised on
                  // the next frame rather than inside this one.
                  if (!_cameraFailed) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _cameraFailed = true);
                    });
                  }
                  return const _CameraUnavailable();
                },
              ),
            ),

            // A flat scrim, not a radial vignette. It exists because the
            // instruction text and chrome are white-on-camera and need
            // something behind them; it just no longer ramps. With no camera
            // the placeholder is already a dark surface, so the scrim would
            // only dim its own message.
            if (!_cameraFailed)
              Positioned.fill(
                child: IgnorePointer(
                  child:
                      ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
                ),
              ),

            if (!_cameraFailed)
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

            // A 12%-opacity mesh wash used to sit here, over the camera. With
            // the mesh gone it was painting a flat tint over the whole preview
            // for no reason — the flat scrim above is the only overlay now.

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
                        label: _torchOn ? 'Turn torch off' : 'Turn torch on',
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
                      // An opaque panel. The 7%-white tint only ever read as a
                      // surface because a 30px blur sat behind it.
                      tint: AppColors.night,
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
                          // Hidden outright in release rather than merely
                          // disabled — a dead "explore the demo kitchen" link
                          // on the pairing screen is its own support call.
                          if (kDebugMode)
                            Center(
                              child: GestureDetector(
                                onTap: _demoScan,
                                child: RichText(
                                  text: TextSpan(
                                    style: AppTypography.caption.copyWith(
                                      color:
                                          Colors.white.withValues(alpha: 0.42),
                                    ),
                                    children: [
                                      const TextSpan(
                                          text: 'No server around? '),
                                      TextSpan(
                                        text: 'Explore the demo kitchen',
                                        style: TextStyle(
                                          color: Colors.white
                                              .withValues(alpha: 0.6),
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
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.palette.ink,
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
            Text('Allow camera access to pair this device.',
                textAlign: TextAlign.center,
                // Was white at 0.6 alpha, which measures 2.95:1 against the
                // camera-dark backdrop — below AA. 0.85 clears it.
                style: AppTypography.caption
                    .copyWith(color: Colors.white.withValues(alpha: 0.85))),
            const SizedBox(height: 20),
            // This screen used to end at the sentence above: it told the
            // operator to go to Settings and then gave them no way to get
            // there. Pairing is the first thing a new device does, so someone
            // who mistaps "Don't Allow" was stranded outside the app.
            Pressable(
              semanticLabel: 'Open this app’s settings',
              onTap: AppSettingsLauncher.open,
              child: Container(
                constraints: const BoxConstraints(
                  minHeight: AppTouchTargets.minimum,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.all(AppRadii.md),
                ),
                child: Text(
                  'Open Settings',
                  style: AppTypography.bodyMd.copyWith(
                    color: AppColors.night,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
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
      widget.stage == _ScanStage.checking ||
      widget.stage == _ScanStage.verified;

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
                    // A plain line. It was a five-stop gradient fading out at
                    // both ends under a terra glow.
                    decoration: BoxDecoration(
                      color: AppColors.terra400,
                      borderRadius: BorderRadius.circular(1),
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
                  // The green border alone marks a verified read.
                  border: Border.all(color: AppColors.success, width: 2),
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
    // The brackets are drawn once. They used to be drawn twice: a 6px
    // mask-blurred glow pass underneath the crisp one.
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

    drawBrackets(paint);
  }

  @override
  bool shouldRepaint(covariant _BracketPainter old) => old.color != color;
}

class _GlassIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  /// Required: this renders an icon and nothing else, so there is no text for
  /// a screen reader to fall back on.
  final String label;
  const _GlassIcon({
    required this.icon,
    required this.onTap,
    required this.label,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    // An opaque chip. This sat on the camera preview, so it used to be a
    // blurred glass surface with a low-alpha white tint under an amber glow
    // when lit. With no blur behind it the tint had nothing to read against,
    // so the fill is solid: amber when on, near-black when off.
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      tint: active ? AppColors.amber : Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.all(13),
      onTap: onTap,
      semanticLabel: label,
      child:
          Icon(icon, color: active ? AppColors.night : Colors.white, size: 22),
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
      tint:
          emphasis ? AppColors.terra500 : Colors.white.withValues(alpha: 0.12),
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
      tint: tint,
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
              style: AppTypography.caption
                  .copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
