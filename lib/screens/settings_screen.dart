import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';

// ─── Local settings state ────────────────────────────────────────────────────

class _SettingsState {
  final bool soundEnabled;
  final bool hapticEnabled;
  const _SettingsState({
    this.soundEnabled = true,
    this.hapticEnabled = true,
  });
  _SettingsState copyWith({bool? soundEnabled, bool? hapticEnabled}) =>
      _SettingsState(
        soundEnabled: soundEnabled ?? this.soundEnabled,
        hapticEnabled: hapticEnabled ?? this.hapticEnabled,
      );
}

class _SettingsNotifier extends StateNotifier<_SettingsState> {
  _SettingsNotifier(this._ref) : super(const _SettingsState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = _SettingsState(
      soundEnabled: prefs.getBool('setting_sound') ?? true,
      hapticEnabled: prefs.getBool('setting_haptic') ?? true,
    );
    _ref.read(hapticEnabledProvider.notifier).state =
        prefs.getBool('setting_haptic') ?? true;
  }

  Future<void> setSoundEnabled(bool v) async {
    state = state.copyWith(soundEnabled: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setting_sound', v);
  }

  Future<void> setHapticEnabled(bool v) async {
    state = state.copyWith(hapticEnabled: v);
    _ref.read(hapticEnabledProvider.notifier).state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setting_haptic', v);
  }
}

final _settingsProvider =
    StateNotifierProvider<_SettingsNotifier, _SettingsState>(
  (ref) => _SettingsNotifier(ref),
);

// ─── Screen ──────────────────────────────────────────────────────────────────

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final restaurant = ref.watch(restaurantProvider);
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final settings = ref.watch(_settingsProvider);

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
                  Text('PREFERENCES',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      // Notifications.
                      ListTile(
                        leading: const Icon(Icons.notifications_outlined,
                            color: AppColors.ink70),
                        title: const Text('Notifications',
                            style: AppTypography.bodyMd),
                        subtitle: Text(
                          settings.soundEnabled && settings.hapticEnabled
                              ? 'Sound & haptics on'
                              : !settings.soundEnabled && !settings.hapticEnabled
                                  ? 'All notifications off'
                                  : settings.soundEnabled
                                      ? 'Sound on, haptics off'
                                      : 'Haptics on, sound off',
                          style: AppTypography.caption,
                        ),
                        trailing:
                            const Icon(Icons.chevron_right, color: AppColors.ink30),
                        onTap: () =>
                            _showNotificationsSheet(context, ref, settings),
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      // Appearance.
                      ListTile(
                        leading: const Icon(Icons.palette_outlined,
                            color: AppColors.ink70),
                        title: const Text('Appearance',
                            style: AppTypography.bodyMd),
                        subtitle: const Text('Light theme · Dark mode coming soon',
                            style: AppTypography.caption),
                        trailing:
                            const Icon(Icons.chevron_right, color: AppColors.ink30),
                        onTap: () => _showAppearanceSheet(context),
                      ),
                      const Divider(height: 1, color: AppColors.ink10),
                      // About.
                      ListTile(
                        leading: const Icon(Icons.info_outline,
                            color: AppColors.ink70),
                        title: const Text('About DineDesk Cap',
                            style: AppTypography.bodyMd),
                        subtitle: Text('v2.0 · $restaurantName',
                            style: AppTypography.caption),
                        trailing:
                            const Icon(Icons.chevron_right, color: AppColors.ink30),
                        onTap: () => _showAboutSheet(context, restaurantName),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 24),

                  if (kDebugMode) ...[
                    Text('DEBUG',
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
                            final restaurant = ref.read(restaurantProvider);
                            ref.read(connectionProvider.notifier).state = v
                                ? const ConnectionStatus(
                                    online: false,
                                    label: 'Last sync 12s ago',
                                    secondsRemaining: 120)
                                : ConnectionStatus(
                                    online: true,
                                    label:
                                        'Connected · ${restaurant?.name ?? 'Restaurant'}');
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
                          subtitle: const Text(
                              'Preview the kicked-device blocker',
                              style: AppTypography.caption),
                          trailing: const Icon(Icons.chevron_right,
                              color: AppColors.ink30),
                          onTap: () => context.push('/force-disconnected'),
                        ),
                      ]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Notifications sheet ──────────────────────────────────────────────────

  void _showNotificationsSheet(
      BuildContext context, WidgetRef ref, _SettingsState settings) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.lg),
      ),
      builder: (ctx) => _NotificationsSheet(settings: settings, ref: ref),
    );
  }

  // ─── Appearance sheet ────────────────────────────────────────────────────

  void _showAppearanceSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.lg),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Appearance', style: AppTypography.headline),
            const SizedBox(height: 4),
            const Text('Customize how DineDesk Cap looks.',
                style: AppTypography.caption),
            const SizedBox(height: 24),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.light_mode_outlined,
                        color: AppColors.terra500),
                    title: const Text('Light', style: AppTypography.bodyMd),
                    subtitle: const Text('Current theme', style: AppTypography.caption),
                    trailing: const Icon(Icons.check_circle,
                        color: AppColors.terra500, size: 20),
                    onTap: () {},
                  ),
                  const Divider(height: 1, color: AppColors.ink10),
                  ListTile(
                    leading: const Icon(Icons.dark_mode_outlined,
                        color: AppColors.ink30),
                    title: Text('Dark',
                        style: AppTypography.bodyMd
                            .copyWith(color: AppColors.ink30)),
                    subtitle: const Text('Coming soon', style: AppTypography.caption),
                    onTap: () {},
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: LiquidSecondaryButton(
                label: 'Done',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 8),
          ],
        ),
      ),
    );
  }

  // ─── About sheet ─────────────────────────────────────────────────────────

  void _showAboutSheet(BuildContext context, String restaurantName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.lg),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.terra400, AppColors.terra600],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.all(AppRadii.md),
              ),
              child: const Icon(Icons.restaurant_menu,
                  color: Colors.white, size: 32),
            ),
            const SizedBox(height: 16),
            const Text('DineDesk Cap', style: AppTypography.headline),
            const SizedBox(height: 4),
            const Text('v2.0', style: AppTypography.caption),
            const SizedBox(height: 2),
            Text('Paired with: $restaurantName',
                style: AppTypography.caption),
            const SizedBox(height: 20),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _AboutRow(
                    icon: Icons.devices_outlined,
                    label: 'Platform',
                    value: 'Mobile Waiter App',
                  ),
                  const Divider(height: 1, color: AppColors.ink10),
                  _AboutRow(
                    icon: Icons.shield_outlined,
                    label: 'Security',
                    value: 'PIN-protected sessions',
                  ),
                  const Divider(height: 1, color: AppColors.ink10),
                  _AboutRow(
                    icon: Icons.sync_outlined,
                    label: 'Sync',
                    value: 'Real-time via Socket.IO',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: LiquidSecondaryButton(
                label: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 8),
          ],
        ),
      ),
    );
  }
}

// ─── Notifications bottom sheet widget ───────────────────────────────────────

class _NotificationsSheet extends StatefulWidget {
  final _SettingsState settings;
  final WidgetRef ref;
  const _NotificationsSheet({required this.settings, required this.ref});

  @override
  State<_NotificationsSheet> createState() => _NotificationsSheetState();
}

class _NotificationsSheetState extends State<_NotificationsSheet> {
  late bool _sound;
  late bool _haptic;

  @override
  void initState() {
    super.initState();
    _sound = widget.settings.soundEnabled;
    _haptic = widget.settings.hapticEnabled;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Notifications', style: AppTypography.headline),
          const SizedBox(height: 4),
          const Text('Control how the app alerts you.',
              style: AppTypography.caption),
          const SizedBox(height: 20),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  value: _sound,
                  activeThumbColor: AppColors.terra500,
                  title:
                      const Text('Sound effects', style: AppTypography.bodyMd),
                  subtitle: const Text('KOT send, item add chimes',
                      style: AppTypography.caption),
                  secondary: const Icon(Icons.volume_up_outlined,
                      color: AppColors.ink70),
                  onChanged: (v) {
                    setState(() => _sound = v);
                    widget.ref.read(_settingsProvider.notifier).setSoundEnabled(v);
                  },
                ),
                const Divider(height: 1, color: AppColors.ink10),
                SwitchListTile(
                  value: _haptic,
                  activeThumbColor: AppColors.terra500,
                  title: const Text('Haptic feedback',
                      style: AppTypography.bodyMd),
                  subtitle: const Text('Vibrations on button press',
                      style: AppTypography.caption),
                  secondary: const Icon(Icons.vibration_outlined,
                      color: AppColors.ink70),
                  onChanged: (v) {
                    setState(() => _haptic = v);
                    widget.ref
                        .read(_settingsProvider.notifier)
                        .setHapticEnabled(v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: LiquidSecondaryButton(
              label: 'Done',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 8),
        ],
      ),
    );
  }
}

// ─── Helper widget ────────────────────────────────────────────────────────────

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _AboutRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.ink50),
          const SizedBox(width: 12),
          Text(label, style: AppTypography.caption),
          const Spacer(),
          Text(value,
              style: AppTypography.caption
                  .copyWith(fontWeight: FontWeight.w600, color: AppColors.ink)),
        ],
      ),
    );
  }
}
