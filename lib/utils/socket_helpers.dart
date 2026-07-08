

import 'dart:async';

import 'package:flutter/foundation.dart';

Timer scheduleSocketTimeout({
  required Duration duration,
  required bool Function() isMounted,
  required bool Function() isStillWaiting,
  required VoidCallback onTimeout,
}) {
  return Timer(duration, () {
    if (isMounted() && isStillWaiting()) {
      onTimeout();
    }
  });
}
