import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class PageContentClamp extends StatelessWidget {
  const PageContentClamp({
    super.key,
    required this.child,
    this.maxWidth = readable,
  });

  static const double readable = 760;

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
