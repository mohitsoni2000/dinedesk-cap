import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'physics.dart';
import 'springs.dart';

/// ============================================================
/// DRAG TO DISMISS — Instagram/Telegram style route pull-away,
/// built natively on RestroSprings (no draggable_route package,
/// no imperative Navigator: plays clean with go_router).
///
/// Two flavors:
///  • [DragToDismiss.gesture]   — for non-scroll screens (e.g.
///    the KOT success screen): drag anywhere, page follows your
///    finger, rounds its corners, scales down; flick or pass the
///    threshold → it flies off with a heavy spring and pops.
///  • [DragToDismiss.overscroll] — for scrollable screens (e.g.
///    order detail): pull past the top of the list (the bouncy
///    overscroll region) and the whole page comes with you.
///    Zero gesture-arena conflict: it only *listens* to scroll
///    notifications, never competes with the list.
///
/// Pair with a transparent route (liquidPage fromBottom) so the
/// previous screen is revealed behind while dragging.
/// ============================================================
class DragToDismiss extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismiss;

  /// Pull distance (logical px) beyond which release = dismiss.
  final double threshold;
  final bool _useOverscroll;

  const DragToDismiss.gesture({
    required this.child,
    required this.onDismiss,
    this.threshold = 130,
    super.key,
  }) : _useOverscroll = false;

  const DragToDismiss.overscroll({
    required this.child,
    required this.onDismiss,
    this.threshold = 96,
    super.key,
  }) : _useOverscroll = true;

  @override
  State<DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<DragToDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _y =
      AnimationController.unbounded(vsync: this, value: 0);
  bool _dismissing = false;
  bool _fingerDrag = false;

  double get _progress => (_y.value / 300).clamp(0.0, 1.0);

  @override
  void dispose() {
    _y.dispose();
    super.dispose();
  }

  void _settle(double velocity) {
    if (_dismissing) return;
    if (_y.value > widget.threshold || velocity > 700) {
      _fire(velocity);
    } else if (_y.value != 0) {
      _y.springTo(0, spring: RestroSprings.snappy, velocity: velocity);
    }
  }

  void _fire(double velocity) {
    if (_dismissing) return;
    _dismissing = true;
    final double h = MediaQuery.sizeOf(context).height;
    _y
        .animateWith(SpringSimulation(RestroSprings.heavy, _y.value,
            h * 1.05, velocity.clamp(500.0, 4200.0)))
        .whenCompleteOrCancel(() {
      if (mounted && _dismissing) widget.onDismiss();
    });
  }

  // ---------------------------------------------------- gesture flavor --
  void _dragUpdate(DragUpdateDetails d) {
    if (_dismissing) return;
    final double next = _y.value + d.delta.dy;
    _y.value = next < 0 ? next * 0.24 : next; // resist upward
  }

  void _dragEnd(DragEndDetails d) =>
      _settle(d.velocity.pixelsPerSecond.dy);

  // ------------------------------------------------- overscroll flavor --
  bool _onScroll(ScrollNotification n) {
    if (_dismissing ||
        n.depth != 0 ||
        n.metrics.axis != Axis.vertical) {
      return false;
    }
    if (n is ScrollUpdateNotification) {
      final double px = n.metrics.pixels;
      if (n.dragDetails != null) {
        _fingerDrag = true;
        if (px < 0) {
          _y.value = -px * 1.12; // ride the bouncy overscroll
        } else if (_y.value != 0) {
          _y.value = 0;
        }
      } else {
        // First ballistic frame after the finger lifts → decide once.
        if (_fingerDrag) {
          _fingerDrag = false;
          if (_y.value > widget.threshold) {
            _fire(600);
            return false;
          }
        }
        if (px < 0) {
          _y.value = -px * 1.12; // follow the bounce back home
        } else if (_y.value != 0) {
          _y.value = 0;
        }
      }
    } else if (n is ScrollEndNotification) {
      _fingerDrag = false;
      if (!_dismissing && _y.value != 0) {
        _y.springTo(0, spring: RestroSprings.soft);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = AnimatedBuilder(
      animation: _y,
      child: widget.child,
      builder: (context, child) {
        final double y = _y.value;
        final double p = _progress;
        if (y == 0) return child!;
        return Transform.translate(
          offset: Offset(0, y),
          child: Transform.scale(
            scale: 1 - 0.05 * p,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28 * p),
              child: child,
            ),
          ),
        );
      },
    );

    if (widget._useOverscroll) {
      return NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: content,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _dragUpdate,
      onVerticalDragEnd: _dragEnd,
      onVerticalDragCancel: () => _settle(0),
      child: content,
    );
  }
}
