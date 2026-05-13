import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final restaurant = ref.watch(restaurantProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const LiquidAppBar(title: 'Settings'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // Real settings.
                  Text('PREFERENCES',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      ListTile(
                        leading: const Icon(Icons.notifications_outlined,
                            color: AppColors.ink70),
                        title:
                            const Text('Notifications', style: AppTypography.bodyMd),
                        subtitle: const Text('Sounds, vibrations, banners',
                            style: AppTypography.caption),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppColors.ink30),
                        onTap: () {},
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      ListTile(
                        leading: const Icon(Icons.palette_outlined,
                            color: AppColors.ink70),
                        title: const Text('Appearance', style: AppTypography.bodyMd),
                        subtitle: const Text('Theme, text size',
                            style: AppTypography.caption),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppColors.ink30),
                        onTap: () {},
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      ListTile(
                        leading: const Icon(Icons.info_outline,
                            color: AppColors.ink70),
                        title: const Text('About RestroApp',
                            style: AppTypography.bodyMd),
                        subtitle: Text('v1.0.0 · ${restaurant.name}',
                            style: AppTypography.caption),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppColors.ink30),
                        onTap: () {},
                      ),
                    ]),
                  ),
                  const SizedBox(height: 24),

                  // Demo helpers — for testing the connection states.
                  Text('DEMO',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      SwitchListTile(
                        value: !conn.online,
                        activeThumbColor: AppColors.terra500,
                        title: const Text('Simulate offline',
                            style: AppTypography.bodyMd),
                        subtitle: Text(
                          conn.online
                              ? 'Tap to drop the WS connection'
                              : 'Banner countdown active · 2:00 → /disconnected',
                          style: AppTypography.caption,
                        ),
                        onChanged: (v) {
                          ref.read(connectionProvider.notifier).state = v
                              ? const ConnectionStatus(
                                  online: false,
                                  label: 'Last sync 12s ago',
                                  secondsRemaining: 120)
                              : const ConnectionStatus(
                                  online: true,
                                  label: 'Connected · Spice Garden');
                        },
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      ListTile(
                        leading: const Icon(Icons.wifi_off_rounded,
                            color: AppColors.warn),
                        title: Text('Disconnected screen',
                            style: AppTypography.bodyMd
                                .copyWith(color: AppColors.warn)),
                        subtitle: const Text('Preview the timeout state',
                            style: AppTypography.caption),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppColors.ink30),
                        onTap: () => context.push('/disconnected'),
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      ListTile(
                        leading: const Icon(Icons.power_off_rounded,
                            color: AppColors.danger),
                        title: Text('Force-disconnect screen',
                            style: AppTypography.bodyMd
                                .copyWith(color: AppColors.danger)),
                        subtitle: const Text('Preview the kicked-device blocker',
                            style: AppTypography.caption),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppColors.ink30),
                        onTap: () => context.push('/force-disconnected'),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
