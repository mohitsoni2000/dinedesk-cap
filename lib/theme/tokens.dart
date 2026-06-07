// Design tokens — ported from restro-mobile.css / restro-liquid-glass.css.
//
// Single source of truth for colors, typography, spacing, radii.
// Keep these aligned with the HTML design system.

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Brand — terra (the warm orange across the entire system)
  static const terra50 = Color(0xFFFFF1EA);
  static const terra100 = Color(0xFFFFD6BE);
  static const terra200 = Color(0xFFFFB793);
  static const terra300 = Color(0xFFF59474);
  static const terra400 = Color(0xFFED6E47);
  static const terra500 = Color(0xFFE05D38); // primary
  static const terra600 = Color(0xFFD4501F);
  static const terra700 = Color(0xFFB23E15);

  // Ink (warm near-black) and paper (warm cream)
  static const ink = Color(0xFF140E08);
  static const ink70 = Color(0xB3140E08);
  static const ink50 = Color(0x80140E08);
  static const ink30 = Color(0x4D140E08);
  static const ink10 = Color(0x1A140E08);
  static const ink05 = Color(0x0D140E08);
  static const amber = Color(0xFFF59E0B);

  // Read-only / view-only mode banner (warn amber spectrum)
  static const readOnlyBannerBg = Color(0xFFFEF3C7);
  static const readOnlyBannerText = Color(0xFF92400E);

  // Trending item indicator dot in fast-add bar
  static const trendingDot = Color(0xFFFF6B35);

  static const paper = Color(0xFFFFFCF8);
  static const paperWarm = Color(0xFFF9E8D2);
  static const paperDeeper = Color(0xFFF2DBC0);

  // Semantic
  static const success = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF3B82F6);
  static const violet = Color(0xFFA855F7);
  static const teal = Color(0xFF14B8A6);

  // Table state colors
  static const tableMineBg = Color(0xFFFFE8DC);
  static const tableMineBorder = Color(0x73ED6E47);
  static const tableOtherBg = Color(0xFFDCEAFE);
  static const tableDirtyBg = Color(0xFFFDF0DC);
  static const tableReservedBg = Color(0xFFF0E8FB);
  static const tableFreeBg = Color(0xFFE8F5EC);

  // Brand — app logo / hero container background
  static const logoBg = Color(0xFF2A2622);

  // Achievement — warm gold for KOT success, kinetic counters
  static const gold = Color(0xFFFFB964);

  // Paper gradient — mesh background top-left (between paper and paperWarm)
  static const paperHint = Color(0xFFFFF6EA);

  // Dark mesh background gradient stops
  static const meshDark1 = Color(0xFF2A1A10);
  static const meshDark2 = Color(0xFF1C130C);
  static const meshDark3 = Color(0xFF14100C);
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

  /// Deep terra glow for the hero app icon container (88px logo).
  static const List<BoxShadow> logoGlow = [
    BoxShadow(color: Color(0x4DE05D38), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x1AE05D38), blurRadius: 48, offset: Offset(0, 20)),
  ];

  /// Shadow for glass surfaces — softer, more diffuse than card shadow.
  /// Glass floats above content, needs a deeper ambient shadow.
  static const List<BoxShadow> glass = [
    BoxShadow(color: Color(0x08140E08), blurRadius: 1, offset: Offset(0, 0)),
    BoxShadow(color: Color(0x0A140E08), blurRadius: 8, offset: Offset(0, 3)),
    BoxShadow(color: Color(0x12140E08), blurRadius: 28, offset: Offset(0, 14)),
    BoxShadow(color: Color(0x0A140E08), blurRadius: 56, offset: Offset(0, 28)),
  ];
}

/// Reusable alpha/opacity values for consistent visual weight.
class AppAlphas {
  AppAlphas._();

  /// Surface overlays
  static const double overlayHeavy = 0.92;   // review screen backdrop
  static const double overlayMedium = 0.68; // scan overlay
  static const double overlayLight = 0.35;  // subtle tints

  /// Glass tint layers
  static const double glassTintLight = 0.06;   // white on dark
  static const double glassTintMedium = 0.10;  // standard glass
  static const double glassTintHeavy = 0.18;   // strong tint
  static const double glassTintDanger = 0.22;  // danger glass

  /// Badge/status backgrounds
  static const double badgeLight = 0.10;  // subtle badge bg
  static const double badgeMedium = 0.14; // standard badge bg
  static const double badgeStrong = 0.20; // high-contrast badge bg

  /// Button tints
  static const double buttonHover = 0.50;  // white overlay on buttons
  static const double buttonPressed = 0.60;
  static const double buttonDisabled = 0.30;

  /// Semantic overlays
  static const double successOverlay = 0.14; // success tint backgrounds
  static const double warnOverlay = 0.12;    // warn tint backgrounds
  static const double dangerOverlay = 0.12;   // danger tint backgrounds
  static const double infoOverlay = 0.10;     // info tint backgrounds

  /// Chip/text fields
  static const double chipDefault = 0.08;   // chip bg
  static const double chipActive = 0.18;     // active chip bg
  static const double chipAmber = 0.22;      // amber chip bg

  /// Divider/border
  static const double dividerLight = 0.08;
  static const double dividerMedium = 0.12;

  /// Progress/bar backgrounds
  static const double progressBg = 0.10;

  /// Banner tints
  static const double bannerDanger = 0.12;
  static const double bannerWarn = 0.18;
}

/// Inline radius values for when you need the raw double (e.g., Container decoration).
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

/// Touch target sizes — 48px is the WCAG AA minimum for interactive elements.
class AppTouchTargets {
  AppTouchTargets._();

  /// Minimum recommended touch target (WCAG AA)
  static const double minimum = 48;

  /// Standard interactive element
  static const double standard = 48;

  /// Small inline control (stepper, icon button)
  static const double control = 48;

  /// Chip / filter pill
  static const double chip = 48;

  /// Section tab (floor tabs)
  static const double tab = 48;

  /// Icon-only button
  static const double iconButton = 48;

  /// Large CTA button (primary action)
  static const double cta = 56;
}

/// Icon sizes for consistent visual hierarchy.
class AppIconSizes {
  AppIconSizes._();

  /// Micro — badge counters, small labels
  static const double micro = 12;

  /// Control — stepper +/-, chip icons
  static const double control = 16;

  /// Standard — list item icons, inline controls
  static const double standard = 18;

  /// Body — section headers, prominent icons
  static const double body = 20;

  /// Title — AppBar icons, feature icons
  static const double title = 22;

  /// Headline — empty state icons, feature illustrations
  static const double headline = 28;

  /// Display — large decorative illustrations
  static const double display = 36;
}

/// Sheet / modal padding tokens for consistent inner margins.
class AppSheetPadding {
  AppSheetPadding._();

  /// Standard sheet outer padding
  static const EdgeInsets sheet = EdgeInsets.all(20);

  /// Compact sheet for smaller modals
  static const EdgeInsets compact = EdgeInsets.all(16);

  /// Large sheet for feature modals
  static const EdgeInsets large = EdgeInsets.all(24);

  /// Content area — text + actions
  static const EdgeInsets content = EdgeInsets.symmetric(horizontal: 20, vertical: 16);

  /// Input fields within sheets
  static const EdgeInsets input = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
}

/// Section spacing — vertical gaps between sections within a screen/sheet.
class AppSectionSpacing {
  AppSectionSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

/// Motion tokens — durations and curves for consistent animation feel.
class AppMotion {
  AppMotion._();

  // Durations — ordered from micro-interaction to large reveal
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration xslow = Duration(milliseconds: 600);

  // Curves
  /// Smooth deceleration — use for entrances and settling.
  static const Curve entrance = Curves.easeOutCubic;

  /// Sharp acceleration — use for exits and dismissals.
  static const Curve exit = Curves.easeIn;

  /// Symmetric ease — use for transitions with no clear in/out direction.
  static const Curve symmetric = Curves.easeInOut;

  /// Elastic overshoot — use for success states and celebrations.
  static const Curve spring = Curves.elasticOut;
}

/// Chip / pill specific tokens.
class AppChipPadding {
  AppChipPadding._();

  /// Filter chip (section filter, floor tabs)
  static const EdgeInsets filterChip = EdgeInsets.symmetric(horizontal: 14, vertical: 12);

  /// Compact chip (fast-add, recent items)
  static const EdgeInsets compactChip = EdgeInsets.symmetric(horizontal: 12, vertical: 10);

  /// Status badge (table state, order status)
  static const EdgeInsets statusBadge = EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  /// Section label (chip-like section headers)
  static const EdgeInsets sectionLabel = EdgeInsets.symmetric(horizontal: 14, vertical: 8);
}
