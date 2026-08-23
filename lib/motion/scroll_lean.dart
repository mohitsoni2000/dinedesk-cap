import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'springs.dart';

class ScrollVelocityLean extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  final double maxLean;

  const ScrollVelocityLean({
    required this.controller,
    required this.child,
    this.maxLean = 4.5,
    super.key,
  });

  @override
  State<ScrollVelocityLean> createState() => _ScrollVelocityLeanState();
}

class _ScrollVelocityLeanState extends State<ScrollVelocityLean> {
  final ValueNotifier<double> _target = ValueNotifier<double>(0);
  double _lastOffset = 0;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _lastOffset = widget.controller.hasClients ? widget.controller.offset : 0;
    widget.controller.addListener(_onScroll);
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final double offset = widget.controller.offset;
    final double delta = offset - _lastOffset;
    _lastOffset = offset;

    final double lean = (delta * 0.55).clamp(-widget.maxLean, widget.maxLean);
    _target.value = lean;

    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 70), () {
      _target.value = 0;
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _settle?.cancel();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppPerf.reduceEffects(context)) return widget.child;
    return ValueListenableBuilder<double>(
      valueListenable: _target,
      child: widget.child,
      builder: (context, lean, child) => SpringBuilder(
        to: lean,
        spring: RestroSprings.soft,
        child: child,
        builder: (context, v, c) => Transform.translate(
          offset: Offset(0, -v),
          child: c,
        ),
      ),
    );
  }
}
