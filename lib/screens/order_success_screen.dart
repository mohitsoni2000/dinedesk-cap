import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
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

class _OrderSuccessScreenState extends ConsumerState<OrderSuccessScreen> {
  bool _showText = false;
  Timer? _autoNav;
  String? _tableDisplayName;

  @override
  void initState() {
    super.initState();
    ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tables = ref.read(tablesProvider);
      final display = tables.where((t) => t.serverId == widget.tableId).map((t) => t.id).firstOrNull;
      if (mounted) setState(() => _tableDisplayName = display);
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showText = true);
    });
    _autoNav = Timer(const Duration(milliseconds: 8000), () {
      if (mounted) context.go('/tables');
    });
  }

  @override
  void dispose() {
    _autoNav?.cancel();
    super.dispose();
  }

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
                  const Hero(
                    tag: HeroTags.kotBadge,
                    child: AnimatedCheckDraw(size: 132),
                  ),
                  const SizedBox(height: 28),
                  SpringBuilder(
                    from: 0.0,
                    to: _showText ? 1.0 : 0.0,
                    spring: RestroSprings.soft,
                    builder: (BuildContext _, double t, Widget? child) {
                      return Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, 20.0 * (1.0 - t)),
                          child: child,
                        ),
                      );
                    },
                    child: Column(children: [
                      const Text('Sent to Kitchen',
                          style: AppTypography.displayMd),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Table ${_tableDisplayName ?? widget.tableId} · KOT ',
                              style: AppTypography.caption),
                          KineticKotNumber(
                            number:
                                int.tryParse(ref.watch(lastKotIdProvider)) ?? 0,
                            fontSize: 14,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Printing on admin desktop',
                          style: AppTypography.micro.copyWith(
                            letterSpacing: 1.4,
                            color: AppColors.success,
                          )),
                    ]),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SpringBuilder(
                      from: 0.0,
                      to: _showText ? 1.0 : 0.0,
                      spring: RestroSprings.soft,
                      builder: (BuildContext _, double t, Widget? child) {
                        return Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: child,
                        );
                      },
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
