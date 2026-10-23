import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppColorScheme extends ThemeExtension<AppColorScheme> {
  final String name;
  final Brightness brightness;
  final Color scaffoldBackground;
  final Color panelBackground;
  final Color elevatedSurface;
  final Color borderColor;
  final Color accentColor;
  final Color secondaryAccent;
  final Color primaryText;
  final Color mutedText;
  final String matchingTerminalTheme;

  const AppColorScheme({
    required this.name,
    required this.brightness,
    required this.scaffoldBackground,
    required this.panelBackground,
    required this.elevatedSurface,
    required this.borderColor,
    required this.accentColor,
    required this.secondaryAccent,
    required this.primaryText,
    required this.mutedText,
    required this.matchingTerminalTheme,
  });

  bool get isDark => brightness == Brightness.dark;

  ThemeData toThemeData() {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: accentColor,
      brightness: brightness,
      primary: accentColor,
      secondary: secondaryAccent,
      surface: panelBackground,
    );

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: baseScheme.copyWith(
        primary: accentColor,
        secondary: secondaryAccent,
        surface: panelBackground,
        surfaceContainerHighest: elevatedSurface,
      ),
      scaffoldBackgroundColor: scaffoldBackground,
      dividerColor: borderColor,
      appBarTheme: AppBarTheme(
        backgroundColor: panelBackground,
        foregroundColor: primaryText,
        elevation: 0,
        iconTheme: IconThemeData(color: primaryText),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panelBackground,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: elevatedSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: borderColor),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor.withValues(alpha: isDark ? 0.18 : 0.14),
          foregroundColor: isDark ? accentColor : primaryText,
          side: BorderSide(color: accentColor.withValues(alpha: 0.45)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryText,
          side: BorderSide(color: borderColor),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentColor,
        ),
      ),
      extensions: [this],
    );
  }

  static AppColorScheme of(BuildContext context) {
    return Theme.of(context).extension<AppColorScheme>() ??
        AppColorSchemes.mjolnirAmber;
  }

  @override
  AppColorScheme copyWith({
    String? name,
    Brightness? brightness,
    Color? scaffoldBackground,
    Color? panelBackground,
    Color? elevatedSurface,
    Color? borderColor,
    Color? accentColor,
    Color? secondaryAccent,
    Color? primaryText,
    Color? mutedText,
    String? matchingTerminalTheme,
  }) {
    return AppColorScheme(
      name: name ?? this.name,
      brightness: brightness ?? this.brightness,
      scaffoldBackground: scaffoldBackground ?? this.scaffoldBackground,
      panelBackground: panelBackground ?? this.panelBackground,
      elevatedSurface: elevatedSurface ?? this.elevatedSurface,
      borderColor: borderColor ?? this.borderColor,
      accentColor: accentColor ?? this.accentColor,
      secondaryAccent: secondaryAccent ?? this.secondaryAccent,
      primaryText: primaryText ?? this.primaryText,
      mutedText: mutedText ?? this.mutedText,
      matchingTerminalTheme:
          matchingTerminalTheme ?? this.matchingTerminalTheme,
    );
  }

  @override
  AppColorScheme lerp(ThemeExtension<AppColorScheme>? other, double t) {
    if (other is! AppColorScheme) return this;
    return AppColorScheme(
      name: t < 0.5 ? name : other.name,
      brightness: t < 0.5 ? brightness : other.brightness,
      scaffoldBackground:
          Color.lerp(scaffoldBackground, other.scaffoldBackground, t)!,
      panelBackground: Color.lerp(panelBackground, other.panelBackground, t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      accentColor: Color.lerp(accentColor, other.accentColor, t)!,
      secondaryAccent: Color.lerp(secondaryAccent, other.secondaryAccent, t)!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      matchingTerminalTheme:
          t < 0.5 ? matchingTerminalTheme : other.matchingTerminalTheme,
    );
  }
}

class AppColorSchemes {
  static const AppColorScheme mjolnirAmber = AppColorScheme(
    name: 'Mjölnir Amber',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF1E1E1E),
    panelBackground: Color(0xFF252526),
    elevatedSurface: Color(0xFF2D2D2D),
    borderColor: Color(0xFF383838),
    accentColor: Colors.amberAccent,
    secondaryAccent: Colors.orangeAccent,
    primaryText: Color(0xFFFFFFFF),
    mutedText: Color(0xFF9E9E9E),
    matchingTerminalTheme: 'Default Dark',
  );

  static const AppColorScheme dracula = AppColorScheme(
    name: 'Dracula',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF21222C),
    panelBackground: Color(0xFF282A36),
    elevatedSurface: Color(0xFF343746),
    borderColor: Color(0xFF44475A),
    accentColor: Color(0xFFBD93F9),
    secondaryAccent: Color(0xFFFF79C6),
    primaryText: Color(0xFFF8F8F2),
    mutedText: Color(0xFF92A1C8),
    matchingTerminalTheme: 'Dracula',
  );

  static const AppColorScheme tokyoNight = AppColorScheme(
    name: 'Tokyo Night',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF16161E),
    panelBackground: Color(0xFF1A1B26),
    elevatedSurface: Color(0xFF24283B),
    borderColor: Color(0xFF2F3549),
    accentColor: Color(0xFF7AA2F7),
    secondaryAccent: Color(0xFFBB9AF7),
    primaryText: Color(0xFFC0CAF5),
    mutedText: Color(0xFF787C99),
    matchingTerminalTheme: 'Tokyo Night',
  );

  static const AppColorScheme nord = AppColorScheme(
    name: 'Nord',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF242933),
    panelBackground: Color(0xFF2E3440),
    elevatedSurface: Color(0xFF3B4252),
    borderColor: Color(0xFF4C566A),
    accentColor: Color(0xFF88C0D0),
    secondaryAccent: Color(0xFF81A1C1),
    primaryText: Color(0xFFECEFF4),
    mutedText: Color(0xFF9AA5B8),
    matchingTerminalTheme: 'Nord',
  );

  static const AppColorScheme catppuccinMocha = AppColorScheme(
    name: 'Catppuccin Mocha',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF181825),
    panelBackground: Color(0xFF1E1E2E),
    elevatedSurface: Color(0xFF313244),
    borderColor: Color(0xFF45475A),
    accentColor: Color(0xFFCBA6F7),
    secondaryAccent: Color(0xFF89B4FA),
    primaryText: Color(0xFFCDD6F4),
    mutedText: Color(0xFF9399B2),
    matchingTerminalTheme: 'Dracula',
  );

  static const AppColorScheme oneDark = AppColorScheme(
    name: 'One Dark',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF21252B),
    panelBackground: Color(0xFF282C34),
    elevatedSurface: Color(0xFF323842),
    borderColor: Color(0xFF3E4451),
    accentColor: Color(0xFF61AFEF),
    secondaryAccent: Color(0xFFC678DD),
    primaryText: Color(0xFFABB2BF),
    mutedText: Color(0xFF7F848E),
    matchingTerminalTheme: 'One Dark',
  );

  static const AppColorScheme gruvboxDark = AppColorScheme(
    name: 'Gruvbox Dark',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF1D2021),
    panelBackground: Color(0xFF282828),
    elevatedSurface: Color(0xFF32302F),
    borderColor: Color(0xFF504945),
    accentColor: Color(0xFFFABD2F),
    secondaryAccent: Color(0xFFFE8019),
    primaryText: Color(0xFFEBDBB2),
    mutedText: Color(0xFFA89984),
    matchingTerminalTheme: 'Gruvbox Dark',
  );

  static const AppColorScheme githubDark = AppColorScheme(
    name: 'GitHub Dark',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF0D1117),
    panelBackground: Color(0xFF161B22),
    elevatedSurface: Color(0xFF21262D),
    borderColor: Color(0xFF30363D),
    accentColor: Color(0xFF58A6FF),
    secondaryAccent: Color(0xFF3FB950),
    primaryText: Color(0xFFF0F6FC),
    mutedText: Color(0xFF8B949E),
    matchingTerminalTheme: 'GitHub Dark',
  );

  static const AppColorScheme synthwave84 = AppColorScheme(
    name: 'Synthwave \'84',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF1E1A2B),
    panelBackground: Color(0xFF262335),
    elevatedSurface: Color(0xFF34294F),
    borderColor: Color(0xFF495495),
    accentColor: Color(0xFFFF7EDB),
    secondaryAccent: Color(0xFF03EDF9),
    primaryText: Color(0xFFFFFFFF),
    mutedText: Color(0xFFB6B1C8),
    matchingTerminalTheme: 'Synthwave \'84',
  );

  static const AppColorScheme solarizedDark = AppColorScheme(
    name: 'Solarized Dark',
    brightness: Brightness.dark,
    scaffoldBackground: Color(0xFF00212B),
    panelBackground: Color(0xFF002B36),
    elevatedSurface: Color(0xFF073642),
    borderColor: Color(0xFF2E545E),
    accentColor: Color(0xFF2AA198),
    secondaryAccent: Color(0xFF268BD2),
    primaryText: Color(0xFFFDF6E3),
    mutedText: Color(0xFF839496),
    matchingTerminalTheme: 'Solarized Dark',
  );

  static const AppColorScheme solarizedLight = AppColorScheme(
    name: 'Solarized Light',
    brightness: Brightness.light,
    scaffoldBackground: Color(0xFFFDF6E3),
    panelBackground: Color(0xFFEEE8D5),
    elevatedSurface: Color(0xFFE4DEC8),
    borderColor: Color(0xFFC9C2AF),
    accentColor: Color(0xFF268BD2),
    secondaryAccent: Color(0xFF2AA198),
    primaryText: Color(0xFF073642),
    mutedText: Color(0xFF586E75),
    matchingTerminalTheme: 'Solarized Light',
  );

  static const Map<String, AppColorScheme> all = {
    'Mjölnir Amber': mjolnirAmber,
    'Dracula': dracula,
    'Tokyo Night': tokyoNight,
    'Nord': nord,
    'Catppuccin Mocha': catppuccinMocha,
    'One Dark': oneDark,
    'Gruvbox Dark': gruvboxDark,
    'GitHub Dark': githubDark,
    'Synthwave \'84': synthwave84,
    'Solarized Dark': solarizedDark,
    'Solarized Light': solarizedLight,
  };

  static AppColorScheme byName(String? name) {
    if (name == null) return mjolnirAmber;
    return all[name] ?? mjolnirAmber;
  }

  static Future<File> _getPrefsFile() async {
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'Mjolnir'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, 'ui_preferences.json'));
  }

  static Future<String> loadSavedSchemeName() async {
    try {
      final file = await _getPrefsFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final json = jsonDecode(raw) as Map<String, dynamic>;
          final scheme = json['app_color_scheme'] as String?;
          if (scheme != null && all.containsKey(scheme)) {
            return scheme;
          }
        }
      }
    } catch (_) {}
    return mjolnirAmber.name;
  }

  static Future<void> saveSchemeName(String schemeName) async {
    try {
      final file = await _getPrefsFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'app_color_scheme': schemeName,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}
