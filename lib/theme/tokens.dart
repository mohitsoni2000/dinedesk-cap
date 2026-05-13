// Design tokens — ported from restro-mobile.css / restro-liquid-glass.css.
//
// Single source of truth for colors, typography, spacing, radii.
// Keep these aligned with the HTML design system.

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Brand — terra (the warm orange across the entire system)
  static const terra50  = Color(0xFFFFF1EA);
  static const terra100 = Color(0xFFFFD6BE);
  static const terra200 = Color(0xFFFFB793);
  static const terra300 = Color(0xFFF59474);
  static const terra400 = Color(0xFFED6E47);
  static const terra500 = Color(0xFFE05D38); // primary
  static const terra600 = Color(0xFFD4501F);
  static const terra700 = Color(0xFFB23E15);

  // Ink (warm near-black) and paper (warm cream)
  static const ink   = Color(0xFF140E08);
  static const ink70 = Color(0xB3140E08);
  static const ink50 = Color(0x80140E08);
  static const ink30 = Color(0x4D140E08);
  static const ink10 = Color(0x1A140E08);
  static const ink05 = Color(0x0D140E08);
  static const amber = Color(0xFFF59E0B);

  static const paper       = Color(0xFFFFFCF8);
  static const paperWarm   = Color(0xFFF9E8D2);
  static const paperDeeper = Color(0xFFF2DBC0);

  // Semantic
  static const success = Color(0xFF22C55E);
  static const warn    = Color(0xFFF59E0B);
  static const danger  = Color(0xFFDC2626);
  static const info    = Color(0xFF3B82F6);
  static const violet  = Color(0xFFA855F7);
  static const teal    = Color(0xFF14B8A6);

  // Table state colors
  static const tableMineBg     = Color(0xFFFFE8DC);
  static const tableMineBorder = Color(0x73ED6E47);
  static const tableOtherBg    = Color(0xFFDCEAFE);
  static const tableDirtyBg    = Color(0xFFFDF0DC);
  static const tableReservedBg = Color(0xFFF0E8FB);
  static const tableFreeBg     = Color(0xFFE8F5EC);
}

class AppRadii {
  AppRadii._();
  static const xs = Radius.circular(8);
  static const sm = Radius.circular(12);
  static const md = Radius.circular(16);
  static const lg = Radius.circular(20);
  static const xl = Radius.circular(28);
  static const pill = Radius.circular(9999);
}

class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

class AppTypography {
  AppTypography._();

  static const String inter = 'Inter';
  static const String cormorant = 'Cormorant';

  static const TextStyle displayLg = TextStyle(
    fontFamily: cormorant,
    fontWeight: FontWeight.w500,
    fontSize: 36,
    height: 1.1,
    color: AppColors.ink,
    letterSpacing: -0.4,
  );

  static const TextStyle displayMd = TextStyle(
    fontFamily: cormorant,
    fontWeight: FontWeight.w500,
    fontSize: 28,
    height: 1.15,
    color: AppColors.ink,
    letterSpacing: -0.3,
  );

  static const TextStyle headline = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    height: 1.2,
    color: AppColors.ink,
    letterSpacing: -0.2,
  );

  static const TextStyle title = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w600,
    fontSize: 17,
    height: 1.25,
    color: AppColors.ink,
  );

  static const TextStyle body = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 1.4,
    color: AppColors.ink,
  );

  static const TextStyle bodyMd = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w500,
    fontSize: 15,
    height: 1.4,
    color: AppColors.ink,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    height: 1.3,
    color: AppColors.ink70,
    letterSpacing: 0.1,
  );

  static const TextStyle micro = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w600,
    fontSize: 10,
    height: 1.2,
    color: AppColors.ink50,
    letterSpacing: 0.6,
  );

  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w500,
    fontSize: 14,
    color: AppColors.ink,
  );
}

class AppShadows {
  AppShadows._();

  /// Subtle ambient shadow for solid cards.
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0A140E08), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0D140E08), blurRadius: 10, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x0D140E08), blurRadius: 24, offset: Offset(0, 12)),
  ];

  /// Heavier shadow for floating elements / modals.
  static const List<BoxShadow> elevated = [
    BoxShadow(color: Color(0x14140E08), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x1F140E08), blurRadius: 28, offset: Offset(0, 12)),
    BoxShadow(color: Color(0x24140E08), blurRadius: 64, offset: Offset(0, 36)),
  ];

  /// Terra-tinted shadow for primary buttons / mine table cards.
  static const List<BoxShadow> terraGlow = [
    BoxShadow(color: Color(0x2DE05D38), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x52E05D38), blurRadius: 20, offset: Offset(0, 8)),
  ];
}
