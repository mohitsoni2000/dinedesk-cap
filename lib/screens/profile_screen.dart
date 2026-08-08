import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/app_card.dart';
import '../widgets/app_surface.dart';
import '../widgets/liquid_chrome.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final op = ref.watch(operatorProvider);
    final opName = op?.name ?? '';
    final opUsername = op?.id ?? '';
    final opRole = op?.role ?? '';
    final opShift = op?.shift ?? '';
    final stats = ref.watch(operatorStatsProvider);
    final restaurant = ref.watch(restaurantProvider);
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final restaurantAddress = restaurant?.address ?? '';
    final restaurantDevice = restaurant?.adminDeviceLabel ?? '';
    final restaurantIp = restaurant?.adminIp ?? '';
    final conn = ref.watch(connectionProvider);

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: PageContentClamp(
            child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Profile', style: AppTypography.displayLg),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    AppSurface(
                      child: Row(
                        children: [
                          Container(
                            width: 54,
                            height: 54,
                            decoration: const BoxDecoration(
                              color: AppColors.terra,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                  opName.isNotEmpty
                                      ? opName[0].toUpperCase()
                                      : '?',
                                  style: AppTypography.headline
                                      .copyWith(color: Colors.white)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(opName, style: AppTypography.title),
                                const SizedBox(height: 2),
                                Text('@$opUsername · $opRole · $restaurantName',
                                    style: context.palette.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 6),
                                if (opShift.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: context.palette.terraSoft,
                                      borderRadius:
                                          BorderRadius.all(AppRadii.pill),
                                    ),
                                    child: Text(
                                      '${opShift.toUpperCase()} SHIFT',
                                      style: AppTypography.pill.copyWith(
                                          color: AppColors.terraInk),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    Text("TODAY'S SHIFT",
                        style: context.palette.micro
                            .copyWith(letterSpacing: 1.4)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                            child: _Kpi(
                          value: '${stats.ordersToday}',
                          label: 'Orders',
                          tint: AppColors.terra,
                        )),
                        const SizedBox(width: 8),
                        Expanded(
                            child: _Kpi(
                          value: '${stats.tablesServed}',
                          label: 'Tables',
                          tint: AppColors.violet,
                        )),
                        const SizedBox(width: 8),
                        Expanded(
                            child: _Kpi(
                          value: '${stats.itemsSold}',
                          label: 'Items',
                          tint: AppColors.success,
                        )),
                      ],
                    ),
                    const SizedBox(height: 16),

                  Text('PAIRED WITH',
                      style:
                          context.palette.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: conn.online
                                    ? AppColors.success
                                    : AppColors.warn,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(restaurantName,
                                  style: AppTypography.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(restaurantAddress,
                            style: context.palette.caption),
                        const SizedBox(height: 10),
                        Divider(height: 1, color: context.palette.ink10),
                        const SizedBox(height: 10),
                        _InfoRow(
                            icon: Icons.computer,
                            label: 'Admin device',
                            value: restaurantDevice),
                        const SizedBox(height: 6),
                        _InfoRow(
                            icon: Icons.wifi,
                            label: 'Network',
                            value: '$restaurantIp · LAN'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      ListTile(
                        leading: Icon(Icons.admin_panel_settings_outlined,
                            color: context.palette.ink70),
                        title: const Text('PIN managed on desktop',
                            style: AppTypography.bodyMd),
                        subtitle: Text('Ask an admin to reset operator PIN',
                            style: context.palette.caption),
                      ),
                      Divider(height: 1, color: context.palette.ink10),
                      ListTile(
                        leading: Icon(Icons.qr_code_scanner,
                            color: context.palette.ink70),
                        title: const Text('Re-pair this device',
                            style: AppTypography.bodyMd),
                        subtitle: Text(
                            'Scan a fresh QR from the admin desktop',
                            style: context.palette.caption),
                        trailing: Icon(Icons.chevron_right,
                            color: context.palette.ink30),
                        onTap: () => context.go('/scan'),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  LiquidSecondaryButton(
                    label: 'Sign out',
                    leadingIcon: Icons.logout,
                    onPressed: () {

                      ref.read(syncServiceProvider).unregisterListeners();
                      ref.read(socketServiceProvider).disconnect();
                      SessionService().clearPairing();
                      ref.read(cartProvider.notifier).clear();
                      ref.read(orderNotesProvider.notifier).state = '';
                      ref.read(selectedTableIdProvider.notifier).state = null;
                      ref.read(forceDisconnectedProvider.notifier).state =
                          false;
                      ref.read(isAuthenticatedProvider.notifier).state = false;
                      context.go('/scan');
                    },
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text('RestroApp v1.0.0',
                        style: context.palette.micro
                            .copyWith(letterSpacing: 1.0)),
                  ),
                ],
              ),
            ),
          ],
        ),
      )),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  final String value;
  final String label;
  final Color tint;
  const _Kpi({required this.value, required this.label, required this.tint});
  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
          ),
          const SizedBox(height: 8),
          Text(value,
              style: AppTypography.headline.copyWith(fontSize: 22)),
          const SizedBox(height: 2),
          Text(label, style: context.palette.caption),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(
      {required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: context.palette.ink50, size: 16),
        const SizedBox(width: 8),
        SizedBox(
            width: 90, child: Text(label, style: context.palette.caption)),
        Expanded(
          child: Text(value,
              style: AppTypography.bodyMd
                  .copyWith(fontFamily: 'monospace', fontSize: 13)),
        ),
      ],
    );
  }
}
