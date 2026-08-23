sealed class RiveButtonPhase {
  const RiveButtonPhase();
}

final class RiveButtonIdle extends RiveButtonPhase {
  const RiveButtonIdle();
}

final class RiveButtonLoading extends RiveButtonPhase {
  const RiveButtonLoading();
}

final class RiveButtonSuccess extends RiveButtonPhase {
  const RiveButtonSuccess();
}

final class RiveButtonError extends RiveButtonPhase {
  const RiveButtonError();
}
