import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/kinetic_counter.dart';

void main() {
  group('CounterAxisMap', () {
    test('idle map has correct weight', () {
      expect(CounterAxisMap.idle.weight, 350);
      expect(CounterAxisMap.idle.italicSlant, 0);
    });

    test('lerp at t=0 returns first map', () {
      final CounterAxisMap mid =
          CounterAxisMap.lerp(CounterAxisMap.idle, CounterAxisMap.heavy, 0);
      expect(mid.weight, equals(CounterAxisMap.idle.weight));
    });

    test('lerp at t=1 returns second map', () {
      final CounterAxisMap mid =
          CounterAxisMap.lerp(CounterAxisMap.idle, CounterAxisMap.heavy, 1);
      expect(mid.weight, equals(CounterAxisMap.heavy.weight));
    });

    test('forAmount(0) returns idle', () {
      final CounterAxisMap a = CounterAxisMap.forAmount(0);
      expect(a.weight, equals(CounterAxisMap.idle.weight));
    });

    test('forAmount(2500) returns heavy', () {
      final CounterAxisMap a = CounterAxisMap.forAmount(2500);
      expect(a.weight, equals(CounterAxisMap.heavy.weight));
    });
  });

  group('KineticRupeeCounter', () {
    testWidgets('renders Indian-locale grouped numbers',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: KineticRupeeCounter(amount: 1234567)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('₹12,34,567'), findsOneWidget);
    });
  });
}
