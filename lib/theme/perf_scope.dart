import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'perf_mode.dart';

/// The resolved answer, published down the tree.
class PerfProfile {
  final PerfMode mode;
  final PerfTier tier;

  /// The single question every ambient effect asks before painting.
  final bool reduceEffects;

  const PerfProfile({
    required this.mode,
    required this.tier,
    required this.reduceEffects,
  });
}

/// Bridges the Riverpod-owned [perfStateProvider] into an [InheritedWidget].
///
/// Effects consult this through `AppPerf.reduceEffects(context)`, which reads
/// like `Theme.of(context)` and works from plain [StatelessWidget]/[State] —
/// including [PageTransitionsBuilder] and the static `CartFlight.fly()`
/// helper, neither of which can hold a `WidgetRef`.
class PerfScope extends ConsumerWidget {
  const PerfScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perf = ref.watch(perfStateProvider);
    // OS accessibility always wins, whatever the operator picked.
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

  static PerfProfile? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PerfInheritedScope>()
      ?.profile;

  @override
  bool updateShouldNotify(PerfInheritedScope old) =>
      old.profile.reduceEffects != profile.reduceEffects ||
      old.profile.mode != profile.mode ||
      old.profile.tier != profile.tier;
}
