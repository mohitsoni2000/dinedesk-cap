import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/feedback_kind.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FeedbackKind', () {
    test('all kinds map to a haptic without throwing', () async {
      final List<FeedbackKind> all = <FeedbackKind>[
        const FeedbackLight(),
        const FeedbackMedium(),
        const FeedbackHeavy(),
        const FeedbackSuccess(),
        const FeedbackError(),
        const FeedbackWarning(),
        const FeedbackSelection(),
      ];
      for (final FeedbackKind kind in all) {
        await kind.triggerHaptic();
      }
    });

    test('audio asset paths are valid keys or null', () {
      const List<FeedbackKind> all = <FeedbackKind>[
        FeedbackLight(),
        FeedbackMedium(),
        FeedbackHeavy(),
        FeedbackSuccess(),
        FeedbackError(),
        FeedbackWarning(),
        FeedbackSelection(),
      ];
      for (final FeedbackKind k in all) {
        final String? asset = k.audioAsset;
        if (asset != null) {
          expect(asset, startsWith('audio/'));
          expect(asset, endsWith('.mp3'));
        }
      }
    });
  });
}
