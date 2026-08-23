import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'perf_mode.dart';

class PerfProfile {
  final PerfMode mode;
  final PerfTier tier;

  final bool reduceEffects;

  const PerfProfile({
    required this.mode,
    required this.tier,
    required this.reduceEffects,
  });
}

class PerfScope extends ConsumerWidget {
  const PerfScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perf = ref.watch(perfStateProvider);

    final reduce = MediaQuery.of(context).disableAnimations ||
        perf.mode == PerfMode.performance ||
        (perf.mode == PerfMode.auto && perf.tier == PerfTier.low);

    return PerfInheritedScope(
      profile: PerfProfile(
        mode: perf.mode,
        tier: perf.tier,
        reduceEffects: reduce,
      ),
      child: child,
    );
  }
}

class PerfInheritedScope extends InheritedWidget {
  const PerfInheritedScope({
    required this.profile,
    required super.child,
    super.key,
  });

  final PerfProfile profile;

  static PerfProfile? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PerfInheritedScope>()?.profile;

  @override
  bool updateShouldNotify(PerfInheritedScope old) =>
      old.profile.reduceEffects != profile.reduceEffects ||
      old.profile.mode != profile.mode ||
      old.profile.tier != profile.tier;
}
