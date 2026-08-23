import 'package:flutter/material.dart';
import '../motion/physics.dart';
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
      scaffoldBackgroundColor: p.paper,
      colorScheme: ColorScheme(
        brightness: p.brightness,
        primary: AppColors.terra,
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
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.isDark ? p.elevated : AppColors.ink,
        contentTextStyle:
            AppTypography.bodyMd.copyWith(color: const Color(0xFFF5EEE3)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      bottomSheetTheme: const BottomSheetThemeData().copyWith(
        backgroundColor: p.elevated,
        surfaceTintColor: Colors.transparent,
        constraints: const BoxConstraints(maxWidth: 640),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.elevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        hintStyle: AppTypography.body.copyWith(color: p.ink30),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.hairline, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.terra, width: 1.5),
        ),
      ),
      dividerColor: p.ink10,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values)
            platform: const SpringPageTransitionsBuilder(),
        },
      ),
    );
  }
}
