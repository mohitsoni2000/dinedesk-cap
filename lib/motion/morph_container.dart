import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

/// Standardised [OpenContainer] preset for Restro.
class RestroMorph extends StatelessWidget {
  const RestroMorph({
    required this.closedBuilder,
    required this.openBuilder,
    this.closedColor = Colors.transparent,
    this.closedShape = const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
    ),
    this.transitionDuration = const Duration(milliseconds: 420),
    super.key,
  });

  final CloseContainerBuilder closedBuilder;
  final OpenContainerBuilder<void> openBuilder;
  final Color closedColor;
  final ShapeBorder closedShape;
  final Duration transitionDuration;

  @override
  Widget build(BuildContext context) {
    return OpenContainer<void>(
      closedColor: closedColor,
      openColor: Theme.of(context).colorScheme.surface,
      closedShape: closedShape,
      closedElevation: 0,
      openElevation: 0,
      transitionType: ContainerTransitionType.fadeThrough,
      transitionDuration: transitionDuration,
      closedBuilder: closedBuilder,
      openBuilder: openBuilder,
    );
  }
}

/// Standard shuttle that interpolates fade between two Hero sides during flight.
Widget restroFadeShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  // Safe cast: hero contexts are guaranteed to wrap a Hero widget.
  final Widget fromHero = fromHeroContext.widget is Hero
      ? (fromHeroContext.widget as Hero).child // safe: is-check above
      : const SizedBox.shrink();
  final Widget toHero = toHeroContext.widget is Hero
      ? (toHeroContext.widget as Hero).child // safe: is-check above
      : const SizedBox.shrink();
  return AnimatedBuilder(
    animation: animation,
    builder: (BuildContext context, Widget? _) {
      return Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Opacity(opacity: 1 - animation.value, child: fromHero),
          Opacity(opacity: animation.value, child: toHero),
        ],
      );
    },
  );
}
