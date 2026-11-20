import 'package:flutter/material.dart';

abstract final class AppPalette {
  static const accent = Color(0xff42c3d5);
  static const lightPrimary = Color(0xff087d91);
  static const darkPrimary = Color(0xff62d4e3);
  static const lightSurface = Color(0xfff5f8fa);
  static const darkSurface = Color(0xff0b141c);
  static const darkOnPrimary = Color(0xff06232a);
  static const darkOnSecondary = Color(0xff14232d);
  static const darkOnTertiary = Color(0xff182344);
  static const darkOnError = Color(0xff39000e);
  static const lightPrimaryContainer = Color(0xffc9eef2);
  static const darkPrimaryContainer = Color(0xff173b47);
  static const lightOnPrimaryContainer = Color(0xff10363e);
  static const darkOnPrimaryContainer = Color(0xffc8f5f8);
  static const lightSecondary = Color(0xff526e7d);
  static const darkSecondary = Color(0xffa3c0d0);
  static const lightSecondaryContainer = Color(0xffdce8ee);
  static const darkSecondaryContainer = Color(0xff263b49);
  static const lightOnSecondaryContainer = Color(0xff1a303a);
  static const darkOnSecondaryContainer = Color(0xffdbeaf0);
  static const lightTertiary = Color(0xff4b5e9b);
  static const darkTertiary = Color(0xffa7bbff);
  static const lightTertiaryContainer = Color(0xffe0e6ff);
  static const darkTertiaryContainer = Color(0xff303c65);
  static const lightOnTertiaryContainer = Color(0xff202f62);
  static const darkOnTertiaryContainer = Color(0xffe1e7ff);
  static const lightError = Color(0xffb4233c);
  static const darkError = Color(0xffff8198);
  static const lightErrorContainer = Color(0xffffd9df);
  static const darkErrorContainer = Color(0xff5a1b2b);
  static const lightOnErrorContainer = Color(0xff5e1021);
  static const darkOnErrorContainer = Color(0xffffdce2);
  static const lightOnSurface = Color(0xff172631);
  static const darkOnSurface = Color(0xffe7f0f5);
  static const lightOnSurfaceVariant = Color(0xff526572);
  static const darkOnSurfaceVariant = Color(0xffa5b7c3);
  static const lightOutline = Color(0xff7e929e);
  static const darkOutline = Color(0xff637987);
  static const lightOutlineVariant = Color(0xffd6e1e7);
  static const darkOutlineVariant = Color(0xff2b3c48);
  static const lightSurfaceContainerLowest = Color(0xffffffff);
  static const darkSurfaceContainerLowest = Color(0xff070d12);
  static const lightSurfaceContainerLow = Color(0xffedf3f6);
  static const darkSurfaceContainerLow = Color(0xff111d26);
  static const lightSurfaceContainer = Color(0xffe7eef2);
  static const darkSurfaceContainer = Color(0xff17242e);
  static const lightSurfaceContainerHigh = Color(0xffe0e9ee);
  static const darkSurfaceContainerHigh = Color(0xff202f3a);
  static const lightSurfaceContainerHighest = Color(0xffd9e4e9);
  static const darkSurfaceContainerHighest = Color(0xff2a3b47);
  static const heroTop = Color(0xff102535);
  static const heroMiddle = Color(0xff143d52);
  static const heroBottom = Color(0xff125566);
  static const heroHighlight = Color(0xffaeeaf2);
  static const heroText = Color(0xffc9f3f5);
  static const heroButton = Color(0xffd9f5f8);
  static const heroButtonText = Color(0xff123441);

  static const terminalDarkBackground = Color(0xff08121a);
  static const terminalDarkForeground = Color(0xffdce9ef);
  static const terminalDarkBlack = Color(0xff08121a);
  static const terminalDarkWhite = Color(0xfff6fbfd);
  static const terminalLightBackground = Color(0xfff5f8fa);
  static const terminalLightForeground = Color(0xff172631);
  static const terminalLightBlack = Color(0xff20303c);
  static const terminalLightWhite = Color(0xff111a20);

  static const terminalRed = Color(0xffd86f82);
  static const terminalGreen = Color(0xff47b995);
  static const terminalYellow = Color(0xffd8ae60);
  static const terminalBlue = Color(0xff5d9ecf);
  static const terminalMagenta = Color(0xffa98bd0);
  static const terminalCyan = Color(0xff42aebb);
  static const terminalBrightRed = Color(0xfff18b9b);
  static const terminalBrightGreen = Color(0xff72d8ad);
  static const terminalBrightYellow = Color(0xfff0cf7f);
  static const terminalBrightBlue = Color(0xff8dc4ec);
  static const terminalBrightMagenta = Color(0xffc4a9ed);
  static const terminalBrightCyan = Color(0xff77dbe4);
  static const terminalBrightBlack = Color(0xff758995);
  static const terminalSelection = Color(0xff54c9da);
  static const terminalSearch = Color(0xffe7c96e);
  static const terminalSearchCurrent = Color(0xff53d6bd);

  static ColorScheme scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: dark ? darkSurface : lightSurface,
    ).copyWith(
      primary: dark ? darkPrimary : lightPrimary,
      onPrimary: dark ? darkOnPrimary : Colors.white,
      primaryContainer: dark ? darkPrimaryContainer : lightPrimaryContainer,
      onPrimaryContainer: dark
          ? darkOnPrimaryContainer
          : lightOnPrimaryContainer,
      secondary: dark ? darkSecondary : lightSecondary,
      onSecondary: dark ? darkOnSecondary : Colors.white,
      secondaryContainer: dark
          ? darkSecondaryContainer
          : lightSecondaryContainer,
      onSecondaryContainer: dark
          ? darkOnSecondaryContainer
          : lightOnSecondaryContainer,
      tertiary: dark ? darkTertiary : lightTertiary,
      onTertiary: dark ? darkOnTertiary : Colors.white,
      tertiaryContainer: dark ? darkTertiaryContainer : lightTertiaryContainer,
      onTertiaryContainer: dark
          ? darkOnTertiaryContainer
          : lightOnTertiaryContainer,
      error: dark ? darkError : lightError,
      onError: dark ? darkOnError : Colors.white,
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
