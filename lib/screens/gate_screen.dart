import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/page_content_clamp.dart';

/// Gate home: issue entry tickets and check guests in. A placeholder until
/// the gate flow lands; the tab only shows for a user with gate rights.
class GateScreen extends StatelessWidget {
  const GateScreen({super.key});

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
                  child: Text('Gate', style: AppTypography.displayLg),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.confirmation_number_outlined,
                              size: 48, color: context.palette.ink30),
                          const SizedBox(height: 12),
                          Text(
                            'Ticket issue and entry scanning are on their way '
                            'to Crew. Use the desk for the gate for now.',
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
