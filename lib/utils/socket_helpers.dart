// Socket helper utilities shared across sheets and screens.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Schedules a timeout that fires [onTimeout] when both [isMounted] and
/// [isStillWaiting] return true at the time of expiry.
///
/// Returns the [Timer] so the caller can cancel it early if needed.
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
