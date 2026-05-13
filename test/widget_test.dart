import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:restro/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: RestroApp()));
    // Just verify the app can build and render without throwing.
    expect(find.byType(RestroApp), findsOneWidget);
  });
}
