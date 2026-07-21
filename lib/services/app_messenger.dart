import '../router.dart';
import '../widgets/dynamic_toast.dart';

/// Lets background services (sync_service.dart) with no BuildContext of
/// their own surface server-side action failures (error:validation /
/// error:permission) that a fire-and-forget emit() would otherwise drop
/// silently — routed through the same DynamicToast every screen uses.
void showAppToast(String message, {ToastKind kind = ToastKind.error}) {
  final context = rootNavigatorKey.currentContext;
  if (context == null) return;
  DynamicToast.show(context, message: message, kind: kind);
}
