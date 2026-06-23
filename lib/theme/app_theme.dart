// Material ThemeData wired up from design tokens.
import 'package:flutter/material.dart';
import 'tokens.dart';

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: const ColorScheme.light(
        primary: AppColors.terra500,
        onPrimary: Colors.white,
        secondary: AppColors.violet,
        onSecondary: Colors.white,
        surface: AppColors.paper,
        onSurface: AppColors.ink,
        error: AppColors.danger,
        onError: Colors.white,
      ),
      textTheme: base.textTheme.copyWith(
        displayLarge: AppTypography.displayLg,
        displayMedium: AppTypography.displayMd,
        headlineMedium: AppTypography.headline,
        titleMedium: AppTypography.title,
        bodyLarge: AppTypography.body,
        bodyMedium: AppTypography.body,
        labelLarge: AppTypography.bodyMd,
        labelMedium: AppTypography.caption,
        labelSmall: AppTypography.micro,
      ),
      iconTheme: const IconThemeData(color: AppColors.ink, size: 22),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      // Any Material route that doesn't go through liquidPage still gets the
      // iOS push (parallax + interactive back) on every platform.
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
