// Confetti burst — pure CustomPainter, no plugin.
//
// Spawns N particles from a single emit point, each with a random angle/velocity,
// gravity-pulled downward, fades + spins. Drops itself when the controller ends.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

class ConfettiBurst extends StatefulWidget {
  final int count;
  final Duration duration;
  final List<Color> palette;

  const ConfettiBurst({
    super.key,
    this.count = 80,
    this.duration = const Duration(milliseconds: 1800),
    this.palette = const [
      AppColors.terra400,
      AppColors.terra600,
      AppColors.amber,
      AppColors.violet,
      AppColors.teal,
      AppColors.success,
    ],
  });

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.duration)..forward();
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    _particles = List.generate(widget.count, (i) {
      final angle = -math.pi / 2 + (rng.nextDouble() - 0.5) * math.pi * 0.9;
      final speed = 280 + rng.nextDouble() * 320;
      return _Particle(
        color: widget.palette[rng.nextInt(widget.palette.length)],
        vx: math.cos(angle) * speed,
        vy: math.sin(angle) * speed,
        spin: (rng.nextDouble() - 0.5) * 12,
        size: 5 + rng.nextDouble() * 6,
        shape: rng.nextInt(3),
        seed: rng.nextDouble(),
      );
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => CustomPaint(
          painter: _ConfettiPainter(t: _ctrl.value, particles: _particles),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _Particle {
  final Color color;
  final double vx, vy, spin, size, seed;
  final int shape; // 0 rect, 1 circle, 2 streamer
  _Particle({
    required this.color, required this.vx, required this.vy,
    required this.spin, required this.size, required this.shape, required this.seed,
  });
}

class _ConfettiPainter extends CustomPainter {
  final double t;
  final List<_Particle> particles;
  _ConfettiPainter({required this.t, required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.55);
    const gravity = 720.0;

    for (final p in particles) {
      // Position via projectile motion
      final time = t * 1.6; // s
      final dx = p.vx * time;
      final dy = p.vy * time + 0.5 * gravity * time * time;
      final pos = origin + Offset(dx, dy);

      // Fade out in last 30%
      final fade = t < 0.7 ? 1.0 : (1.0 - (t - 0.7) / 0.3);
      if (fade <= 0) continue;

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * t + p.seed * 6.28);

      final paint = Paint()..color = p.color.withValues(alpha: fade.clamp(0, 1));
      switch (p.shape) {
        case 0:
          canvas.drawRect(
            Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.6),
            paint,
          );
          break;
        case 1:
          canvas.drawCircle(Offset.zero, p.size * 0.5, paint);
          break;
        case 2:
          final path = Path()
            ..moveTo(-p.size, 0)
            ..quadraticBezierTo(0, -p.size, p.size, 0);
          canvas.drawPath(path, paint..style = PaintingStyle.stroke..strokeWidth = 2);
          break;
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
}
