/// A button's send/loading/success/error phase — reused by
/// send_kot_button.dart. Despite the name, this file no longer depends on
/// the `rive` package: the Rive-animated button widget that used to live
/// here had zero call sites and was deleted; this sealed hierarchy is the
/// only part of it still in use.
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
