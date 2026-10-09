import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../controllers/gate_scan_controller.dart';
import '../controllers/qr_scan_controller.dart' show ScanStage;
import '../data/providers.dart';
import '../services/offline_guard.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/gate/check_in_card.dart';
import '../widgets/gate/gate_offline_strip.dart';
import '../widgets/gate/manual_ticket_sheet.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/qr_scan/camera_unavailable_view.dart';
import '../widgets/qr_scan/qr_scan_overlay.dart';

/// Checking guests in at the gate: the camera reads ticket QRs (or the
/// usher types a number), the desk answers, and the answer fills the screen
/// in its tone. The rules (filter, cooldown, one at a time, unconfirmed,
/// offline) live in [GateScanController]; this screen drives the camera.
///
/// The camera runs in normal detection mode, not `noDuplicates` (the
/// pairing screen's): a guest coming back must scan again, and the per-code
/// cooldown keeps a held QR quiet instead.
class GateScanScreen extends ConsumerStatefulWidget {
  const GateScanScreen({super.key});

  @override
  ConsumerState<GateScanScreen> createState() => _GateScanScreenState();
}

class _GateScanScreenState extends ConsumerState<GateScanScreen> {
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 400,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
  );
  StreamSubscription<SocketState>? _socketSub;
  bool _cameraFailed = false;
  bool _cameraPaused = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _socketSub = ref
        .read(socketServiceProvider)
        .stateStream
        .listen((_) => _syncOnline());
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOnline());
  }

  @override
  void dispose() {
    unawaited(_socketSub?.cancel());
    unawaited(_scanner.dispose());
    super.dispose();
  }

  /// No check-in without the desk: scanning pauses while it is away, and
  /// starts again when it is back.
  void _syncOnline() {
    if (!mounted) return;
    final online = !isDeskOffline(ref);
    ref.read(gateScanControllerProvider.notifier).setOnline(online);
    if (_cameraFailed || online != _cameraPaused) return;
    _cameraPaused = !online;
    unawaited(_quietly(online ? _scanner.start : _scanner.stop));
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // The camera was starting or already gone; the next change retries.
    }
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.trim().isNotEmpty) {
        ref.read(gateScanControllerProvider.notifier).onDetected(raw);
        return;
      }
    }
  }

  Future<void> _typeTicket() async {
    if (!ref.read(gateScanControllerProvider).online) {
      DynamicToast.warning(context, "Desk unreachable – can't verify entries");
      return;
    }
    final typed = await ManualTicketSheet.show(context);
    if (typed == null || !mounted) return;
    final sent =
        ref.read(gateScanControllerProvider.notifier).submitManual(typed);
    if (!sent) {
      DynamicToast.warning(context, "Can't check in right now — try again");
    }
  }

  Future<void> _retry() async {
    if (!requireDesk(context, ref)) return;
    await ref.read(gateScanControllerProvider.notifier).retryPending();
  }

  Future<void> _drop() async {
    final drop = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('Drop this check-in?', style: AppTypography.title),
        content: const Text(
            'The desk did not answer, so this guest may or may not be checked '
            'in. Scanning the ticket again later may then say "Already used".',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Drop it',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (drop == true && mounted) {
      ref.read(gateScanControllerProvider.notifier).abandonPending();
    }
  }

  Future<void> _toggleTorch() async {
    await _quietly(_scanner.toggleTorch);
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/gate');
    }
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(flagsProvider);
    final canCheckIn = flags.entryTickets && flags.ticketCheckin;
    final state = ref.watch(gateScanControllerProvider);
    final card = state.shownCard;

    if (!canCheckIn) {
      return Scaffold(
        backgroundColor: context.palette.paper,
        body: SafeArea(
          child: Column(children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _back,
              ),
            ),
            Expanded(
              child: Center(
                child: Text("You can't check guests in — ask the desk",
                    style: context.palette.caption),
              ),
            ),
          ]),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.ink,
      body: Stack(
        children: [
          if (_cameraFailed)
            const Positioned.fill(
              child: CameraUnavailableView(
                message: 'Camera permission is needed to scan entry tickets. '
                    'Enable it in settings, or type the ticket number.',
              ),
            )
          else ...[
            Positioned.fill(
              child: MobileScanner(
                controller: _scanner,
                onDetect: _onDetect,
                errorBuilder: (_, __) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_cameraFailed) {
                      setState(() => _cameraFailed = true);
                    }
                  });
                  return const SizedBox.shrink();
                },
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: QrScanTargetOverlay(
                  stage: state.inFlight ? ScanStage.checking : ScanStage.idle,
                ),
              ),
            ),
          ],
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _GlassButton(
                        label: 'Back',
                        icon: Icons.arrow_back_rounded,
                        onTap: _back,
                      ),
                      const Expanded(
                        child: Text(
                          'Scan entry',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: AppTypography.inter,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (_cameraFailed)
                        const SizedBox(width: 44)
                      else
                        _GlassButton(
                          label: _torchOn ? 'Turn torch off' : 'Turn torch on',
                          icon: _torchOn
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          active: _torchOn,
                          onTap: _toggleTorch,
                        ),
                    ],
                  ),
                  if (!state.online) ...[
                    const SizedBox(height: 12),
                    const GateOfflineStrip(),
                  ],
                  const Spacer(),
                  LiquidGlassSurface(
                    borderRadius: const BorderRadius.all(AppRadii.md),
                    tint: Colors.black.withValues(alpha: 0.55),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14),
                    onTap: _typeTicket,
                    semanticLabel: 'Type the ticket number',
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.keyboard_outlined,
                            color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Type ticket number',
                          style: TextStyle(
                            fontFamily: AppTypography.inter,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (card != null)
            Positioned.fill(
              child: CheckInCardView(
                card: card,
                busy: state.inFlight,
                onDismiss: ref
                    .read(gateScanControllerProvider.notifier)
                    .dismissCard,
                onRetry: _retry,
                onDrop: _drop,
              ),
            ),
        ],
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.onTap,
    required this.label,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      tint: active ? AppColors.amber : Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      semanticLabel: label,
      child: Icon(icon,
          color: active ? AppColors.night : Colors.white, size: 20),
    );
  }
}
