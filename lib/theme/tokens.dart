

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const terra50 = Color(0xFFFFF1EA);
  static const terra100 = Color(0xFFFFD6BE);
  static const terra200 = Color(0xFFFFB793);
  static const terra300 = Color(0xFFF59474);
  static const terra400 = Color(0xFFED6E47);
  static const terra500 = Color(0xFFE05D38);
  static const terra600 = Color(0xFFD4501F);
  static const terra700 = Color(0xFFB23E15);

  static const ink = Color(0xFF140E08);
  static const ink70 = Color(0xB3140E08);
  static const ink50 = Color(0x80140E08);
  static const ink30 = Color(0x4D140E08);
  static const ink10 = Color(0x1A140E08);
  static const ink05 = Color(0x0D140E08);
  static const amber = Color(0xFFF59E0B);

  static const readOnlyBannerBg = Color(0xFFFEF3C7);
  static const readOnlyBannerText = Color(0xFF92400E);

  static const trendingDot = Color(0xFFFF6B35);

  static const paper = Color(0xFFFFFCF8);
  static const paperWarm = Color(0xFFF9E8D2);
  static const paperDeeper = Color(0xFFF2DBC0);

  static const success = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF3B82F6);
  static const violet = Color(0xFFA855F7);
  static const teal = Color(0xFF14B8A6);

  static const tableMineBg = Color(0xFFFFE8DC);
  static const tableMineBorder = Color(0x73ED6E47);
  static const tableOtherBg = Color(0xFFDCEAFE);
  static const tableDirtyBg = Color(0xFFFDF0DC);
  static const tableReservedBg = Color(0xFFF0E8FB);
  static const tableFreeBg = Color(0xFFE8F5EC);

  static const logoBg = Color(0xFF2A2622);

  static const gold = Color(0xFFFFB964);

  static const paperHint = Color(0xFFFFF6EA);

  static const meshDark1 = Color(0xFF2A1A10);
  static const meshDark2 = Color(0xFF1C130C);
  static const meshDark3 = Color(0xFF14100C);

  static const scrim = Color(0x33000000);

  static const counterPaper = Color(0xFFF4EDE0);
}

class AppPalette {
  final Brightness brightness;

  final Color ink;
  final Color ink70;
  final Color ink50;
  final Color ink30;
  final Color ink10;
  final Color ink05;

  final Color surface;
  final Color surfaceWarm;
  final Color counterPaper;

  final Color tableMineBg;
  final Color tableOtherBg;
  final Color tableDirtyBg;
  final Color tableReservedBg;
  final Color tableFreeBg;

  final Color readOnlyBannerBg;
  final Color readOnlyBannerText;

  const AppPalette._({
    required this.brightness,
    required this.ink,
    required this.ink70,
    required this.ink50,
    required this.ink30,
    required this.ink10,
    required this.ink05,
    required this.surface,
    required this.surfaceWarm,
    required this.counterPaper,
    required this.tableMineBg,
    required this.tableOtherBg,
    required this.tableDirtyBg,
    required this.tableReservedBg,
    required this.tableFreeBg,
    required this.readOnlyBannerBg,
    required this.readOnlyBannerText,
  });

  bool get isDark => brightness == Brightness.dark;

  TextStyle get caption => AppTypography.caption.copyWith(color: ink70);
  TextStyle get micro => AppTypography.micro.copyWith(color: ink70);

  static const light = AppPalette._(
    brightness: Brightness.light,
    ink: AppColors.ink,
    ink70: AppColors.ink70,
    ink50: AppColors.ink50,
    ink30: AppColors.ink30,
    ink10: AppColors.ink10,
    ink05: AppColors.ink05,
    surface: AppColors.paper,
    surfaceWarm: AppColors.paperWarm,
    counterPaper: AppColors.counterPaper,
    tableMineBg: AppColors.tableMineBg,
    tableOtherBg: AppColors.tableOtherBg,
    tableDirtyBg: AppColors.tableDirtyBg,
    tableReservedBg: AppColors.tableReservedBg,
    tableFreeBg: AppColors.tableFreeBg,
    readOnlyBannerBg: AppColors.readOnlyBannerBg,
    readOnlyBannerText: AppColors.readOnlyBannerText,
  );

  static const dark = AppPalette._(
    brightness: Brightness.dark,
    ink: Color(0xFFF5EEE3),
    ink70: Color(0xB3F5EEE3),
    ink50: Color(0x80F5EEE3),
    ink30: Color(0x4DF5EEE3),
    ink10: Color(0x1AF5EEE3),
    ink05: Color(0x0DF5EEE3),
    surface: Color(0xFF281E14),
    surfaceWarm: Color(0xFF2F2418),
    counterPaper: Color(0xFF2F2418),
    tableMineBg: Color(0xFF3D2417),
    tableOtherBg: Color(0xFF1D2B3D),
    tableDirtyBg: Color(0xFF3A2C12),
    tableReservedBg: Color(0xFF2C2140),
    tableFreeBg: Color(0xFF1C3024),
    readOnlyBannerBg: Color(0xFF3B2F10),
    readOnlyBannerText: Color(0xFFFCD34D),
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

extension AppPaletteX on BuildContext {
  AppPalette get palette => AppPalette.of(this);
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
    letterSpacing: -0.4,
  );

  static const TextStyle displayMd = TextStyle(
    fontFamily: cormorant,
    fontWeight: FontWeight.w500,
    fontSize: 28,
    height: 1.15,
    letterSpacing: -0.3,
  );

  static const TextStyle headline = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w700,
    fontSize: 22,
    height: 1.2,
    letterSpacing: -0.2,
  );

  static const TextStyle title = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w600,
    fontSize: 17,
    height: 1.25,
  );

  static const TextStyle body = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 1.4,
  );

  static const TextStyle bodyMd = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w500,
    fontSize: 15,
    height: 1.4,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    height: 1.3,
    letterSpacing: 0.1,
  );

  static const TextStyle micro = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w600,
    fontSize: 11,
    height: 1.2,
    letterSpacing: 0.6,
  );

  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w500,
    fontSize: 14,
  );
}

class AppShadows {
  AppShadows._();

  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0A140E08), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0D140E08), blurRadius: 10, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x0D140E08), blurRadius: 24, offset: Offset(0, 12)),
  ];

  static const List<BoxShadow> elevated = [
    BoxShadow(color: Color(0x14140E08), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x1F140E08), blurRadius: 28, offset: Offset(0, 12)),
    BoxShadow(color: Color(0x24140E08), blurRadius: 64, offset: Offset(0, 36)),
  ];

  static const List<BoxShadow> terraGlow = [
    BoxShadow(color: Color(0x2DE05D38), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x52E05D38), blurRadius: 20, offset: Offset(0, 8)),
  ];

  static const List<BoxShadow> logoGlow = [
    BoxShadow(color: Color(0x4DE05D38), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x1AE05D38), blurRadius: 48, offset: Offset(0, 20)),
  ];

  static const List<BoxShadow> glass = [
    BoxShadow(color: Color(0x08140E08), blurRadius: 1, offset: Offset(0, 0)),
    BoxShadow(color: Color(0x0A140E08), blurRadius: 8, offset: Offset(0, 3)),
    BoxShadow(color: Color(0x12140E08), blurRadius: 28, offset: Offset(0, 14)),
    BoxShadow(color: Color(0x0A140E08), blurRadius: 56, offset: Offset(0, 28)),
  ];
}

class AppAlphas {
  AppAlphas._();

  static const double overlayHeavy = 0.92;
  static const double overlayMedium = 0.68;
  static const double overlayLight = 0.35;

  static const double glassTintLight = 0.06;
  static const double glassTintMedium = 0.10;
  static const double glassTintHeavy = 0.18;
  static const double glassTintDanger = 0.22;

  static const double badgeLight = 0.10;
  static const double badgeMedium = 0.14;
  static const double badgeStrong = 0.20;

  static const double buttonHover = 0.50;
  static const double buttonPressed = 0.60;
  static const double buttonDisabled = 0.30;

  static const double successOverlay = 0.14;
  static const double warnOverlay = 0.12;
  static const double dangerOverlay = 0.12;
  static const double infoOverlay = 0.10;

  static const double chipDefault = 0.08;
  static const double chipActive = 0.18;
  static const double chipAmber = 0.22;

  static const double dividerLight = 0.08;
  static const double dividerMedium = 0.12;

  static const double progressBg = 0.10;

  static const double bannerDanger = 0.12;
  static const double bannerWarn = 0.18;
}

class AppRadiiValues {
  AppRadiiValues._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double pill = 9999;
}

class AppTouchTargets {
  AppTouchTargets._();

  static const double minimum = 48;

  static const double standard = 48;

  static const double control = 48;

  static const double chip = 48;

  static const double tab = 48;

  static const double iconButton = 48;

  static const double cta = 56;
}

class AppControlSizes {
  AppControlSizes._();

  static const double sheetHandleWidth = 40;
  static const double sheetHandleHeight = 4;

  static const double iconTile = 44;

  static const double avatar = 56;
}

class AppIconSizes {
  AppIconSizes._();

  static const double micro = 12;

  static const double control = 16;

  static const double standard = 18;

  static const double body = 20;

  static const double title = 22;

  static const double headline = 28;

  static const double display = 36;
}

class AppSheetPadding {
  AppSheetPadding._();

  static const EdgeInsets sheet = EdgeInsets.all(20);

  static const EdgeInsets compact = EdgeInsets.all(16);

  static const EdgeInsets large = EdgeInsets.all(24);

  static const EdgeInsets content = EdgeInsets.symmetric(horizontal: 20, vertical: 16);

  static const EdgeInsets input = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
}

class AppSectionSpacing {
  AppSectionSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppMotion {
  AppMotion._();

  static const Duration quick = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration xslow = Duration(milliseconds: 600);

  static const Curve entrance = Curves.easeOutCubic;

  static const Curve exit = Curves.easeIn;

  static const Curve symmetric = Curves.easeInOut;

  static const Curve spring = Curves.elasticOut;
}

class AppChipPadding {
  AppChipPadding._();

  static const EdgeInsets filterChip = EdgeInsets.symmetric(horizontal: 14, vertical: 12);

  static const EdgeInsets compactChip = EdgeInsets.symmetric(horizontal: 12, vertical: 10);

  static const EdgeInsets statusBadge = EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  static const EdgeInsets sectionLabel = EdgeInsets.symmetric(horizontal: 14, vertical: 8);
}
