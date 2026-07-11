

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';

class ConnectingScreen extends ConsumerStatefulWidget {
  const ConnectingScreen({super.key});
  @override
  ConsumerState<ConnectingScreen> createState() => _ConnectingScreenState();
}

class _ConnectingScreenState extends ConsumerState<ConnectingScreen>
    with SingleTickerProviderStateMixin {
  static const _stages = <String>[
    'Reaching the POS server',
    'Securing the session',
    'Loading restaurant data',
  ];
  int _stage = 0;
  bool _failed = false;
  Timer? _stageTimer;
  Timer? _timeoutTimer;
  StreamSubscription<SocketState>? _socketSub;
  String? _errorMsg;
  PairingInfo? _pairing;

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
    debugPrint('[Connect] Loading saved pairing...');
    final pairing = await SessionService().getSavedPairing();
    if (!mounted) return;

    if (pairing == null) {
      debugPrint('[Connect] No pairing found → redirecting to /scan');
      context.go('/scan');
      return;
    }

    setState(() {
      _pairing = pairing;
      _stage = 0;
      _failed = false;
      _errorMsg = null;
    });

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && !_failed) setState(() => _failed = true);
    });

    if (pairing.token == 'demo-token') {
      debugPrint('[Connect] Demo pairing — skipping real socket handshake');
      _runDemoStages();
      return;
    }

    debugPrint('[Connect] Pairing loaded: ${pairing.host}:${pairing.port}');
    final socketService = ref.read(socketServiceProvider);

    _socketSub = socketService.stateStream.listen((state) {
      if (!mounted) return;
      debugPrint('[Connect] Socket state changed: $state');
      if (state == SocketState.connected) {
        debugPrint('[Connect] ✓ Connected → advancing stages then → /auth');
        _timeoutTimer?.cancel();

        setState(() => _stage = 1);
        _stageTimer = Timer(const Duration(milliseconds: 700), () {
          if (!mounted) return;
          setState(() => _stage = 2);
          _stageTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted) {
              debugPrint('[Connect] Navigating to /auth');
              context.go('/auth');
            }
          });
        });
      } else if (state == SocketState.disconnected && _stage > 0) {
        debugPrint('[Connect] ✗ Connection lost during handshake');
        setState(() => _errorMsg = 'Connection lost — retrying…');
      }
    });

    debugPrint('[Connect] Starting socket connection...');
    socketService.connect(pairing.host, pairing.port, pairing.token);
  }

  void _runDemoStages() {
    setState(() => _stage = 1);
    _stageTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _stage = 2);
      _stageTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          _timeoutTimer?.cancel();
          context.go('/auth');
        }
      });
    });
  }

  Future<void> _cancelToScan() async {
    await SessionService().clearPairing();
    if (!mounted) return;
    context.go('/scan');
  }

  void _retry() {
    _stageTimer?.cancel();
    _socketSub?.cancel();
    ref.read(socketServiceProvider).disconnect();
    _connectToServer();
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _timeoutTimer?.cancel();
    _socketSub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = _pairing?.host ?? '';
    final port = _pairing?.port;
    final isDemo = _pairing?.token == 'demo-token';

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: AppSurface(
                borderRadius: const BorderRadius.all(AppRadii.lg),
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Hero(
                      tag: HeroTags.pairingCore,
                      child: SizedBox(
                        width: 96,
                        height: 96,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (!_failed) _PulseRing(),
                            RotationTransition(
                              turns: _failed
                                  ? const AlwaysStoppedAnimation(0)
                                  : _spin,
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: _failed
                                        ? const [
                                            AppColors.terra,
                                            AppColors.terraDeep,
                                          ]
                                        : const [
                                            AppColors.terra400,
                                            AppColors.terra600,
                                          ],
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: AppShadows.terraGlow,
                                ),
                                child: Icon(
                                  _failed
                                      ? Icons.wifi_off_rounded
                                      : Icons.wifi_tethering,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_failed) ...[
                      const Text("Can't reach the server",
                          style: AppTypography.displayMd,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            _ChecklistItem(
                                text:
                                    'Is this phone on the same Wi-Fi as the desktop?'),
                            _ChecklistItem(
                                text:
                                    'Is the Restro POS app running on the desktop?'),
                            _ChecklistItem(
                                text:
                                    'QR codes expire — ask the admin for a fresh one.'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _CardButton(
                              label: 'Scan new QR',
                              filled: false,
                              onTap: _cancelToScan,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _CardButton(
                              label: 'Try again',
                              filled: true,
                              onTap: _retry,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      Text('CONNECTING TO',
                          style: AppTypography.micro
                              .copyWith(color: context.palette.ink50)),
                      const SizedBox(height: 4),
                      Text(
                        host.isEmpty ? '—' : (isDemo ? 'Demo Kitchen' : host),
                        style: AppTypography.tableName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isDemo
                            ? 'Local sandbox · no server needed'
                            : 'Port ${port ?? '—'} · Restro POS',
                        style: context.palette.caption,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_errorMsg != null) ...[
                        const SizedBox(height: 8),
                        Text(_errorMsg!,
                            style: AppTypography.caption
                                .copyWith(color: AppColors.warn),
                            textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 20),
                      Column(
                        children: [
                          for (int i = 0; i < _stages.length; i++) ...[
                            _StageRow(
                              label: _stages[i],
                              done: i < _stage,
                              active: i == _stage,
                            ),
                            if (i < _stages.length - 1)
                              const SizedBox(height: 6),
                          ],
                        ],
                      ),
                      const SizedBox(height: 20),
                      Pressable(
                        onTap: _cancelToScan,
                        child: Text('Cancel',
                            style: AppTypography.caption
                                .copyWith(color: context.palette.ink50)),
                      ),
                    ],
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

class _ChecklistItem extends StatelessWidget {
  final String text;
  const _ChecklistItem({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ',
              style: AppTypography.caption.copyWith(color: AppColors.terra)),
          Expanded(
            child: Text(text,
                style: AppTypography.caption
                    .copyWith(color: context.palette.ink70)),
          ),
        ],
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _CardButton(
      {required this.label, required this.filled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? context.palette.ink : Colors.transparent,
          borderRadius: const BorderRadius.all(AppRadii.md),
          border: filled ? null : Border.all(color: context.palette.hairline),
        ),
        child: Text(
          label,
          style: AppTypography.bodyMd.copyWith(
            color: filled ? Colors.white : context.palette.ink,
            fontWeight: FontWeight.w600,
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
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();
  late final Animation<double> _curved =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

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
              color: AppColors.terra400
                  .withValues(alpha: (1 - t).clamp(0, 1) * 0.6),
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
  const _StageRow(
      {required this.label, required this.done, required this.active});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? AppColors.success
                : active
                    ? context.palette.terraSoft
                    : context.palette.ink05,
          ),
          child: done
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : active
                  ? const Center(
                      child: SizedBox(
                        width: 8,
                        height: 8,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: AppColors.terra,
                        ),
                      ),
                    )
                  : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: AppTypography.bodyMd.copyWith(
              color: done ? context.palette.ink70 : context.palette.ink,
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
