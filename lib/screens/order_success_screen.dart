import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/animated_check_draw.dart';
import '../widgets/confetti_burst.dart';

class OrderSuccessScreen extends ConsumerStatefulWidget {
  final String tableId;
  final bool isRoom;
  const OrderSuccessScreen(
      {super.key, required this.tableId, this.isRoom = false});
  @override
  ConsumerState<OrderSuccessScreen> createState() => _OrderSuccessScreenState();
}

class _OrderSuccessScreenState extends ConsumerState<OrderSuccessScreen> {
  bool _showText = false;
  Timer? _autoNav;
  String? _tableDisplayName;

  static const int _autoNavSeconds = 45;
  int _countdown = _autoNavSeconds;

  @override
  void initState() {
    super.initState();
    ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final display = widget.isRoom
          ? ref
              .read(roomsProvider)
              .where((r) => r.serverId == widget.tableId)
              .map((r) => r.id)
              .firstOrNull
          : ref
              .read(tablesProvider)
              .where((t) => t.serverId == widget.tableId)
              .map((t) => t.id)
              .firstOrNull;
      if (mounted) setState(() => _tableDisplayName = display);
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showText = true);
    });
    _startAutoNav();
  }

  void _startAutoNav() {
    setState(() => _countdown = _autoNavSeconds);
    _autoNav?.cancel();
    _autoNav = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_countdown > 1) {
          _countdown--;
        } else {
          timer.cancel();
          context.go('/tables');
        }
      });
    });
  }

  @override
  void dispose() {
    _autoNav?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragToDismiss.gesture(
      onDismiss: () {
        if (mounted) context.go('/tables');
      },
      child: ColoredBox(
        color: context.palette.paper,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              const Positioned.fill(child: ConfettiBurst(count: 90)),
              SafeArea(
                child: Column(
                  children: [
                    const Spacer(),
                    const GravityDrop(
                      dropHeight: 110,
                      child: Hero(
                        tag: HeroTags.kotBadge,
                        child: AnimatedCheckDraw(size: 132),
                      ),
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
                        Text('Sent to Kitchen',
                            style: AppTypography.displayMd
                                .copyWith(color: context.palette.ink)),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 16),
                          decoration: BoxDecoration(
                            color: AppColors.gold
                                .withValues(alpha: AppAlphas.badgeLight),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: AppColors.gold.withValues(alpha: 0.30),
                                width: 1.5),
                          ),
                          child: Column(
                            children: [
                              const Text('KOT NUMBER',
                                  style: TextStyle(
                                    fontFamily: AppTypography.inter,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 2.5,
                                    color: AppColors.gold,
                                  )),
                              const SizedBox(height: 8),
                              KineticKotNumber(
                                number: int.tryParse(
                                        (ref.watch(lastKotIdProvider) ?? '')
                                            .replaceAll(
                                                RegExp(r'[^0-9]'), '')) ??
                                    0,
                                fontSize: 64,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                                '${widget.isRoom ? 'Room' : 'Table'} ${_tableDisplayName ?? widget.tableId}',
                                style: context.palette.caption),
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
                        child: Column(
                          children: [
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () {
                                  _autoNav?.cancel();
                                  context.go('/tables');
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.gold,
                                  side: const BorderSide(
                                      color: AppColors.gold, width: 1.5),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text(
                                  "I've noted the KOT",
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            LiquidPrimaryButton(
                              label: 'Back to Tables ($_countdown)',
                              fullWidth: true,
                              onPressed: () {
                                _autoNav?.cancel();
                                context.go('/tables');
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
