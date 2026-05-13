import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/animated_check_draw.dart';
import '../widgets/confetti_burst.dart';

class OrderSuccessScreen extends ConsumerStatefulWidget {
  final String tableId;
  const OrderSuccessScreen({super.key, required this.tableId});
  @override
  ConsumerState<OrderSuccessScreen> createState() => _OrderSuccessScreenState();
}

class _OrderSuccessScreenState extends ConsumerState<OrderSuccessScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _txt =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  Timer? _autoNav;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _txt.forward();
    });
    // Auto-return to tables after 3.5s.
    _autoNav = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) context.go('/tables');
    });
  }

  @override
  void dispose() { _autoNav?.cancel(); _txt.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return LiquidMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const Positioned.fill(child: ConfettiBurst(count: 90)),
            SafeArea(
              child: Column(
                children: [
                  const Spacer(),
                  const AnimatedCheckDraw(size: 132),
                  const SizedBox(height: 28),
                  FadeTransition(
                    opacity: _txt,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.2),
                        end: Offset.zero,
                      ).animate(CurvedAnimation(parent: _txt, curve: Curves.easeOutCubic)),
                      child: Column(children: [
                        const Text('Sent to Kitchen', style: AppTypography.displayMd),
                        const SizedBox(height: 8),
                        Text('Table ${widget.tableId} · KOT ${ref.watch(lastKotIdProvider)}',
                            style: AppTypography.caption),
                        const SizedBox(height: 4),
                        Text('Printing on admin desktop',
                            style: AppTypography.micro.copyWith(
                              letterSpacing: 1.4,
                              color: AppColors.success,
                            )),
                      ]),
                    ),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: FadeTransition(
                      opacity: _txt,
                      child: LiquidPrimaryButton(
                        label: 'Back to Tables',
                        fullWidth: true,
                        onPressed: () {
                          _autoNav?.cancel();
                          context.go('/tables');
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
