import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/predictive_zone.dart';

void main() {
  group('PredictiveZone', () {
    testWidgets('reports nothing when disabled', (WidgetTester tester) async {
      double captured = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PredictiveZone(
                enabled: false,
                onIntentProximity: (double p) {
                  captured = p;
                },
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(captured, -1);
    });

    testWidgets('renders child', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PredictiveZone(
              onIntentProximity: (_) {},
              child: const Text('Hello'),
            ),
          ),
        ),
      );
      expect(find.text('Hello'), findsOneWidget);
    });
  });

  testWidgets('PredictiveScale renders AnimatedScale',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: PredictiveScale(child: Text('Button')),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(AnimatedScale), findsOneWidget);
  });
}
