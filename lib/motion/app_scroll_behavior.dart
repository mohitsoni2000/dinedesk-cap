// Global scroll behavior — gives every scrollable in the app the iOS
// rubber-band "bounce" overscroll, on Android too.
//
// Wire it once on MaterialApp.router(scrollBehavior: const AppScrollBehavior()).
// After that, every ListView / CustomScrollView / SingleChildScrollView in the
// app inherits BouncingScrollPhysics with no per-screen changes.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  // iOS rubber-band on every platform. AlwaysScrollable so short lists still
  // bounce (matches the iOS feel where even a half-full screen tugs back).
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  // iOS doesn't show a scrollbar by default and never paints the Android
  // glow/stretch overscroll indicator — suppress both so the bounce reads clean.
  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  // Allow trackpad/mouse drag in addition to touch (useful on tablets / desktop
  // debug) without changing the touch feel.
  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}
