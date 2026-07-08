

import 'package:flutter/material.dart';
import 'tokens.dart';

class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(AppPalette.light);

  static ThemeData dark() => _build(AppPalette.dark);

  static ThemeData _build(AppPalette p) {
    final base = p.isDark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    TextStyle inked(TextStyle s) => s.copyWith(color: p.ink);
    return base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: ColorScheme(
        brightness: p.brightness,
        primary: AppColors.terra500,
        onPrimary: Colors.white,
        secondary: AppColors.violet,
        onSecondary: Colors.white,
        surface: p.surface,
        onSurface: p.ink,
        error: AppColors.danger,
        onError: Colors.white,
      ),
      textTheme: base.textTheme.copyWith(
        displayLarge: inked(AppTypography.displayLg),
        displayMedium: inked(AppTypography.displayMd),
        headlineMedium: inked(AppTypography.headline),
        titleMedium: inked(AppTypography.title),
        bodyLarge: inked(AppTypography.body),
        bodyMedium: inked(AppTypography.body),
        labelLarge: inked(AppTypography.bodyMd),
        labelMedium: AppTypography.caption.copyWith(color: p.ink70),
        labelSmall: AppTypography.micro.copyWith(color: p.ink70),
      ),
      iconTheme: IconThemeData(color: p.ink, size: 22),
      dividerColor: p.ink10,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
