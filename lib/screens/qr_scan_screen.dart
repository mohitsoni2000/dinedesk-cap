import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../controllers/qr_scan_controller.dart';
import '../theme/tokens.dart';
import '../widgets/qr_scan/qr_scan_console.dart';

class QrScanScreen extends ConsumerStatefulWidget {
  const QrScanScreen({super.key});

  @override
  ConsumerState<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends ConsumerState<QrScanScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    _entranceCtrl.forward();
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  void _onSuccessNavigate() {
    if (mounted) {
      context.go('/connecting');
    }
  }

  void _openCameraScanner() {
    if (mounted) {
      context.go('/scan/camera');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SizedBox.expand(
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _entranceCtrl,
            builder: (_, child) => Opacity(
              opacity: _entranceCtrl.value,
              child: Transform.scale(
                scale: 0.97 + (0.03 * _entranceCtrl.value),
                child: child,
              ),
            ),
            child: QrScanConsole(
              onOpenScanner: _openCameraScanner,
              onDemoScan: () => triggerDemoSetup(
                ref,
                onSuccessNavigate: _onSuccessNavigate,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
