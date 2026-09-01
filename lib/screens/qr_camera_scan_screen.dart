import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../controllers/qr_scan_controller.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/qr_scan/camera_unavailable_view.dart';
import '../widgets/qr_scan/qr_scan_overlay.dart';

class QrCameraScanScreen extends ConsumerStatefulWidget {
  const QrCameraScanScreen({super.key});

  @override
  ConsumerState<QrCameraScanScreen> createState() =>
      _QrCameraScanScreenState();
}

class _QrCameraScanScreenState extends ConsumerState<QrCameraScanScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late MobileScannerController _scannerController;
  bool _userOpenedSettings = false;

  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  @override
  void initState() {
    super.initState();
    _initScannerController();
    WidgetsBinding.instance.addObserver(this);
    _entranceCtrl.forward();
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

  void _onBack() {
    if (mounted) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/scan');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(qrScanProvider);
    final notifier = ref.read(qrScanProvider.notifier);

    if (state.cameraFailed) {
      return Scaffold(
        backgroundColor: AppColors.ink,
        body: SafeArea(
          child: Stack(
            children: [
              CameraUnavailableView(
                onOpenSettings: () {
                  _userOpenedSettings = true;
                },
              ),
              Positioned(
                top: 12,
                left: 16,
                child: _GlassIconButton(
                  label: 'Back to pairing menu',
                  icon: Icons.arrow_back_rounded,
                  onTap: _onBack,
                ),
              ),
            ],
          ),
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

            // 3. Scanner Target Frame Layer
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

            // 4. Top Header Bar (Left: Back Arrow, Right: Flash Icon Toggle)
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _GlassIconButton(
                        label: 'Back to setup menu',
                        icon: Icons.arrow_back_rounded,
                        onTap: _onBack,
                      ),
                      _GlassIconButton(
                        label:
                            state.torchOn ? 'Turn torch off' : 'Turn torch on',
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
          ],
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final bool active;

  const _GlassIconButton({
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
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      semanticLabel: label,
      child: Icon(
        icon,
        color: active ? AppColors.night : Colors.white,
        size: 20,
      ),
    );
  }
}
