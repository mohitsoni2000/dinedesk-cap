import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/tokens.dart';

@immutable
class CounterAxisMap {
  const CounterAxisMap({
    required this.weight,
    required this.soft,
    required this.wonk,
    required this.opticalSize,
    required this.italicSlant,
  });

  final double weight;

  /// [soft], [wonk], [opticalSize] and [italicSlant] describe variable-font
  /// axes that the renderer no longer applies — Cormorant is loaded as static
  /// weights here, and the slant in particular was making the bill total lean
  /// once the amount crossed a threshold. Only [weight] reaches the TextStyle.
  /// The fields stay so the amount→axis table reads as one thing.
  final double soft;
  final double wonk;
  final double opticalSize;
  final double italicSlant;

  static CounterAxisMap lerp(CounterAxisMap a, CounterAxisMap b, double t) {
    return CounterAxisMap(
      weight: a.weight + (b.weight - a.weight) * t,
      soft: a.soft + (b.soft - a.soft) * t,
      wonk: a.wonk + (b.wonk - a.wonk) * t,
      opticalSize: a.opticalSize + (b.opticalSize - a.opticalSize) * t,
      italicSlant: a.italicSlant + (b.italicSlant - a.italicSlant) * t,
    );
  }

  static const CounterAxisMap idle = CounterAxisMap(
    weight: 350,
    soft: 30,
    wonk: 0,
    opticalSize: 144,
    italicSlant: 0,
  );

  static const CounterAxisMap growing = CounterAxisMap(
    weight: 450,
    soft: 60,
    wonk: 0.5,
    opticalSize: 144,
    italicSlant: 0.6,
  );

  static const CounterAxisMap heavy = CounterAxisMap(
    weight: 600,
    soft: 100,
    wonk: 1,
    opticalSize: 144,
    italicSlant: 1,
  );

  static CounterAxisMap forAmount(double rupees) {
    if (rupees < 500) {
      return CounterAxisMap.lerp(idle, growing, rupees / 500);
    }
    if (rupees < 2500) {
      return CounterAxisMap.lerp(growing, heavy, (rupees - 500) / 2000);
    }
    return heavy;
  }
}

class KineticRupeeCounter extends StatelessWidget {
  const KineticRupeeCounter({
    required this.amount,
    this.fontSize = 36,
    this.color,
    this.duration = const Duration(milliseconds: 600),
    super.key,
  });

  final double amount;
  final double fontSize;

  final Color? color;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final Color resolvedColor = color ?? context.palette.counterPaper;
    final NumberFormat fmt = NumberFormat.decimalPattern('en_IN');
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: amount),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double rolled, Widget? _) {
        final CounterAxisMap axes = CounterAxisMap.forAmount(rolled);
        return Text(
          '₹${fmt.format(rolled.round())}',
          style: TextStyle(
            fontFamily: AppTypography.cormorant,
            fontWeight: axes.weight >= 500 ? FontWeight.w600 : FontWeight.w500,
            fontSize: fontSize,
            color: resolvedColor,
            height: 1.0,
            letterSpacing: 0,
            // Upright, always.
            //
            // The slant used to be driven by the amount — cross a threshold
            // and the bill total leaned over. Italic serif numerals are
            // markedly harder to read than upright ones, and this renders the
            // number the operator reads aloud to the customer, sitting
            // directly under a "Subtotal" in plain upright sans. A decorative
            // axis is the wrong thing to spend on the one figure that has to
            // be unambiguous.
            //
            // The weight axis stays: heavier for larger amounts reads as
            // emphasis rather than as a different typeface.
            fontStyle: FontStyle.normal,
            fontFeatures: const <FontFeature>[
              FontFeature.tabularFigures(),
            ],
          ),
        );
      },
    );
  }
}

class KineticKotNumber extends StatefulWidget {
  const KineticKotNumber({
    required this.number,
    this.fontSize = 48,
    super.key,
  });

  final int number;
  final double fontSize;

  @override
  State<KineticKotNumber> createState() => _KineticKotNumberState();
}

class _KineticKotNumberState extends State<KineticKotNumber>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _animation =
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (BuildContext context, Widget? _) {
        return Text(
          '#${widget.number.toString().padLeft(4, '0')}',
          style: TextStyle(
            fontFamily: AppTypography.cormorant,
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w600,
            color: AppColors.gold,
            fontStyle: FontStyle.italic,
            letterSpacing: 0,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}
