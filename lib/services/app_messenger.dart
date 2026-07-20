import 'package:flutter/material.dart';

/// App-wide SnackBar host. Background services (sync_service.dart) have no
/// BuildContext of their own, but still need to surface server-side action
/// failures (error:validation / error:permission) that a fire-and-forget
/// emit() would otherwise drop silently.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showAppSnackBar(String message) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}
