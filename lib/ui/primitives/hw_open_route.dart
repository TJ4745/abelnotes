import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/hw_motion.dart';
import '../theme/hw_theme.dart';

/// Critically damped spring as a Curve, so route animations (which run on
/// durations) still move like [HwSprings.open].
class _SpringCurve extends Curve {
  final double seconds;
  late final SpringSimulation _sim = SpringSimulation(HwSprings.open, 0, 1, 0);
  _SpringCurve(this.seconds);

  @override
  double transformInternal(double t) => t >= 1 ? 1 : _sim.x(t * seconds);
}

/// Opens a page by growing it out of [origin] (a notebook cover) and closes
/// it back into the same rect: the editor comes from, and returns to, the
/// thing that was tapped.
class HwOpenRoute<T> extends PageRouteBuilder<T> {
  HwOpenRoute({
    required WidgetBuilder builder,
    required Rect origin,
    required Widget cover,
  }) : super(
          // fullscreenDialog keeps the library still underneath instead of
          // the Cupertino parallax slide.
          fullscreenDialog: true,
          transitionDuration: const Duration(milliseconds: 560),
          reverseTransitionDuration: const Duration(milliseconds: 480),
          pageBuilder: (context, _, __) => builder(context),
          transitionsBuilder: (context, animation, _, child) {
            if (hwReduceMotion(context)) {
              return FadeTransition(opacity: animation, child: child);
            }
            final curved = CurvedAnimation(
              parent: animation,
              curve: _SpringCurve(0.56),
              reverseCurve: _SpringCurve(0.48).flipped,
            );
            return AnimatedBuilder(
              animation: curved,
              child: child,
              builder: (context, child) =>
                  _grow(context, curved.value, origin, cover, child!),
            );
          },
        );

  static Widget _grow(
      BuildContext context, double t, Rect origin, Widget cover, Widget child) {
    final p = HwThemeScope.of(context);
    final size = MediaQuery.sizeOf(context);
    final rect = Rect.lerp(origin, Offset.zero & size, t)!;
    final radius = Radius.circular(12 * (1 - t));
    return Stack(children: [
      Positioned.fill(
        child: IgnorePointer(child: ColoredBox(color: p.scrim.withValues(alpha: p.scrim.a * t))),
      ),
      Positioned.fromRect(
        rect: rect,
        child: ClipRRect(
          borderRadius: BorderRadius.all(radius),
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: p.paper1),
            // The page keeps full-size layout and is clipped, never squashed.
            OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: size.width,
              maxWidth: size.width,
              minHeight: size.height,
              maxHeight: size.height,
              child: Transform.translate(
                offset: -rect.topLeft,
                // Web skips the fade, a full-screen layer per frame there;
                // the cover on top already hides the page early on.
                child: kIsWeb
                    ? child
                    : Opacity(
                        opacity: ((t - 0.15) / 0.45).clamp(0.0, 1.0),
                        child: child,
                      ),
              ),
            ),
            // The cover dissolves into the page.
            IgnorePointer(
              child: Opacity(
                opacity: (1 - t / 0.55).clamp(0.0, 1.0),
                // Drawn at the tapped size and stretched, so the pattern
                // grows with the cover instead of re-tiling.
                child: FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox.fromSize(
                    size: origin.size,
                    // Route overlays sit above any Material: give the cover's
                    // title a text style instead of the debug fallback.
                    child: Material(type: MaterialType.transparency, child: cover),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}
