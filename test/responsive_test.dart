import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/theme/tokens.dart';
import 'package:restro/widgets/dynamic_toast.dart';
import 'package:restro/widgets/numeric_keyboard.dart';
import 'package:restro/widgets/page_content_clamp.dart';
import 'package:restro/widgets/pin_pad.dart';

void _useSurface(WidgetTester tester, Size size, {double textScale = 1.0}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

TextStyle _paintedStyle(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  return paragraph.text.style!;
}

const _phone = Size(360, 800);
const _smallPhone = Size(320, 640);
const _tablet = Size(1024, 1366);
const _phoneLandscape = Size(800, 360);

void main() {
  group('Material ancestor', () {
    testWidgets('toast text is not underlined', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () =>
                    DynamicToast.show(context, message: 'Saved to the desk'),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Saved to the desk'), findsOneWidget);
      final style = _paintedStyle(tester, 'Saved to the desk');
      expect(style.decoration, isNot(TextDecoration.underline));
    });
  });

  group('PinPad', () {
    testWidgets('does not stretch to full tablet width', (tester) async {
      _useSurface(tester, _tablet);
      await tester.pumpWidget(_host(PinPad(
        onKeyPress: (_) {},
        onForgot: () {},
        onDelete: () {},
      )));

      final row = find
          .descendant(of: find.byType(PinPad), matching: find.byType(Row))
          .first;
      expect(tester.getSize(row).width, lessThanOrEqualTo(PinPad.maxWidth));
    });

    testWidgets('still fills a narrow phone', (tester) async {
      _useSurface(tester, _smallPhone);
      await tester.pumpWidget(_host(PinPad(
        onKeyPress: (_) {},
        onForgot: () {},
        onDelete: () {},
      )));

      final row = find
          .descendant(of: find.byType(PinPad), matching: find.byType(Row))
          .first;

      expect(tester.getSize(row).width, _smallPhone.width);
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a 2x font scale on a small phone', (tester) async {
      _useSurface(tester, _smallPhone, textScale: 2.0);
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: PinPad(
          onKeyPress: (_) {},
          onForgot: () {},
          onDelete: () {},
        ),
      )));

      expect(tester.takeException(), isNull);
    });
  });

  group('NumericKeyboard', () {
    testWidgets('is clamped to the same width as PinPad', (tester) async {
      _useSurface(tester, _tablet);
      await tester.pumpWidget(_host(NumericKeyboard(
        value: '12',
        onChanged: (_) {},
      )));

      final row = find
          .descendant(
              of: find.byType(NumericKeyboard), matching: find.byType(Row))
          .first;
      expect(tester.getSize(row).width, lessThanOrEqualTo(PinPad.maxWidth));
    });
  });

  group('PageContentClamp', () {
    testWidgets('leaves phone layouts full-bleed', (tester) async {
      _useSurface(tester, _phone);
      await tester.pumpWidget(
        _host(const PageContentClamp(child: SizedBox.expand())),
      );

      expect(tester.getSize(find.byType(SizedBox)).width, _phone.width);
    });

    testWidgets('caps content on a tablet', (tester) async {
      _useSurface(tester, _tablet);
      await tester.pumpWidget(
        _host(const PageContentClamp(child: SizedBox.expand())),
      );

      expect(
        tester.getSize(find.byType(SizedBox)).width,
        PageContentClamp.readable,
      );
    });

    testWidgets('a landscape phone is still below the two-pane bar',
        (tester) async {
      _useSurface(tester, _phoneLandscape);
      await tester.pumpWidget(
        _host(const PageContentClamp(child: SizedBox.expand())),
      );

      expect(
          tester.getSize(find.byType(SizedBox)).width, _phoneLandscape.width);
    });
  });

  group('breakpoints', () {
    test('two-pane only kicks in at tablet-wide', () {
      expect(const BoxConstraints(maxWidth: 360).isTwoPane, isFalse);
      expect(const BoxConstraints(maxWidth: 800).isTwoPane, isFalse);
      expect(const BoxConstraints(maxWidth: 920).isTwoPane, isTrue);
      expect(const BoxConstraints(maxWidth: 1366).isTwoPane, isTrue);
    });
  });
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );
