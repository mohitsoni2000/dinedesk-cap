// Animated check-draw — pop circle + stroke-drawn check.
//
// Two phases:
//   0..0.45: circle scales in (elastic), bg fills
//   0.45..1: check stroke draws via PathMetric extraction

import 'package:flutter/material.dart';
import '../theme/tokens.dart';

class AnimatedCheckDraw extends StatefulWidget {
  final double size;
  final Color color;
  final Duration duration;
  const AnimatedCheckDraw({
    super.key,
    this.size = 120,
    this.color = AppColors.success,
    this.duration = const Duration(milliseconds: 1100),
  });

  @override
  State<AnimatedCheckDraw> createState() => _AnimatedCheckDrawState();
}

class _AnimatedCheckDrawState extends State<AnimatedCheckDraw>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.duration)..forward();

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;
        // Pop in (elastic)
        final pop = t < 0.45
            ? Curves.elasticOut.transform((t / 0.45).clamp(0, 1))
            : 1.0;
        // Draw progress
        final draw = t < 0.45 ? 0.0 : ((t - 0.45) / 0.55).clamp(0.0, 1.0);

        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Transform.scale(
            scale: pop,
            child: CustomPaint(
              painter: _CheckPainter(progress: draw, color: widget.color),
            ),
          ),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  final double progress;
  final Color color;
  _CheckPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);

    // Soft glow
    final glow = Paint()
      ..color = color.withValues(alpha: 0.32)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(c, r * 0.95, glow);

    // Filled circle
    final fill = Paint()..color = color;
    canvas.drawCircle(c, r * 0.88, fill);

    // Inner specular sweep
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.45),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r * 0.88, sheen);

    // Build check path
    final path = Path()
      ..moveTo(r * 0.55, r * 1.05)
      ..lineTo(r * 0.92, r * 1.38)
      ..lineTo(r * 1.45, r * 0.72);

    // Extract metric and slice by progress
    final metric = path.computeMetrics().first;
    final extracted = metric.extractPath(0, metric.length * progress);

    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = r * 0.16
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(extracted, stroke);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) =>
      old.progress != progress || old.color != color;
}
