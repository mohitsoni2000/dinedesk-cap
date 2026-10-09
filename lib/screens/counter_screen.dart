import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/page_content_clamp.dart';

/// Counter home: table-less ordering with daily tokens, the home tab on a QSR
/// desk. A placeholder until the counter flow lands; the tab only shows when
/// the desk runs in QSR mode.
class CounterScreen extends StatelessWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: PageContentClamp(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('Counter', style: AppTypography.displayLg),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.storefront_outlined,
                              size: 48, color: context.palette.ink30),
                          const SizedBox(height: 12),
                          Text(
                            'Counter orders with tokens are on their way to '
                            'Crew. Take counter orders at the desk for now.',
                            textAlign: TextAlign.center,
                            style: context.palette.caption,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
