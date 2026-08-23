import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/pressable.dart';
import 'package:restro/theme/tokens.dart';
import 'package:restro/widgets/app_card.dart';
import 'package:restro/widgets/app_surface.dart';

double contrastRatio(Color fg, Color bg) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);

  final a = fg.a;
  final flattened = Color.from(
    alpha: 1.0,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );

  final l1 = luminance(flattened);
  final l2 = luminance(bg);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('contrast — read on a cheap phone, under glare, often over 40', () {
    for (final entry in <(String, AppPalette)>[
      ('light', AppPalette.light),
      ('dark', AppPalette.dark),
    ]) {
      final (name, p) = entry;

      test('$name: ink and ink70 carry body text at AA (4.5:1)', () {
        for (final bg in <Color>[p.paper, p.surface]) {
          expect(contrastRatio(p.ink, bg), greaterThanOrEqualTo(4.5));
          expect(contrastRatio(p.ink70, bg), greaterThanOrEqualTo(4.5));
        }
      });

      test('$name: ink50 reaches AA', () {
        for (final bg in <Color>[p.paper, p.surface]) {
          expect(contrastRatio(p.ink50, bg), greaterThanOrEqualTo(4.5),
              reason: 'ink50 on $name');
        }
      });

      test('$name: ink30 clears the 3:1 floor for UI and large text', () {
        for (final bg in <Color>[p.paper, p.surface]) {
          expect(contrastRatio(p.ink30, bg), greaterThanOrEqualTo(3.0),
              reason: 'ink30 on $name');
        }
      });
    }
  });

  group('type scale', () {
    test('status badges are not the smallest text in the app', () {
      expect(AppTypography.pill.fontSize, greaterThanOrEqualTo(12));
      expect(
        AppTypography.pill.fontSize,
        greaterThanOrEqualTo(AppTypography.micro.fontSize!),
      );
    });
  });

  group('touch targets', () {
    test('the declared minimum meets platform guidance', () {
      expect(AppTouchTargets.minimum, greaterThanOrEqualTo(44));
    });
  });

  group('Pressable — the app’s universal tappable', () {
    testWidgets('publishes a labelled button to screen readers',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Pressable(
              onTap: () {},
              semanticLabel: 'Turn torch on',
              child: const Icon(Icons.flash_on),
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(Pressable)),
        isSemantics(
          label: 'Turn torch on',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );

      handle.dispose();
    });

    testWidgets('a disabled one is not announced as tappable', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Pressable(
              enabled: false,
              semanticLabel: 'Send KOT',
              child: Icon(Icons.send),
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(Pressable)),
        isSemantics(isEnabled: false, hasTapAction: false),
      );
      handle.dispose();
    });
  });

  group('card surfaces give a ListTile a Material to splash onto', () {
    for (final entry in <(String, Widget Function(Widget))>[
      ('AppCard', (child) => AppCard(padding: EdgeInsets.zero, child: child)),
      (
        'AppSurface',
        (child) => AppSurface(padding: EdgeInsets.zero, child: child)
      ),
    ]) {
      final (name, wrap) = entry;

      testWidgets(name, (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: wrap(
                ListTile(title: const Text('Performance'), onTap: () {}),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull, reason: '$name asserted');

        final material = tester.widget<Material>(
          find
              .ancestor(
                of: find.byType(ListTile),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, isNotNull, reason: '$name has no Material fill');
        expect(material.color, isNot(Colors.transparent));
      });
    }
  });
}
