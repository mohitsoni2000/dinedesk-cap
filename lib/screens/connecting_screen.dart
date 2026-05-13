// Connecting Screen — shown after QR scan during the pairing handshake.
//
// Cycles through stages: finding restaurant → verifying device → almost there.
// On completion advances to /auth for username + PIN. The actual handshake
// (Socket.IO connect + JWT pair) is driven by SocketService.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';

class ConnectingScreen extends ConsumerStatefulWidget {
  const ConnectingScreen({super.key});
  @override
  ConsumerState<ConnectingScreen> createState() => _ConnectingScreenState();
}

class _ConnectingScreenState extends ConsumerState<ConnectingScreen>
    with SingleTickerProviderStateMixin {
  static const _stages = <String>[
    'Finding restaurant…',
    'Verifying device…',
    'Almost there…',
  ];
  int _stage = 0;
  Timer? _stageTimer;
  StreamSubscription<SocketState>? _socketSub;
  String? _errorMsg;

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _connectToServer();
  }

  Future<void> _connectToServer() async {
    final pairing = await SessionService().getSavedPairing();
    if (!mounted) return;

    if (pairing == null) {
      context.go('/scan');
      return;
    }

    final socketService = ref.read(socketServiceProvider);

    // Listen to socket state changes.
    _socketSub = socketService.stateStream.listen((state) {
      if (!mounted) return;
      if (state == SocketState.connected) {
        // Advance to stage 2 then navigate to /auth.
        setState(() => _stage = 1);
        _stageTimer = Timer(const Duration(milliseconds: 700), () {
          if (!mounted) return;
          setState(() => _stage = 2);
          _stageTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted) context.go('/auth');
          });
        });
      } else if (state == SocketState.disconnected && _stage > 0) {
        setState(() => _errorMsg = 'Connection lost — retrying…');
      }
    });

    // Start connection.
    socketService.connect(pairing.host, pairing.port, pairing.token);

    // Advance stage 0 after a short delay for visual feedback.
    _stageTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted && _stage == 0) {
        // Stage 0 is already visible; socket state listener handles the rest.
      }
    });
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _socketSub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final restaurant = ref.watch(restaurantProvider);
    final name = restaurant?.name ?? 'Restaurant';
    final deviceLabel = restaurant?.adminDeviceLabel ?? 'Admin Desktop';

    return LiquidMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: LiquidGlassSurface(
                borderRadius: const BorderRadius.all(AppRadii.lg),
                blur: 30, thickness: 14,
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pulse + spinner.
                    SizedBox(
                      width: 96, height: 96,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          _PulseRing(),
                          RotationTransition(
                            turns: _spin,
                            child: Container(
                              width: 64, height: 64,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [AppColors.terra400, AppColors.terra600],
                                ),
                                shape: BoxShape.circle,
                                boxShadow: AppShadows.terraGlow,
                              ),
                              child: const Icon(Icons.wifi_tethering,
                                color: Colors.white, size: 28),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text('Connecting to', style: AppTypography.caption),
                    const SizedBox(height: 4),
                    Text(name,
                      style: AppTypography.displayMd, textAlign: TextAlign.center,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(deviceLabel,
                      style: AppTypography.caption,
                      textAlign: TextAlign.center,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (_errorMsg != null) ...[
                      const SizedBox(height: 8),
                      Text(_errorMsg!,
                        style: AppTypography.caption.copyWith(color: AppColors.warn),
                        textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 20),

                    // Stage list with animated checkmarks.
                    Column(
                      children: [
                        for (int i = 0; i < _stages.length; i++) ...[
                          _StageRow(
                            label: _stages[i],
                            done: i < _stage,
                            active: i == _stage,
                          ),
                          if (i < _stages.length - 1) const SizedBox(height: 6),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                    LiquidSecondaryButton(
                      label: 'Cancel',
                      onPressed: () => context.go('/scan'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseRing extends StatefulWidget {
  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
    AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
  late final Animation<double> _curved = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (_, __) {
        final t = _curved.value;
        return Container(
          width: 96 * (0.6 + t * 0.4),
          height: 96 * (0.6 + t * 0.4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.terra400.withValues(alpha: (1 - t).clamp(0, 1) * 0.6),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}

class _StageRow extends StatelessWidget {
  final String label;
  final bool done;
  final bool active;
  const _StageRow({required this.label, required this.done, required this.active});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 18, height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
              ? AppColors.success
              : active
                ? AppColors.terra400.withValues(alpha: 0.18)
                : AppColors.ink05,
          ),
          child: done
            ? const Icon(Icons.check, size: 12, color: Colors.white)
            : active
              ? const Center(
                  child: SizedBox(
                    width: 8, height: 8,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: AppColors.terra500,
                    ),
                  ),
                )
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
            style: AppTypography.bodyMd.copyWith(
              color: done ? AppColors.ink70 : AppColors.ink,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
