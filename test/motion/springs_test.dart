import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/motion.dart';

void main() {
  group('SpringBuilder', () {
    testWidgets('settles at target value', (WidgetTester tester) async {
      double captured = -1.0;
      await tester.pumpWidget(
        SpringBuilder(
          from: 0.0,
          to: 1.0,
          spring: RestroSprings.snappy,
          builder: (BuildContext _, double v, Widget? __) {
            captured = v;
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(captured, closeTo(1.0, 0.005));
    });

    testWidgets('bouncy spring overshoots target', (WidgetTester tester) async {
      double maxObserved = 0.0;
      await tester.pumpWidget(
        SpringBuilder(
          from: 0.0,
          to: 1.0,
          spring: RestroSprings.bouncy,
          builder: (BuildContext _, double v, Widget? __) {
            if (v > maxObserved) maxObserved = v;
            return const SizedBox.shrink();
          },
        ),
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(maxObserved, greaterThan(1.10));
      expect(maxObserved, lessThan(1.30));
    });

    testWidgets('re-targets mid-flight without snap',
        (WidgetTester tester) async {
      double targetValue = 1.0;
      late void Function(void Function()) setStateOuter;
      await tester.pumpWidget(
        StatefulBuilder(
          builder:
              (BuildContext context, void Function(void Function()) setState) {
            setStateOuter = setState;
            return SpringBuilder(
              from: 0.0,
              to: targetValue,
              spring: RestroSprings.soft,
              builder: (BuildContext _, double v, Widget? __) =>
                  const SizedBox.shrink(),
            );
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      setStateOuter(() {
        targetValue = 0.5;
      });
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });
}
