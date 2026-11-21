import 'package:flutter/material.dart';

abstract final class AppPalette {
  static const accent = Color(0xffd45636);
  static const lightPrimary = Color(0xffa43f28);
  static const darkPrimary = Color(0xffff9477);
  static const lightSurface = Color(0xfff3f0e8);
  static const darkSurface = Color(0xff111513);
  static const darkOnPrimary = Color(0xff311107);
  static const lightPrimaryContainer = Color(0xfff2ddd4);
  static const darkPrimaryContainer = Color(0xff47271f);
  static const lightOnPrimaryContainer = Color(0xff452016);
  static const darkOnPrimaryContainer = Color(0xffffddd2);
  static const lightSecondary = Color(0xff57614c);
  static const darkSecondary = Color(0xffbdc7a9);
  static const lightSecondaryContainer = Color(0xffe1e6d6);
  static const darkSecondaryContainer = Color(0xff343c2c);
  static const lightOnSecondaryContainer = Color(0xff272e20);
  static const darkOnSecondaryContainer = Color(0xffe0e7d3);
  static const lightTertiary = Color(0xff526b70);
  static const darkTertiary = Color(0xffaac9ca);
  static const lightTertiaryContainer = Color(0xffdce9e7);
  static const darkTertiaryContainer = Color(0xff2c4142);
  static const lightOnTertiaryContainer = Color(0xff1b3031);
  static const darkOnTertiaryContainer = Color(0xffd5e5e3);
  static const lightError = Color(0xffb42332);
  static const darkError = Color(0xffff897f);
  static const lightErrorContainer = Color(0xfffbdadd);
  static const darkErrorContainer = Color(0xff5a2025);
  static const lightOnErrorContainer = Color(0xff54141d);
  static const darkOnErrorContainer = Color(0xffffdadd);
  static const lightOnSurface = Color(0xff20251f);
  static const darkOnSurface = Color(0xffe9e7dd);
  static const lightOnSurfaceVariant = Color(0xff66675f);
  static const darkOnSurfaceVariant = Color(0xffb6b4a9);
  static const lightOutline = Color(0xff89877d);
  static const darkOutline = Color(0xff89877d);
  static const lightOutlineVariant = Color(0xffd8d4c8);
  static const darkOutlineVariant = Color(0xff383b35);
  static const lightSurfaceContainerLowest = Color(0xfffffdf8);
  static const darkSurfaceContainerLowest = Color(0xff0b0e0c);
  static const lightSurfaceContainerLow = Color(0xffeeebe2);
  static const darkSurfaceContainerLow = Color(0xff191d19);
  static const lightSurfaceContainer = Color(0xffe9e6dc);
  static const darkSurfaceContainer = Color(0xff20241f);
  static const lightSurfaceContainerHigh = Color(0xffe2dfd5);
  static const darkSurfaceContainerHigh = Color(0xff292d27);
  static const lightSurfaceContainerHighest = Color(0xffdcd8ce);
  static const darkSurfaceContainerHighest = Color(0xff333730);

  static const ink = Color(0xff1b211d);
  static const inkSoft = Color(0xff2a322d);
  static const paper = Color(0xfff3f0e8);
  static const paperBright = Color(0xfffffdf8);
  static const rule = Color(0xffd8d4c8);
  static const accentSoft = Color(0xfff2ddd4);
  static const success = Color(0xff3f7958);
  static const warning = Color(0xffa87428);

  static const terminalDarkBackground = Color(0xff101512);
  static const terminalDarkForeground = Color(0xffe9e7dd);
  static const terminalDarkBlack = Color(0xff101512);
  static const terminalDarkWhite = Color(0xfffaf8ef);
  static const terminalLightBackground = Color(0xfff5f2ea);
  static const terminalLightForeground = Color(0xff20251f);
  static const terminalLightBlack = Color(0xff292d27);
  static const terminalLightWhite = Color(0xff141814);

  static const terminalRed = Color(0xffc55243);
  static const terminalGreen = Color(0xff65906c);
  static const terminalYellow = Color(0xffbb8a3d);
  static const terminalBlue = Color(0xff718ca5);
  static const terminalMagenta = Color(0xffa17989);
  static const terminalCyan = Color(0xff648c89);
  static const terminalBrightRed = Color(0xffe27a69);
  static const terminalBrightGreen = Color(0xff89b58c);
  static const terminalBrightYellow = Color(0xffddba70);
  static const terminalBrightBlue = Color(0xff99b6ce);
  static const terminalBrightMagenta = Color(0xffc39bae);
  static const terminalBrightCyan = Color(0xff88b9b4);
  static const terminalBrightBlack = Color(0xff888980);
  static const terminalSelection = Color(0xffd45636);
  static const terminalSearch = Color(0xfff0ca7b);
  static const terminalSearchCurrent = Color(0xff8db89b);

  static final _lightScheme = _createScheme(Brightness.light);
  static final _darkScheme = _createScheme(Brightness.dark);

  static ColorScheme scheme(Brightness brightness) =>
      brightness == Brightness.dark ? _darkScheme : _lightScheme;

  static ColorScheme _createScheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme(
      brightness: brightness,
      surface: dark ? darkSurface : lightSurface,
      surfaceTint: dark ? darkPrimary : lightPrimary,
      inverseSurface: dark ? lightOnSurface : darkOnSurface,
      onInverseSurface: dark ? lightSurface : darkSurface,
      inversePrimary: dark ? lightPrimary : darkPrimary,
      primary: dark ? darkPrimary : lightPrimary,
      onPrimary: dark ? darkOnPrimary : Colors.white,
      primaryContainer: dark ? darkPrimaryContainer : lightPrimaryContainer,
      onPrimaryContainer: dark
          ? darkOnPrimaryContainer
          : lightOnPrimaryContainer,
      secondary: dark ? darkSecondary : lightSecondary,
      onSecondary: dark ? const Color(0xff20241b) : Colors.white,
      secondaryContainer: dark
          ? darkSecondaryContainer
          : lightSecondaryContainer,
      onSecondaryContainer: dark
          ? darkOnSecondaryContainer
          : lightOnSecondaryContainer,
      tertiary: dark ? darkTertiary : lightTertiary,
      onTertiary: dark ? const Color(0xff162021) : Colors.white,
      tertiaryContainer: dark ? darkTertiaryContainer : lightTertiaryContainer,
      onTertiaryContainer: dark
          ? darkOnTertiaryContainer
          : lightOnTertiaryContainer,
      error: dark ? darkError : lightError,
      onError: dark ? const Color(0xff370b0d) : Colors.white,
      errorContainer: dark ? darkErrorContainer : lightErrorContainer,
      onErrorContainer: dark ? darkOnErrorContainer : lightOnErrorContainer,
      onSurface: dark ? darkOnSurface : lightOnSurface,
      onSurfaceVariant: dark ? darkOnSurfaceVariant : lightOnSurfaceVariant,
      outline: dark ? darkOutline : lightOutline,
      outlineVariant: dark ? darkOutlineVariant : lightOutlineVariant,
      surfaceContainerLowest: dark
          ? darkSurfaceContainerLowest
          : lightSurfaceContainerLowest,
      surfaceContainerLow: dark
          ? darkSurfaceContainerLow
          : lightSurfaceContainerLow,
      surfaceContainer: dark ? darkSurfaceContainer : lightSurfaceContainer,
      surfaceContainerHigh: dark
          ? darkSurfaceContainerHigh
          : lightSurfaceContainerHigh,
      surfaceContainerHighest: dark
          ? darkSurfaceContainerHighest
          : lightSurfaceContainerHighest,
    );
  }
}
