import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/app_store.dart';

class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = store.glassStyle == 'solid';
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: muted ? .04 : .13),
            colors.surface,
            colors.tertiary.withValues(alpha: muted ? .02 : .08),
          ],
          stops: const [0, .52, 1],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.store,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 22,
  });

  final AppStore store;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final liquid = store.glassStyle == 'liquid';
    final solid = store.glassStyle == 'solid';
    final opacity = solid ? 1.0 : store.glassOpacity.clamp(.35, .9);
    final tint = liquid ? colors.primary : colors.surfaceContainerHighest;
    final blur = solid
        ? 0.0
        : liquid
        ? 24.0
        : 14.0;
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: opacity),
              gradient: liquid
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        tint.withValues(alpha: .12),
                        colors.surface.withValues(alpha: opacity),
                        colors.tertiary.withValues(alpha: .04),
                      ],
                    )
                  : null,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: (liquid ? colors.primary : colors.outlineVariant)
                    .withValues(alpha: liquid ? .22 : .55),
              ),
              boxShadow: liquid
                  ? [
                      BoxShadow(
                        color: colors.primary.withValues(alpha: .08),
                        blurRadius: 24,
                        spreadRadius: -10,
                      ),
                    ]
                  : null,
            ),
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ),
      ),
    );
  }
}
