import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../controllers/qr_scan_controller.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/qr_scan/camera_unavailable_view.dart';
import '../widgets/qr_scan/qr_scan_console.dart';
import '../widgets/qr_scan/qr_scan_overlay.dart';

class QrScanScreen extends ConsumerStatefulWidget {
  const QrScanScreen({super.key});

  @override
  ConsumerState<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends ConsumerState<QrScanScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late MobileScannerController _scannerController;

  bool _userOpenedSettings = false;

  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    _initScannerController();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entranceCtrl.forward();
    });
  }

  void _initScannerController() {
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerController.dispose();
    _entranceCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _userOpenedSettings) {
      _userOpenedSettings = false;
      _resetAndRetryCamera();
    }
  }

  void _resetAndRetryCamera() {
    _scannerController.dispose();
    _initScannerController();
    ref.read(qrScanProvider.notifier).retryCamera();
  }

  void _onSuccessNavigate() {
    if (mounted) {
      context.go('/connecting');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(qrScanProvider);
    final notifier = ref.read(qrScanProvider.notifier);

    if (state.cameraFailed) {
      return Scaffold(
        backgroundColor: AppColors.ink,
        body: CameraUnavailableView(
          onOpenSettings: () {
            _userOpenedSettings = true;
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SizedBox.expand(
        child: Stack(
          children: [
            // 1. Camera Viewfinder Layer
            Positioned.fill(
              child: MobileScanner(
                controller: _scannerController,
                onDetect: (capture) => notifier.processBarcode(
                  capture,
                  onSuccessNavigate: _onSuccessNavigate,
                ),
                errorBuilder: (_, __) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) notifier.setCameraFailed();
                  });
                  return const SizedBox.shrink();
                },
              ),
            ),

            // 2. Dark Dim Overlay Layer
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                ),
              ),
            ),

            // 3. Scanner Target Frame & Status Overlay Layer
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _entranceCtrl,
                builder: (_, child) => Opacity(
                  opacity: _entranceCtrl.value,
                  child: child,
                ),
                child: QrScanTargetOverlay(
                  stage: state.stage,
                  errorLabel: state.errorLabel,
                  shakeTrigger: state.shakeTrigger,
                ),
              ),
            ),

            // 4. Header Bar (App Logo & Torch Toggle)
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
                      Image.asset(
                        'assets/images/appicon_cream.png',
                        fit: BoxFit.contain,
                        height: 47,
                        width: 47,
                      ),
                      const Spacer(),
                      _GlassIcon(
                        label: state.torchOn ? 'Turn torch off' : 'Turn torch on',
                        icon: state.torchOn
                            ? Icons.flash_on_rounded
                            : Icons.flash_off_rounded,
                        active: state.torchOn,
                        onTap: () => notifier.toggleTorch(_scannerController),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 5. Bottom Console Card ("Pair this device")
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
                  child: QrScanConsole(
                    onDemoScan: () => notifier.demoScan(
                      onSuccessNavigate: _onSuccessNavigate,
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

class _GlassIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String label;

  const _GlassIcon({
    required this.icon,
    required this.onTap,
    required this.label,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      tint: active ? AppColors.amber : Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.all(13),
      onTap: onTap,
      semanticLabel: label,
      child: Icon(
        icon,
        color: active ? AppColors.night : Colors.white,
        size: 22,
      ),
    );
  }
}
