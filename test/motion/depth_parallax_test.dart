import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/depth_parallax.dart';

void main() {
  group('DepthLayer', () {
    test('rejects depth outside [0..1]', () {
      expect(
        () => DepthLayer(depth: -0.1, child: const SizedBox()),
        throwsAssertionError,
      );
      expect(
        () => DepthLayer(depth: 1.5, child: const SizedBox()),
        throwsAssertionError,
      );
    });

    test('accepts valid depth', () {
      const DepthLayer layer = DepthLayer(depth: 0.5, child: SizedBox());
      expect(layer.depth, 0.5);
    });
  });
}
