import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Caps page content width on wide screens.
///
/// Without this, a single-column screen on a tablet becomes one very long
/// stretched strip — a settings row spanning 1200px reads worse than the same
/// row on a phone. Below [AppBreakpoints.tabletWide] this is a no-op, since
/// phones and portrait tablets need every pixel they have.
class PageContentClamp extends StatelessWidget {
  const PageContentClamp({
    super.key,
    required this.child,
    this.maxWidth = readable,
  });

  /// Lists, forms and settings — roughly a comfortable reading measure.
  static const double readable = 760;

  /// Grid-led screens (the tables floor, rooms) that want the extra columns.
  static const double grid = 1180;

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!context.isTabletWide) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
