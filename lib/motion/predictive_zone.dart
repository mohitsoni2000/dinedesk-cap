import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Wraps a child with a "predictive zone" that measures pointer proximity.
/// Reports [0..1]: 0 = far away, 1 = fully over the widget.
/// Does not animate — just measures and reports. Consumer decides what to do.
class PredictiveZone extends StatefulWidget {
  const PredictiveZone({
    required this.child,
    required this.onIntentProximity,
    this.maxProximityRadius = 100,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final ValueChanged<double> onIntentProximity;
  final double maxProximityRadius;
  final bool enabled;

  @override
  State<PredictiveZone> createState() => _PredictiveZoneState();
}

class _PredictiveZoneState extends State<PredictiveZone> {
  final GlobalKey _key = GlobalKey();

  double _proximityForOffset(Offset globalPosition) {
    final RenderObject? renderObj = _key.currentContext?.findRenderObject();
    if (renderObj is! RenderBox) return 0;
    final RenderBox box = renderObj;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final Rect bounds = topLeft & box.size;

    final double dx = math.max(
      0,
      math.max(
        bounds.left - globalPosition.dx,
        globalPosition.dx - bounds.right,
      ),
    );
    final double dy = math.max(
      0,
      math.max(
        bounds.top - globalPosition.dy,
        globalPosition.dy - bounds.bottom,
      ),
    );
    final double distance = math.sqrt(dx * dx + dy * dy);

    if (distance >= widget.maxProximityRadius) return 0;
    return 1 - (distance / widget.maxProximityRadius);
  }

  void _handleHover(PointerHoverEvent event) {
    if (!widget.enabled) return;
    widget.onIntentProximity(_proximityForOffset(event.position));
  }

  void _handleHoverExit(PointerExitEvent _) {
    if (!widget.enabled) return;
    widget.onIntentProximity(0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return KeyedSubtree(key: _key, child: widget.child);
    }
    return MouseRegion(
      onHover: _handleHover,
      onExit: _handleHoverExit,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (PointerMoveEvent e) {
          widget.onIntentProximity(_proximityForOffset(e.position));
        },
        onPointerUp: (_) => widget.onIntentProximity(0),
        child: KeyedSubtree(key: _key, child: widget.child),
      ),
    );
  }
}

/// Convenience: wraps child with [PredictiveZone] and applies subtle
/// pre-scale based on proximity. Scale: 1.0 (far) to 1.0+maxScaleBoost (touching).
class PredictiveScale extends StatefulWidget {
  const PredictiveScale({
    required this.child,
    this.maxScaleBoost = 0.02,
    this.maxProximityRadius = 100,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final double maxScaleBoost;
  final double maxProximityRadius;
  final bool enabled;

  @override
  State<PredictiveScale> createState() => _PredictiveScaleState();
}

class _PredictiveScaleState extends State<PredictiveScale> {
  final ValueNotifier<double> _proximity = ValueNotifier(0);

  @override
  void dispose() {
    _proximity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PredictiveZone(
      enabled: widget.enabled,
      maxProximityRadius: widget.maxProximityRadius,
      onIntentProximity: (double p) => _proximity.value = p,
      child: ValueListenableBuilder<double>(
        valueListenable: _proximity,
        builder: (_, p, child) => AnimatedScale(
          scale: 1.0 + widget.maxScaleBoost * p,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
