import 'package:flutter/material.dart';

import '../../native/native_colors.dart';

/// The app's main colours, mapped 1:1 onto the native Android @color values (NC):
/// bg = bg_screen, card = surface, ink = text_primary, muted = text_secondary, line = divider,
/// blue = primary, blueSoft = choice_selected_bg, gold = crown, danger = danger.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.card,
    required this.ink,
    required this.muted,
    required this.line,
    required this.blue,
    required this.blueSoft,
    required this.gold,
    required this.danger,
    required this.shadow,
  });

  final Color bg;
  final Color card;
  final Color ink;
  final Color muted;
  final Color line;
  final Color blue;
  final Color blueSoft;
  final Color gold;
  final Color danger;
  final Color shadow;

  static const light = AppPalette(
    bg: Color(0xFFF6F7FD),
    card: Colors.white,
    ink: Color(0xFF1B1F2A),
    muted: Color(0xFF8E949E),
    line: Color(0xFFF0F2F8),
    blue: Color(0xFF0A5FD9),
    blueSoft: Color(0xFFEEF4FF),
    gold: Color(0xFFFFB300),
    danger: Color(0xFFE53935),
    shadow: Color(0x140F172A),
  );

  static const dark = AppPalette(
    bg: Color(0xFF101216),
    card: Color(0xFF17191E),
    ink: Color(0xFFE6E8EC),
    muted: Color(0xFF9AA0AA),
    line: Color(0xFF2A2E36),
    blue: Color(0xFF0A5FD9),
    blueSoft: Color(0xFF1B2A42),
    gold: Color(0xFFFFB300),
    danger: Color(0xFFE53935),
    shadow: Color(0x66000000),
  );

  static AppPalette of(BuildContext context) {
    return Theme.of(context).extension<AppPalette>() ?? light;
  }

  @override
  AppPalette copyWith({
    Color? bg,
    Color? card,
    Color? ink,
    Color? muted,
    Color? line,
    Color? blue,
    Color? blueSoft,
    Color? gold,
    Color? danger,
    Color? shadow,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      card: card ?? this.card,
      ink: ink ?? this.ink,
      muted: muted ?? this.muted,
      line: line ?? this.line,
      blue: blue ?? this.blue,
      blueSoft: blueSoft ?? this.blueSoft,
      gold: gold ?? this.gold,
      danger: danger ?? this.danger,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      line: Color.lerp(line, other.line, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      blueSoft: Color.lerp(blueSoft, other.blueSoft, t)!,
      gold: Color.lerp(gold, other.gold, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

class DocColors {
  // the Android app's type_* colours
  static const pdf = Color(0xFFD10000);
  static const word = Color(0xFF1560D6);
  static const excel = Color(0xFF008A3B);
  static const ppt = Color(0xFFF26201);
  static const txt = Color(0xFF5F6B90);
  static const image = Color(0xFFFDA800);
  static const folder = Color(0xFF1A6FE0);
  static const all = Color(0xFF1A6FE0);
}

/// Global theme matching the native Theme.DocReader (res/values/themes.xml, MaterialComponents
/// DayNight): window = @color/bg_screen, sheets = @color/surface with 20 dp top corners
/// (BottomSheetRounded), dialogs = surface (MaterialAlertDialog), PillButton buttons, controls
/// (radio / checkbox / progress / cursor) tinted @color/primary, @color/divider lines.
ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final palette = dark ? AppPalette.dark : AppPalette.light;
  final c = dark ? NC.dark : NC.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: c.primary,
    brightness: brightness,
  ).copyWith(
    primary: c.primary,
    onPrimary: c.white,
    primaryContainer: c.primaryLight,
    onPrimaryContainer: c.textPrimary,
    secondary: c.primary,
    onSecondary: c.white,
    secondaryContainer: c.choiceSelectedBg,
    onSecondaryContainer: c.textPrimary,
    tertiary: c.primary,
    surface: c.surface,
    onSurface: c.textPrimary,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.surfaceVariant,
    outline: c.textHint,
    outlineVariant: c.divider,
    error: c.danger,
    onError: c.white,
    shadow: Colors.black,
    scrim: c.scrim,
  );
  const pillShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24)));
  const pillText = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
  WidgetStateProperty<Color?> checked(Color on, Color off) =>
      WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? on : off);
  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bgScreen,
    canvasColor: c.bgScreen,
    cardColor: c.surface,
    splashFactory: InkRipple.splashFactory,
    highlightColor: Colors.transparent,
    // ?attr/colorControlHighlight of MaterialComponents
    splashColor: dark ? const Color(0x33FFFFFF) : const Color(0x1F000000),
    hoverColor: dark ? const Color(0x14FFFFFF) : const Color(0x0A000000),
    dividerColor: c.divider,
    hintColor: c.textHint,
    disabledColor: c.textHint,
    iconTheme: IconThemeData(color: c.iconMain, size: 24),
    primaryIconTheme: IconThemeData(color: c.white),
    extensions: [palette],
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: c.bgScreen,
      surfaceTintColor: Colors.transparent,
      foregroundColor: c.textPrimary,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.textPrimary),
    ),
    // native messages are Android toasts / TopPill: dark rounded, white 14 sp text
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xE6283040),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
      actionTextColor: const Color(0xFF8AB4F8),
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.fromLTRB(24, 0, 24, 64),
    ),
    // MaterialAlertDialogBuilder (Theme.DocReader.Dialog): surface, 4 dp corners, 0.32 dim
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      barrierColor: const Color(0x52000000),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: c.textPrimary),
      contentTextStyle: TextStyle(fontSize: 16, height: 1.4, color: c.textSecondary),
    ),
    // Theme.DocReader.BottomSheet → BottomSheetRounded: surface, 20 dp top corners
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      modalBackgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      modalElevation: 8,
      modalBarrierColor: const Color(0x52000000),
      showDragHandle: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      clipBehavior: Clip.antiAlias,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: TextStyle(fontSize: 15, color: c.textPrimary),
    ),
    // fab_blue circle, white ic_add, 6 dp elevation (fragment_home.xml fabCreate)
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.fabBlue,
      foregroundColor: c.white,
      elevation: 6,
      focusElevation: 6,
      hoverElevation: 8,
      highlightElevation: 12,
      shape: const CircleBorder(),
    ),
    // PillButton: primary, white 16 sp bold, 24 dp corners, 44 dp high, no elevation
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.white,
        disabledBackgroundColor: c.primary.withValues(alpha: 0.4),
        disabledForegroundColor: c.white.withValues(alpha: 0.8),
        minimumSize: const Size(64, 44),
        elevation: 0,
        shape: pillShape,
        textStyle: pillText,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.white,
        minimumSize: const Size(64, 44),
        elevation: 0,
        shape: pillShape,
        textStyle: pillText,
      ),
    ),
    // bg_outline_btn: primary 1.4 dp outline, 22 dp corners
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.primary,
        minimumSize: const Size(64, 44),
        side: BorderSide(color: c.primary, width: 1.4),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
        textStyle: pillText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    // radio_tint / checkbox_tint: primary when checked, radio_off / #B8BEC8 otherwise
    radioTheme: RadioThemeData(fillColor: checked(c.primary, c.radioOff)),
    checkboxTheme: CheckboxThemeData(
      fillColor: checked(c.primary, Colors.transparent),
      checkColor: WidgetStatePropertyAll(c.white),
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(color: states.contains(WidgetState.selected) ? c.primary : const Color(0xFFB8BEC8), width: 2),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: checked(c.white, c.white),
      trackColor: checked(c.primary, c.textHint),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.primary,
      inactiveTrackColor: c.progressTrack,
      thumbColor: c.primary,
      overlayColor: c.primary.withValues(alpha: 0.12),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.primary,
      linearTrackColor: c.progressTrack,
      circularTrackColor: Colors.transparent,
      refreshBackgroundColor: c.surface,
    ),
    dividerTheme: DividerThemeData(color: c.divider, thickness: 1, space: 1),
    tabBarTheme: TabBarThemeData(
      labelColor: c.primary,
      unselectedLabelColor: c.textSecondary,
      indicatorColor: c.primary,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    listTileTheme: ListTileThemeData(iconColor: c.iconMain, textColor: c.textPrimary),
    // EditText: primary cursor and handles (hints use hintColor = text_hint)
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.primary,
      selectionColor: c.primary.withValues(alpha: 0.3),
      selectionHandleColor: c.primary,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: const Color(0xE6283040), borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 13),
    ),
  );
  return theme.copyWith(textTheme: theme.textTheme.apply(bodyColor: c.textPrimary, displayColor: c.textPrimary));
}
