import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Palette {
  const _Palette({
    required this.ink,
    required this.muted,
    required this.subtle,
    required this.bg,
    required this.surface,
    required this.field,
    required this.line,
    required this.green,
    required this.greenDark,
    required this.greenSoft,
    required this.red,
    required this.orange,
    required this.blue,
  });

  final Color ink;
  final Color muted;
  final Color subtle;
  final Color bg;
  final Color surface;
  final Color field;
  final Color line;
  final Color green;
  final Color greenDark;
  final Color greenSoft;
  final Color red;
  final Color orange;
  final Color blue;
}

const _lightPalette = _Palette(
  ink: Color(0xFF0D1526),
  muted: Color(0xFF526481),
  subtle: Color(0xFF8B9AB3),
  bg: Color(0xFFF4F7FB),
  surface: Color(0xFFFFFFFF),
  field: Color(0xFFEDF1F7),
  line: Color(0xFFDCE3ED),
  green: Color(0xFF0FBC86),
  greenDark: Color(0xFF006A4C),
  greenSoft: Color(0xFFEAFBF5),
  red: Color(0xFFFF4347),
  orange: Color(0xFFFF7A1A),
  blue: Color(0xFF25AEF3),
);

const _darkPalette = _Palette(
  ink: Color(0xFFF0F3F8),
  muted: Color(0xFF93A0B5),
  subtle: Color(0xFF5C6A80),
  bg: Color(0xFF0A0E15),
  surface: Color(0xFF141A24),
  field: Color(0xFF1B2330),
  line: Color(0xFF262F3E),
  green: Color(0xFF13B685),
  greenDark: Color(0xFF0E9E73),
  greenSoft: Color(0xFF122A22),
  red: Color(0xFFFF5B60),
  orange: Color(0xFFFF9142),
  blue: Color(0xFF4CC2FF),
);

/// Global light/dark switch. `VColors.*` are getters over whichever palette
/// is current, so every screen that reads e.g. `VColors.bg` in its `build()`
/// picks up the new colors automatically on the next frame — no need to
/// thread a theme object through 13 screens individually.
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final instance = ThemeController._();

  static const _prefsKey = 'dark_mode';
  bool _dark = false;
  bool get isDark => _dark;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _dark = prefs.getBool(_prefsKey) ?? false;
    VColors._palette = _dark ? _darkPalette : _lightPalette;
    notifyListeners();
  }

  Future<void> toggle() async {
    _dark = !_dark;
    VColors._palette = _dark ? _darkPalette : _lightPalette;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, _dark);
  }
}

abstract final class VColors {
  static _Palette _palette = _lightPalette;

  static Color get ink => _palette.ink;
  static Color get muted => _palette.muted;
  static Color get subtle => _palette.subtle;
  static Color get bg => _palette.bg;
  static Color get surface => _palette.surface;
  static Color get field => _palette.field;
  static Color get line => _palette.line;
  static Color get green => _palette.green;
  static Color get greenDark => _palette.greenDark;
  static Color get greenSoft => _palette.greenSoft;
  static Color get red => _palette.red;
  static Color get orange => _palette.orange;
  static Color get blue => _palette.blue;
}

ThemeData buildTheme() {
  final dark = ThemeController.instance.isDark;
  final text = GoogleFonts.robotoTextTheme(
    dark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
  ).apply(
    bodyColor: VColors.ink,
    displayColor: VColors.ink,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: VColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: VColors.green,
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: VColors.green,
      surface: VColors.surface,
      error: VColors.red,
    ),
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w900,
        letterSpacing: -0.8,
      ),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
      bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
    ),
    dividerColor: VColors.line,
    cardTheme: CardThemeData(
      color: VColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: VColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: VColors.field,
      hintStyle: TextStyle(color: VColors.subtle),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: VColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: VColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: VColors.green, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: VColors.green,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: VColors.ink,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        side: BorderSide(color: dark ? VColors.line : const Color(0xFFC9D3E1)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: VColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    // The club's other (web-based) POS shows category/reason pills as plain
    // colored text on a filled background, with no leading checkmark icon --
    // Flutter's ChoiceChip draws one by default, which read as a mismatch
    // next to that reference.
    chipTheme: ChipThemeData(
      showCheckmark: false,
      selectedColor: VColors.green,
      backgroundColor: VColors.surface,
      side: BorderSide(color: VColors.line),
      labelStyle: TextStyle(fontWeight: FontWeight.w600, color: VColors.ink),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
