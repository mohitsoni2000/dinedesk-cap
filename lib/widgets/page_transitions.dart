import 'package:flutter/cupertino.dart';

Page<void> liquidPage({
  LocalKey? key,
  required Widget child,
  Duration duration = const Duration(milliseconds: 360),
  bool fromBottom = false,
}) {
  if (fromBottom) {
    return CupertinoPage<void>(
      key: key,
      child: child,
      fullscreenDialog: true,
    );
  }

  return CupertinoPage<void>(key: key, child: child);
}
