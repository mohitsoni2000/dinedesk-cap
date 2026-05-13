import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final op = ref.watch(operatorProvider);
    final stats = ref.watch(operatorStatsProvider);
    final restaurant = ref.watch(restaurantProvider);
    final conn = ref.watch(connectionProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const LiquidAppBar(title: 'Profile'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // Operator card.
                  AppCard(
                    child: Row(
                      children: [
                        Container(
                          width: 56, height: 56,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [AppColors.terra400, AppColors.terra600],
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(op.name.isNotEmpty ? op.name[0].toUpperCase() : '?',
                              style: AppTypography.headline.copyWith(color: Colors.white)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(op.name, style: AppTypography.title),
                              const SizedBox(height: 2),
                              Text('@${op.username} · ${op.role}',
                                style: AppTypography.caption),
                              const SizedBox(height: 4),
                              Text(op.shift,
                                style: AppTypography.caption.copyWith(
                                  color: AppColors.terra600,
                                  fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Today's KPIs.
                  Text("TODAY'S SHIFT",
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: _Kpi(
                        value: '${stats.ordersToday}',
                        label: 'Orders',
                        tint: AppColors.terra500,
                      )),
                      const SizedBox(width: 8),
                      Expanded(child: _Kpi(
                        value: '${stats.tablesServed}',
                        label: 'Tables',
                        tint: AppColors.violet,
                      )),
                      const SizedBox(width: 8),
                      Expanded(child: _Kpi(
                        value: '${stats.itemsSold}',
                        label: 'Items',
                        tint: AppColors.success,
                      )),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Restaurant + connection info.
                  Text('PAIRED WITH',
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8, height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: conn.online ? AppColors.success : AppColors.warn,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(restaurant.name, style: AppTypography.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(restaurant.address, style: AppTypography.caption),
                        const SizedBox(height: 10),
                        const Divider(height: 1, color: AppColors.ink10),
                        const SizedBox(height: 10),
                        _InfoRow(
                          icon: Icons.computer,
                          label: 'Admin device',
                          value: restaurant.adminDeviceLabel),
                        const SizedBox(height: 6),
                        _InfoRow(
                          icon: Icons.wifi,
                          label: 'Network',
                          value: '${restaurant.adminIp} · LAN'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Account actions.
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      ListTile(
                        leading: const Icon(Icons.password, color: AppColors.ink70),
                        title: const Text('Change PIN', style: AppTypography.bodyMd),
                        trailing: const Icon(Icons.chevron_right, color: AppColors.ink30),
                        onTap: () => context.push('/change-pin'),
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      ListTile(
                        leading: const Icon(Icons.qr_code_scanner, color: AppColors.ink70),
                        title: const Text('Re-pair this device',
                          style: AppTypography.bodyMd),
                        subtitle: const Text('Scan a fresh QR from the admin desktop',
                          style: AppTypography.caption),
                        trailing: const Icon(Icons.chevron_right, color: AppColors.ink30),
                        onTap: () => context.go('/scan'),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  LiquidSecondaryButton(
                    label: 'Sign out',
                    leadingIcon: Icons.logout,
                    onPressed: () {
                      // Clear all session state before sign-out (C5 fix).
                      ref.read(cartProvider.notifier).clear();
                      ref.read(orderNotesProvider.notifier).state = '';
                      ref.read(orderCustomerCountProvider.notifier).state = 2;
                      ref.read(selectedTableIdProvider.notifier).state = null;
                      ref.read(isAuthenticatedProvider.notifier).state = false;
                      context.go('/auth');
                    },
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text('RestroApp v1.0.0',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.0)),
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
            width: 8, height: 8,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
          ),
          const SizedBox(height: 8),
          Text(value, style: AppTypography.displayMd),
          const SizedBox(height: 2),
          Text(label, style: AppTypography.caption),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.ink50, size: 16),
        const SizedBox(width: 8),
        SizedBox(width: 90, child: Text(label, style: AppTypography.caption)),
        Expanded(
          child: Text(value,
            style: AppTypography.bodyMd.copyWith(
              fontFamily: 'monospace', fontSize: 13)),
        ),
      ],
    );
  }
}
