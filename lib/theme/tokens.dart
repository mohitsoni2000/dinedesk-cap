import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'perf_mode.dart';
import 'perf_scope.dart';

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

  // "Light" design system terracotta — same ramp, named per the token spec.
  static const terra = Color(0xFFE05D38);
  static const terraDeep = Color(0xFFB23E15);
  static const terraInk = Color(0xFF8A3212);
  static const terraSoft = Color(0xFFFFE3D6);

  // The numbers in these names are tiers, not literal alpha percentages any
  // more. They are tuned for contrast against `paper` (#F9F5EE) and `card`
  // (#FFFFFF), measured with the WCAG 2.1 formula:
  //
  //   ink    16.92:1 / 18.38:1   AA + AAA
  //   ink70   6.56:1 /  6.82:1   AA + AAA
  //   ink50   4.70:1 /  4.82:1   AA        (was 0x80 → 3.40:1, failed)
  //   ink30   3.40:1 /  3.48:1   AA-large + UI components
  //                              (was 0x4D → 1.96:1, effectively invisible)
  //
  // ink30 is for disabled controls and placeholders only — it does not carry
  // body text. ink10/ink05 are fills and hairlines, never text.
  //
  // This matters more here than in an office app: the operator is reading a
  // cheap phone at arm's length under restaurant lighting, often with glare,
  // and may well be over 40 — contrast sensitivity drops with age.
  static const ink = Color(0xFF1A130C);
  static const ink70 = Color(0xB31A130C);
  static const ink50 = Color(0x991A130C);
  static const ink30 = Color(0x801A130C);
  static const ink10 = Color(0x1A1A130C);
  static const ink05 = Color(0x0D1A130C);
  static const hairline = Color(0x171A130C);
  static const amber = Color(0xFFF59E0B);

  static const readOnlyBannerBg = Color(0xFFFEF3C7);
  static const readOnlyBannerText = Color(0xFF92400E);

  static const trendingDot = Color(0xFFFF6B35);

  static const paper = Color(0xFFF9F5EE);
  static const card = Color(0xFFFFFFFF);
  static const paperWarm = Color(0xFFF9E8D2);
  static const paperDeeper = Color(0xFFF2DBC0);
  static const night = Color(0xFF141009);

  static const success = Color(0xFF1FA455);
  static const warn = Color(0xFFD98A0B);
  static const danger = Color(0xFFD5392B);
  static const info = Color(0xFF3B82F6);
  static const violet = Color(0xFFA855F7);
  static const teal = Color(0xFF14B8A6);

  static const tableMineBg = Color(0xFFFFF3EC);
  static const tableMineWashStart = Color(0xFFFFFAF6);
  static const tableMineWashEnd = Color(0xFFFFF2E9);
  static const tableMineBorder = Color(0x73E05D38);
  static const tableOtherBg = Color(0xFFE4EEFD);
  static const tableOtherText = Color(0xFF1D4FB8);
  static const tableDirtyBg = Color(0xFFFBF0D9);
  static const tableDirtyText = Color(0xFF8F5C05);
  static const tableReservedBg = Color(0xFFF0E7FB);
  static const tableReservedText = Color(0xFF6B32B0);
  static const tableFreeBg = Color(0xFFE4F6EC);
  static const tableFreeText = Color(0xFF0E7A3D);

  static const timerBadBg = Color(0xFFFBE4E1);
  static const timerBadText = Color(0xFFA82A1E);

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

  // ---- v2 semantic tokens (theme-aware; prefer these over AppColors) ----
  final Color paper; // scaffold / app background
  final Color paperHint; // subtle warm hint surface
  final Color elevated; // sheets, dialogs, popovers
  final Color hairline; // 1px borders
  final Color scrim; // modal barrier
  final Color terraSoft; // brand tint chip bg
  final Color onTerraSoft; // text on terraSoft
  final Color tableMineWashStart;
  final Color tableMineWashEnd;
  final Color tableMineBorder;
  final Color tableFreeText;
  final Color tableOtherText;
  final Color tableDirtyText;
  final Color tableReservedText;
  final Color successBg;
  final Color successText;
  final Color warnBg;
  final Color warnText;
  final Color dangerBg;
  final Color dangerText;
  final Color infoBg;
  final Color infoText;
  final Color timerOkBg;
  final Color timerOkText;
  final Color timerWarnBg;
  final Color timerWarnText;
  final Color timerBadBg;
  final Color timerBadText;
  final Color paidBg;
  final Color paidText; // history PAID pill
  final Color alertDeep;
  final Color onAlertDeep; // ready-to-serve banner
  final Color navBar;
  final Color navHairline; // bottom nav surface
  final Color selectedPill; // solid 'active' pill fill (white text on top)

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
    required this.paper,
    required this.paperHint,
    required this.elevated,
    required this.hairline,
    required this.scrim,
    required this.terraSoft,
    required this.onTerraSoft,
    required this.tableMineWashStart,
    required this.tableMineWashEnd,
    required this.tableMineBorder,
    required this.tableFreeText,
    required this.tableOtherText,
    required this.tableDirtyText,
    required this.tableReservedText,
    required this.successBg,
    required this.successText,
    required this.warnBg,
    required this.warnText,
    required this.dangerBg,
    required this.dangerText,
    required this.infoBg,
    required this.infoText,
    required this.timerOkBg,
    required this.timerOkText,
    required this.timerWarnBg,
    required this.timerWarnText,
    required this.timerBadBg,
    required this.timerBadText,
    required this.paidBg,
    required this.paidText,
    required this.alertDeep,
    required this.onAlertDeep,
    required this.navBar,
    required this.navHairline,
    required this.selectedPill,
  });

  bool get isDark => brightness == Brightness.dark;

  /// Both of these used to be two-layer, per-brightness drops — the dark one
  /// a 26px spread-inset black, the "mine" one a terra glow. They are the
  /// single neutral shadow and no shadow respectively now.
  List<BoxShadow> get cardShadow => AppShadows.flat;

  List<BoxShadow> get mineShadow => AppShadows.none;

  /// The wash behind a table you're serving is a solid fill, not a diagonal
  /// two-stop gradient. [tableMineWashStart] is the colour it settles on.
  Color get mineWash => tableMineWashStart;

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
    surface: AppColors.card,
    surfaceWarm: AppColors.paperWarm,
    counterPaper: AppColors.counterPaper,
    tableMineBg: AppColors.tableMineBg,
    tableOtherBg: AppColors.tableOtherBg,
    tableDirtyBg: AppColors.tableDirtyBg,
    tableReservedBg: AppColors.tableReservedBg,
    tableFreeBg: AppColors.tableFreeBg,
    readOnlyBannerBg: AppColors.readOnlyBannerBg,
    readOnlyBannerText: AppColors.readOnlyBannerText,
    paper: AppColors.paper,
    paperHint: AppColors.paperHint,
    elevated: AppColors.card,
    hairline: AppColors.hairline,
    scrim: AppColors.scrim,
    terraSoft: AppColors.terraSoft,
    onTerraSoft: AppColors.terraInk,
    tableMineWashStart: AppColors.tableMineWashStart,
    tableMineWashEnd: AppColors.tableMineWashEnd,
    tableMineBorder: AppColors.tableMineBorder,
    tableFreeText: AppColors.tableFreeText,
    tableOtherText: AppColors.tableOtherText,
    tableDirtyText: AppColors.tableDirtyText,
    tableReservedText: AppColors.tableReservedText,
    successBg: AppColors.tableFreeBg,
    successText: AppColors.tableFreeText,
    warnBg: AppColors.tableDirtyBg,
    warnText: AppColors.tableDirtyText,
    dangerBg: AppColors.timerBadBg,
    dangerText: AppColors.timerBadText,
    infoBg: AppColors.tableOtherBg,
    infoText: AppColors.tableOtherText,
    timerOkBg: AppColors.tableFreeBg,
    timerOkText: AppColors.tableFreeText,
    timerWarnBg: AppColors.tableDirtyBg,
    timerWarnText: AppColors.tableDirtyText,
    timerBadBg: AppColors.timerBadBg,
    timerBadText: AppColors.timerBadText,
    paidBg: Color(0xFFDDF3F0),
    paidText: Color(0xFF0B6E61),
    alertDeep: Color(0xFF0F5E30),
    onAlertDeep: Color(0xFFFFFFFF),
    navBar: Color(0xF0FFFFFF),
    navHairline: AppColors.hairline,
    selectedPill: AppColors.ink,
  );

  static const dark = AppPalette._(
    brightness: Brightness.dark,
    // Same tiers as light, same alphas. Against dark `paper` (#17110B) and
    // `surface` (#281E14): ink70 8.31/7.61, ink50 6.39/5.95, ink30 4.79/4.55
    // — all AA. Dark mode was already passing at ink50; ink30 was 2.48:1.
    ink: Color(0xFFF5EEE3),
    ink70: Color(0xB3F5EEE3),
    ink50: Color(0x99F5EEE3),
    ink30: Color(0x80F5EEE3),
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
    paper: Color(0xFF17110B),
    paperHint: Color(0xFF211812),
    elevated: Color(0xFF241B11),
    hairline: Color(0x24F5EEE3),
    scrim: Color(0x8A000000),
    terraSoft: Color(0xFF462313),
    onTerraSoft: Color(0xFFFFB793),
    tableMineWashStart: Color(0xFF3A2114),
    tableMineWashEnd: Color(0xFF2C1A10),
    tableMineBorder: Color(0x8CE05D38),
    tableFreeText: Color(0xFF7BE0A8),
    tableOtherText: Color(0xFF9CC3FF),
    tableDirtyText: Color(0xFFFFD37A),
    tableReservedText: Color(0xFFD7B8FF),
    successBg: Color(0xFF1C3024),
    successText: Color(0xFF7BE0A8),
    warnBg: Color(0xFF3A2C12),
    warnText: Color(0xFFFFD37A),
    dangerBg: Color(0xFF46201B),
    dangerText: Color(0xFFFF9C8F),
    infoBg: Color(0xFF1D2B3D),
    infoText: Color(0xFF9CC3FF),
    timerOkBg: Color(0xFF1C3024),
    timerOkText: Color(0xFF7BE0A8),
    timerWarnBg: Color(0xFF3A2C12),
    timerWarnText: Color(0xFFFFD37A),
    timerBadBg: Color(0xFF46201B),
    timerBadText: Color(0xFFFF9C8F),
    paidBg: Color(0xFF12332F),
    paidText: Color(0xFF6FD9C8),
    alertDeep: Color(0xFF0F5E30),
    onAlertDeep: Color(0xFFFFFFFF),
    navBar: Color(0xF01E1710),
    navHairline: Color(0x24F5EEE3),
    selectedPill: AppColors.terra600,
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
  static const md = Radius.circular(14);
  static const lg = Radius.circular(18);
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
    fontWeight: FontWeight.w600,
    fontSize: 36,
    height: 1.1,
    letterSpacing: -0.54,
  );

  static const TextStyle displayMd = TextStyle(
    fontFamily: cormorant,
    fontWeight: FontWeight.w500,
    fontSize: 28,
    height: 1.15,
    letterSpacing: -0.3,
  );

  static const TextStyle tableName = TextStyle(
    fontFamily: cormorant,
    fontWeight: FontWeight.w600,
    fontSize: 27,
    height: 1.1,
    letterSpacing: -0.405,
  );

  static const TextStyle sheetTitle = TextStyle(
    fontFamily: cormorant,
    fontWeight: FontWeight.w600,
    fontSize: 26,
    height: 1.15,
    letterSpacing: -0.39,
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

  /// Status badges: FREE / MINE / DIRTY / RESERVED / READY, and the floor
  /// filter chips.
  ///
  /// This was 9.5px, which put the most safety-critical, most-glanced-at
  /// information in the app at its smallest size — smaller than any body
  /// text. The waiter already knows the table is called T-01 (27px); what
  /// they are scanning the floor *for* is the state. 12px with the existing
  /// w700 and wide tracking still reads as a badge, not as body copy.
  static const TextStyle pill = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w700,
    fontSize: 12,
    height: 1.2,
    letterSpacing: 0.4,
  );

  static const TextStyle navLabel = TextStyle(
    fontFamily: inter,
    fontWeight: FontWeight.w700,
    fontSize: 9,
    height: 1.2,
    letterSpacing: 0.3,
  );

  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w500,
    fontSize: 14,
  );
}

class AppShadows {
  AppShadows._();

  /// No shadow at all. Surfaces that used to be separated by a coloured glow
  /// are separated by their fill and their hairline border instead.
  static const List<BoxShadow> none = <BoxShadow>[];

  /// The only shadow in the app: one soft, neutral drop, used where a surface
  /// genuinely floats over another (sheets, cards, the nav bar). Each
  /// [BoxShadow] is its own blurred draw, so there is never more than one.
  static const List<BoxShadow> flat = [
    BoxShadow(color: Color(0x1F140E08), blurRadius: 8, offset: Offset(0, 3)),
  ];

  // The stacked and coloured shadows below are retained as names so call
  // sites keep compiling, but they are all [flat] or [none] now. The multi-
  // layer drops (2/24px, 4/28/64px, 1/8/28/56px) and the terra glows are
  // gone — they were the "depth" half of the old glass look.
  static const List<BoxShadow> card = flat;
  static const List<BoxShadow> elevated = flat;
  static const List<BoxShadow> glass = flat;

  static const List<BoxShadow> terraWash = none;
  static const List<BoxShadow> terraGlow = none;
  static const List<BoxShadow> logoGlow = none;

  /// These four used to branch on [AppPerf.reduceEffects]. There is nothing
  /// left to branch to — the rich variants no longer exist — so they are now
  /// constant. They stay as functions because ~10 call sites pass a context.
  static List<BoxShadow> glassFor(BuildContext context) => flat;

  static List<BoxShadow> elevatedFor(BuildContext context) => flat;

  static List<BoxShadow> cardFor(BuildContext context) => flat;

  /// The table you're serving is marked by its fill and border, not by a
  /// coloured glow behind the tile.
  static List<BoxShadow> mineFor(BuildContext context) => none;
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

  static const EdgeInsets content =
      EdgeInsets.symmetric(horizontal: 20, vertical: 16);

  static const EdgeInsets input =
      EdgeInsets.symmetric(horizontal: 16, vertical: 12);
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

  static const EdgeInsets filterChip =
      EdgeInsets.symmetric(horizontal: 14, vertical: 12);

  static const EdgeInsets compactChip =
      EdgeInsets.symmetric(horizontal: 12, vertical: 10);

  static const EdgeInsets statusBadge =
      EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  static const EdgeInsets sectionLabel =
      EdgeInsets.symmetric(horizontal: 14, vertical: 8);
}

/// ============================================================
/// ADAPTIVE DESIGN — single source of truth for every screen.
/// Phone · tablet · desktop follow the same tokens, so layouts
/// scale without per-screen magic numbers.
/// ============================================================
class AppBreakpoints {
  AppBreakpoints._();

  /// Phone vs tablet. Below this is a handset in either orientation.
  static const double tablet = 600;

  /// Enough room for two panes — a side nav rail, an order rail, a
  /// master/detail split. A 10" tablet lands here in landscape and in the
  /// [tablet] bucket in portrait.
  static const double tabletWide = 920;
}

enum AppSizeClass { phone, tablet, tabletWide }

extension AdaptiveContext on BuildContext {
  double get _w => MediaQuery.sizeOf(this).width;

  AppSizeClass get sizeClass => _w >= AppBreakpoints.tabletWide
      ? AppSizeClass.tabletWide
      : _w >= AppBreakpoints.tablet
          ? AppSizeClass.tablet
          : AppSizeClass.phone;

  bool get isPhone => sizeClass == AppSizeClass.phone;
  bool get isTabletUp => _w >= AppBreakpoints.tablet;

  /// Whole-window signal — right for page-level decisions like content
  /// clamping. For a two-pane split use [AdaptiveConstraints.isTwoPane] on a
  /// local [LayoutBuilder] instead: inside a Row that has already given away
  /// width to a rail, the window width no longer describes the space left.
  bool get isTabletWide => _w >= AppBreakpoints.tabletWide;

  /// Pick a value per size class: `context.adaptive(phone: 16, tablet: 24)`.
  T adaptive<T>({required T phone, T? tablet}) => switch (sizeClass) {
        AppSizeClass.phone => phone,
        AppSizeClass.tablet || AppSizeClass.tabletWide => tablet ?? phone,
      };

  /// Grid tile sizing for the tables floor — wider screens get roomier
  /// tiles while the max-extent delegate keeps column count fluid.
  double get tableTileExtent => adaptive(phone: 200, tablet: 212);

  /// Space to leave at the bottom of a bottom sheet.
  ///
  /// Sheets shown with `isScrollControlled: true` get no automatic keyboard
  /// padding, so they have to account for it themselves. Whichever of the two
  /// insets is larger is the right answer, and they are never added: with the
  /// keyboard open its height already spans the gesture-bar area, so summing
  /// them double-counts; with it closed the keyboard inset is zero and only
  /// the safe area remains.
  double get sheetBottomInset => math.max(
        MediaQuery.viewInsetsOf(this).bottom,
        MediaQuery.viewPaddingOf(this).bottom,
      );

  /// A linear stand-in for the system font scale, for sizing math that has to
  /// grow with text. Android's curve flattens at the top end, so this is an
  /// upper bound rather than exact.
  double get effectiveTextScale =>
      (MediaQuery.textScalerOf(this).scale(100) / 100).clamp(1.0, 2.0);

  /// Honors performance mode and OS "reduce motion" — heavy ambient effects
  /// switch off.
  bool get reduceMotion => AppPerf.reduceEffects(this);
}

extension AdaptiveConstraints on BoxConstraints {
  /// Whether the space actually available here fits two panes. Measured from
  /// a local [LayoutBuilder] rather than the window, so a pane nested inside
  /// another split sees its own width.
  bool get isTwoPane => maxWidth >= AppBreakpoints.tabletWide;
}

/// Performance guardrails for low-end devices. Ambient effects consult
/// this before painting; interactions stay spring-driven everywhere.
class AppPerf {
  AppPerf._();

  /// True when heavy ambient effects should be skipped — either the operator
  /// asked for it, the device was detected as low-tier, or the OS wants
  /// reduced motion. Resolved by [PerfScope]; the [MediaQuery] fallback keeps
  /// widget tests that pump a subtree without a [PerfScope] ancestor working.
  static bool reduceEffects(BuildContext context) =>
      PerfInheritedScope.maybeOf(context)?.reduceEffects ??
      MediaQuery.of(context).disableAnimations;

  static PerfMode mode(BuildContext context) =>
      PerfInheritedScope.maybeOf(context)?.mode ?? PerfMode.auto;

  static PerfTier tier(BuildContext context) =>
      PerfInheritedScope.maybeOf(context)?.tier ?? PerfTier.capable;

  /// List prefetch window — enough to hide jank, small enough for RAM.
  static const double listCacheExtent = 500;

  /// Grid prefetch window for the tables floor.
  static const double gridCacheExtent = 400;

  /// Prefetch is a RAM trade. A constant window meant the device least able
  /// to hold offscreen rows kept exactly as many alive as a flagship.
  static double listCacheExtentFor(BuildContext context) =>
      tier(context) == PerfTier.low ? 220 : listCacheExtent;

  static double gridCacheExtentFor(BuildContext context) =>
      tier(context) == PerfTier.low ? 180 : gridCacheExtent;
}
