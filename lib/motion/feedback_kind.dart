import 'package:flutter/services.dart';

sealed class FeedbackKind {
  const FeedbackKind();
}

final class FeedbackLight extends FeedbackKind {
  const FeedbackLight();
}

final class FeedbackMedium extends FeedbackKind {
  const FeedbackMedium();
}

final class FeedbackHeavy extends FeedbackKind {
  const FeedbackHeavy();
}

final class FeedbackSuccess extends FeedbackKind {
  const FeedbackSuccess();
}

final class FeedbackError extends FeedbackKind {
  const FeedbackError();
}

final class FeedbackWarning extends FeedbackKind {
  const FeedbackWarning();
}

final class FeedbackSelection extends FeedbackKind {
  const FeedbackSelection();
}

extension FeedbackHaptic on FeedbackKind {
  Future<void> triggerHaptic() async {
    switch (this) {
      case FeedbackLight():
        await HapticFeedback.lightImpact();
      case FeedbackMedium():
        await HapticFeedback.mediumImpact();
      case FeedbackHeavy():
        await HapticFeedback.heavyImpact();
      case FeedbackSuccess():
        await HapticFeedback.mediumImpact();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await HapticFeedback.lightImpact();
      case FeedbackError():
        await HapticFeedback.heavyImpact();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await HapticFeedback.heavyImpact();
      case FeedbackWarning():
        await HapticFeedback.mediumImpact();
      case FeedbackSelection():
        await HapticFeedback.selectionClick();
    }
  }

  String? get audioAsset => null;
}
