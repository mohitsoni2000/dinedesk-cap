import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/connection_bootstrap.dart';
import '../theme/tokens.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  late final Animation<double> _logoAnim = CurvedAnimation(
    parent: _animCtrl,
    curve: const Interval(0.00, 0.55, curve: Curves.easeOutBack),
  );

  late final Animation<double> _wordmarkAnim = CurvedAnimation(
    parent: _animCtrl,
    curve: const Interval(0.13, 0.68, curve: Curves.easeOutCubic),
  );

  late final Animation<double> _operatorAnim = CurvedAnimation(
    parent: _animCtrl,
    curve: const Interval(0.27, 0.82, curve: Curves.easeOutCubic),
  );

  late final Animation<double> _versionAnim = CurvedAnimation(
    parent: _animCtrl,
    curve: const Interval(0.45, 1.00, curve: Curves.easeOutCubic),
  );

  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _animCtrl.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndNavigate();
    });
  }

  Timer? _delayTimer;

  @override
  void dispose() {
    _delayTimer?.cancel();
    _animCtrl.dispose();
    super.dispose();
  }

  void _navigate(BootstrapOutcome outcome) {
    if (!mounted || _navigated) return;

    final permissionsComplete = ref.read(startupPermissionsCompleteProvider);
    if (!permissionsComplete || outcome is BootstrapIdle) return;

    _navigated = true;

    _delayTimer?.cancel();
    _delayTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      if (outcome is BootstrapNoPairing) {
        context.go('/scan');
      } else {
        context.go('/connecting');
      }
    });
  }

  void _checkAndNavigate() {
    final outcome = ref.read(connectionBootstrapProvider);
    _navigate(outcome);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(startupPermissionsCompleteProvider, (_, next) {
      if (next) {
        final outcome = ref.read(connectionBootstrapProvider);
        _navigate(outcome);
      }
    });

    ref.listen<BootstrapOutcome>(connectionBootstrapProvider, (_, next) {
      _navigate(next);
    });

    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: AppColors.night,
        child: SizedBox.expand(
          child: AnimatedBuilder(
            animation: _animCtrl,
            builder: (context, _) {
              final logoVal = _logoAnim.value;
              final wordmarkVal = _wordmarkAnim.value;
              final operatorVal = _operatorAnim.value;
              final versionVal = _versionAnim.value;

              return Stack(
                children: [
                  DepthParallaxStack(
                    maxOffset: 8,
                    layers: [
                      const DepthLayer(depth: 0.0, child: SizedBox.expand()),
                      DepthLayer(
                        depth: 0.6,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 1. App Logo (Bouncy Scale & Fade)
                              Opacity(
                                opacity: logoVal.clamp(0.0, 1.0),
                                child: Transform.scale(
                                  scale: 0.75 + 0.25 * logoVal,
                                  child: Container(
                                    width: 88,
                                    height: 88,
                                    decoration: const BoxDecoration(
                                      color: AppColors.logoBg,
                                      borderRadius:
                                          BorderRadius.all(AppRadii.lg),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Image.asset(
                                        'assets/images/appicon_cream.png',
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 28),

                              // 2. Lockup Wordmark (Slide & Fade)
                              Opacity(
                                opacity: wordmarkVal.clamp(0.0, 1.0),
                                child: Transform.translate(
                                  offset: Offset(0, 12 * (1 - wordmarkVal)),
                                  child: Image.asset(
                                    'assets/images/lockup_ink_cream.png',
                                    height: 26,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),

                              // 3. Operator Divider & Title
                              Opacity(
                                opacity: operatorVal.clamp(0.0, 1.0),
                                child: Column(
                                  children: [
                                    Container(
                                      width: 120,
                                      height: 0.5,
                                      color:
                                          Colors.white.withValues(alpha: 0.15),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'O P E R A T O R',
                                      style: TextStyle(
                                        fontFamily: AppTypography.inter,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 10,
                                        letterSpacing: 6,
                                        color: Colors.white
                                            .withValues(alpha: 0.45),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      width: 120,
                                      height: 0.5,
                                      color:
                                          Colors.white.withValues(alpha: 0.15),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  // 4. Version Badge
                  Positioned(
                    right: 20,
                    bottom: 20,
                    child: SafeArea(
                      child: Opacity(
                        opacity: versionVal.clamp(0.0, 1.0),
                        child: Text(
                          'v2.0',
                          style: AppTypography.micro.copyWith(
                            color: Colors.white.withValues(alpha: 0.2),
                            fontSize: 9,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
