import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'physics.dart';

class CartFlight {
  CartFlight._();

  static final GlobalKey cartBarKey = GlobalKey(debugLabel: 'cart-flight-bar');

  static final GlobalKey railKey = GlobalKey(debugLabel: 'cart-flight-rail');

  static List<GlobalKey> get _targets => <GlobalKey>[railKey, cartBarKey];

  static void fly(BuildContext origin, {VoidCallback? onLand}) {
    final RenderBox? originBox = origin.findRenderObject() as RenderBox?;
    RenderBox? targetBox;
    for (final key in _targets) {
      final ctx = key.currentContext;
      final rb = ctx?.findRenderObject() as RenderBox?;
      if (rb != null && rb.attached && rb.hasSize) {
        targetBox = rb;
        break;
      }
    }
    final OverlayState? overlay = Overlay.maybeOf(origin, rootOverlay: true);

    if (originBox == null ||
        !originBox.attached ||
        targetBox == null ||
        overlay == null ||
        AppPerf.reduceEffects(origin)) {
      onLand?.call();
      return;
    }

    final Offset start =
        originBox.localToGlobal(originBox.size.center(Offset.zero));

    final Offset end = targetBox.localToGlobal(
        Offset(targetBox.size.width * 0.22, targetBox.size.height * 0.5));

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _FlightDot(
        start: start,
        end: end,
        onDone: () {
          entry.remove();
          onLand?.call();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _FlightDot extends StatelessWidget {
  final Offset start;
  final Offset end;
  final VoidCallback onDone;
  const _FlightDot({
    required this.start,
    required this.end,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final Offset ctrl = Offset(
      (start.dx + end.dx) / 2,
      (start.dy < end.dy ? start.dy : end.dy) - 84,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeInOutCubic,
      onEnd: onDone,
      builder: (context, t, _) {
        final double u = 1 - t;
        final Offset p = Offset(
          u * u * start.dx + 2 * u * t * ctrl.dx + t * t * end.dx,
          u * u * start.dy + 2 * u * t * ctrl.dy + t * t * end.dy,
        );

        final double born = (t / 0.12).clamp(0.0, 1.0);
        final double scale = born * (1.0 - 0.62 * Curves.easeIn.transform(t));
        final double opacity =
            t > 0.86 ? (1 - (t - 0.86) / 0.14).clamp(0.0, 1.0) : 1.0;

        return Positioned(
          left: p.dx - 9,
          top: p.dy - 9,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.terra,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: AppShadows.terraGlow,
                  ),
                  child: const Icon(Icons.add, size: 11, color: Colors.white),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class BoingOnChange extends StatefulWidget {
  final Object? trigger;
  final double power;
  final Widget child;
  const BoingOnChange({
    required this.trigger,
    required this.child,
    this.power = 0.9,
    super.key,
  });

  @override
  State<BoingOnChange> createState() => _BoingOnChangeState();
}

class _BoingOnChangeState extends State<BoingOnChange> {
  final BoingController _boing = BoingController();

  @override
  void didUpdateWidget(covariant BoingOnChange old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _boing.fire(widget.power);
  }

  @override
  Widget build(BuildContext context) =>
      Boing(controller: _boing, child: widget.child);
}
