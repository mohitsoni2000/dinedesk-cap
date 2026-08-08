import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../theme/tokens.dart';

@immutable
class DepthLayer {
  const DepthLayer({
    required this.child,
    required this.depth,
  }) : assert(depth >= 0 && depth <= 1, 'depth must be in [0..1]');

  final Widget child;
  final double depth;
}

class DepthParallaxStack extends StatefulWidget {
  const DepthParallaxStack({
    required this.layers,
    this.maxOffset = 16,
    this.smoothing = 0.18,
    super.key,
  });

  final List<DepthLayer> layers;
  final double maxOffset;
  final double smoothing;

  @override
  State<DepthParallaxStack> createState() => _DepthParallaxStackState();
}

class _DepthParallaxStackState extends State<DepthParallaxStack>
    with SingleTickerProviderStateMixin {
  StreamSubscription<GyroscopeEvent>? _sub;
  late final Ticker _ticker;
  final ValueNotifier<Offset> _offset = ValueNotifier(Offset.zero);

  double _targetX = 0;
  double _targetY = 0;
  double _currentX = 0;
  double _currentY = 0;

  static const double _decay = 0.92;

  static const double _settleEpsilon = 0.0005;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // AppPerf, not MediaQuery. Gating on `disableAnimations` alone meant a
    // detected low-tier device kept the gyroscope stream subscribed and the
    // ticker running every frame — constant CPU and battery on exactly the
    // hardware that can least afford it, for an effect nobody can see there.
    final reducedMotion = AppPerf.reduceEffects(context);
    if (reducedMotion) {
      _sub?.cancel();
      _sub = null;
      _ticker.stop();
    } else {
      _sub ??= gyroscopeEventStream().listen(_onGyro);
    }
  }

  void _onGyro(GyroscopeEvent e) {
    _targetX += e.y * 0.05;
    _targetY += e.x * 0.05;
    _targetX = _targetX.clamp(-1.0, 1.0);
    _targetY = _targetY.clamp(-1.0, 1.0);

    if (!_ticker.isActive &&
        (_targetX.abs() > _settleEpsilon || _targetY.abs() > _settleEpsilon)) {
      _ticker.start();
    }
  }

  void _onTick(Duration _) {
    _targetX *= _decay;
    _targetY *= _decay;
    _currentX += (_targetX - _currentX) * widget.smoothing;
    _currentY += (_targetY - _currentY) * widget.smoothing;
    if (_targetX.abs() < _settleEpsilon &&
        _targetY.abs() < _settleEpsilon &&
        _currentX.abs() < _settleEpsilon &&
        _currentY.abs() < _settleEpsilon) {
      _currentX = 0;
      _currentY = 0;
      _offset.value = Offset.zero;
      _ticker.stop();
      return;
    }
    final next = Offset(_currentX, _currentY);

    if (_offset.value != next) _offset.value = next;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion = MediaQuery.of(context).disableAnimations;
    return ValueListenableBuilder<Offset>(
      valueListenable: _offset,
      builder: (context, offset, _) {
        final double effX = reducedMotion ? 0 : offset.dx;
        final double effY = reducedMotion ? 0 : offset.dy;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            for (final DepthLayer layer in widget.layers)
              Transform.translate(
                offset: Offset(
                  effX * widget.maxOffset * layer.depth,
                  effY * widget.maxOffset * layer.depth,
                ),
                child: layer.child,
              ),
          ],
        );
      },
    );
  }
}
