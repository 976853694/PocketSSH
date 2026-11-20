import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ssh/core/app_palette.dart';

double _contrast(Color first, Color second) {
  final high = first.computeLuminance().clamp(0.0, 1.0);
  final low = second.computeLuminance().clamp(0.0, 1.0);
  final lighter = high > low ? high : low;
  final darker = high > low ? low : high;
  return (lighter + .05) / (darker + .05);
}

void main() {
  test(
    'light palette uses a cool paper surface and readable blue-cyan accent',
    () {
      final colors = AppPalette.scheme(Brightness.light);
      expect(colors.surface, AppPalette.lightSurface);
      expect(colors.primary, AppPalette.lightPrimary);
      expect(colors.onSurface, isNot(colors.surface));
      expect(colors.error, AppPalette.lightError);
      expect(_contrast(colors.primary, colors.surface), greaterThan(4.5));
      expect(_contrast(colors.onSurface, colors.surface), greaterThan(7));
    },
  );

  test('dark palette uses a navy surface and luminous cyan accent', () {
    final colors = AppPalette.scheme(Brightness.dark);
    expect(colors.surface, AppPalette.darkSurface);
    expect(colors.primary, AppPalette.darkPrimary);
    expect(colors.onSurface, isNot(colors.surface));
    expect(colors.error, AppPalette.darkError);
    expect(_contrast(colors.primary, colors.surface), greaterThan(4.5));
    expect(_contrast(colors.onSurface, colors.surface), greaterThan(7));
  });
}
