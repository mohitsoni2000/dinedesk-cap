import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';
import '../services/biometric_service.dart';
import '../theme/theme_mode_provider.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/app_surface.dart';
import '../widgets/liquid_chrome.dart';

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

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final restaurant = ref.watch(restaurantProvider);
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final settings = ref.watch(_settingsProvider);

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Settings', style: AppTypography.displayLg),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    Text('FEEDBACK',
                        style: AppTypography.micro
                            .copyWith(letterSpacing: 1.4)),
                    const SizedBox(height: 8),
                    AppSurface(
                      padding: EdgeInsets.zero,
                      child: Column(children: [
                        _SettingsRow(
                          icon: Icons.notifications_outlined,
                          title: 'Notifications',
                          subtitle: settings.soundEnabled &&
                                  settings.hapticEnabled
                              ? 'Sound & haptics on'
                              : !settings.soundEnabled &&
                                      !settings.hapticEnabled
                                  ? 'All notifications off'
                                  : settings.soundEnabled
                                      ? 'Sound on, haptics off'
                                      : 'Haptics on, sound off',
                          onTap: () =>
                              _showNotificationsSheet(context, ref, settings),
                        ),
                        Divider(height: 1, color: context.palette.hairline),
                        _SettingsRow(
                          icon: Icons.palette_outlined,
                          title: 'Appearance',
                          subtitle: switch (ref.watch(themeModeProvider)) {
                            ThemeMode.system => 'System · follows device',
                            ThemeMode.light => 'Light theme',
                            ThemeMode.dark => 'Dark theme',
                          },
                          onTap: () => _showAppearanceSheet(context),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 24),

                    Text('DEVICE',
                        style: AppTypography.micro
                            .copyWith(letterSpacing: 1.4)),
                    const SizedBox(height: 8),
                    AppSurface(
                      padding: EdgeInsets.zero,
                      child: Column(children: [
                        _SettingsRow(
                          icon: Icons.lock_reset_outlined,
                          title: 'Change PIN',
                          subtitle: 'Update your operator PIN',
                          onTap: () => context.push('/change-pin'),
                        ),
                        Divider(height: 1, color: context.palette.hairline),
                        const _BiometricRow(),
                        Divider(height: 1, color: context.palette.hairline),
                        _SettingsRow(
                          icon: Icons.info_outline,
                          title: 'About Command.Crew',
                          subtitle: 'v2.0 · $restaurantName',
                          onTap: () =>
                              _showAboutSheet(context, restaurantName),
                        ),
                      ]),
                    ),

                    if (kDebugMode) ...[
                      const SizedBox(height: 24),
                      Text('DANGER ZONE',
                          style: AppTypography.micro.copyWith(
                              letterSpacing: 1.4, color: AppColors.danger)),
                      const SizedBox(height: 8),
                      AppSurface(
                        padding: EdgeInsets.zero,
                        border: Border.all(
                            color: AppColors.danger.withValues(alpha: 0.25)),
                        child: Column(children: [
                          SwitchListTile(
                            value: !conn.online,
                            activeThumbColor: AppColors.terra,
                            title: const Text('Simulate offline',
                                style: AppTypography.bodyMd),
                            subtitle: Text(
                              conn.online
                                  ? 'Tap to drop the WS connection'
                                  : 'Banner countdown active · 15:00 → /disconnected',
                              style: AppTypography.caption,
                            ),
                            onChanged: (v) {
                              final restaurant = ref.read(restaurantProvider);
                              ref.read(connectionProvider.notifier).state = v
                                  ? const ConnectionStatus(
                                      online: false,
                                      label: 'Last sync 12s ago',
                                      secondsRemaining: 900)
                                  : ConnectionStatus(
                                      online: true,
                                      label:
                                          'Connected · ${restaurant?.name ?? 'Restaurant'}');
                            },
                          ),
                          Divider(height: 1, color: context.palette.hairline),
                          _SettingsRow(
                            icon: Icons.wifi_off_rounded,
                            title: 'Disconnected screen',
                            subtitle: 'Preview the timeout state',
                            danger: true,
                            onTap: () => context.push('/disconnected'),
                          ),
                          Divider(height: 1, color: context.palette.hairline),
                          _SettingsRow(
                            icon: Icons.power_off_rounded,
                            title: 'Force-disconnect screen',
                            subtitle: 'Preview the kicked-device blocker',
                            danger: true,
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
      ),
    );
  }

  void _showNotificationsSheet(
      BuildContext context, WidgetRef ref, _SettingsState settings) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.lg),
      ),
      builder: (ctx) => _NotificationsSheet(settings: settings, ref: ref),
    );
  }

  void _showAppearanceSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.palette.surface,
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
            const Text('Customize how Command.Crew looks.',
                style: AppTypography.caption),
            const SizedBox(height: 24),
            Consumer(builder: (context, ref, _) {
              final mode = ref.watch(themeModeProvider);
              Widget option({
                required ThemeMode value,
                required IconData icon,
                required String label,
                required String subtitle,
              }) {
                final selected = mode == value;
                return ListTile(
                  leading: Icon(icon,
                      color: selected
                          ? AppColors.terra500
                          : context.palette.ink70),
                  title: Text(label, style: AppTypography.bodyMd),
                  subtitle: Text(subtitle, style: AppTypography.caption),
                  trailing: selected
                      ? const Icon(Icons.check_circle,
                          color: AppColors.terra500, size: 20)
                      : null,
                  onTap: () =>
                      ref.read(themeModeProvider.notifier).set(value),
                );
              }

              return AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    option(
                      value: ThemeMode.system,
                      icon: Icons.brightness_auto_outlined,
                      label: 'System',
                      subtitle: 'Follow device setting',
                    ),
                    Divider(height: 1, color: context.palette.ink10),
                    option(
                      value: ThemeMode.light,
                      icon: Icons.light_mode_outlined,
                      label: 'Light',
                      subtitle: 'Warm cream · daytime shifts',
                    ),
                    Divider(height: 1, color: context.palette.ink10),
                    option(
                      value: ThemeMode.dark,
                      icon: Icons.dark_mode_outlined,
                      label: 'Dark',
                      subtitle: 'Midnight tandoor · evening service',
                    ),
                  ],
                ),
              );
            }),
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

  void _showAboutSheet(BuildContext context, String restaurantName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.palette.surface,
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
            const Text('Command.Crew', style: AppTypography.headline),
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
                  Divider(height: 1, color: context.palette.ink10),
                  _AboutRow(
                    icon: Icons.shield_outlined,
                    label: 'Security',
                    value: 'PIN-protected sessions',
                  ),
                  Divider(height: 1, color: context.palette.ink10),
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

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppColors.danger : context.palette.ink;
    return ListTile(
      leading: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: danger
              ? AppColors.danger.withValues(alpha: 0.10)
              : context.palette.terraSoft,
          borderRadius: const BorderRadius.all(AppRadii.xs),
        ),
        child: Icon(icon,
            size: 16, color: danger ? AppColors.danger : AppColors.terraDeep),
      ),
      title: Text(title, style: AppTypography.bodyMd.copyWith(color: fg)),
      subtitle: Text(subtitle, style: AppTypography.caption),
      trailing: Icon(Icons.chevron_right, color: context.palette.ink30),
      onTap: onTap,
    );
  }
}

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
                  secondary: Icon(Icons.volume_up_outlined,
                      color: context.palette.ink70),
                  onChanged: (v) {
                    setState(() => _sound = v);
                    widget.ref.read(_settingsProvider.notifier).setSoundEnabled(v);
                  },
                ),
                Divider(height: 1, color: context.palette.ink10),
                SwitchListTile(
                  value: _haptic,
                  activeThumbColor: AppColors.terra500,
                  title: const Text('Haptic feedback',
                      style: AppTypography.bodyMd),
                  subtitle: const Text('Vibrations on button press',
                      style: AppTypography.caption),
                  secondary: Icon(Icons.vibration_outlined,
                      color: context.palette.ink70),
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
          Icon(icon, size: 18, color: context.palette.ink50),
          const SizedBox(width: 12),
          Text(label, style: AppTypography.caption),
          const Spacer(),
          Text(value,
              style: AppTypography.caption
                  .copyWith(fontWeight: FontWeight.w600, color: context.palette.ink)),
        ],
      ),
    );
  }
}

class _BiometricRow extends ConsumerStatefulWidget {
  const _BiometricRow();
  @override
  ConsumerState<_BiometricRow> createState() => _BiometricRowState();
}

class _BiometricRowState extends ConsumerState<_BiometricRow> {
  bool? _enabled;
  bool _supported = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bio = ref.read(biometricServiceProvider);
    final supported = await bio.canUse();
    final enabled = await bio.isEnabled();
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _enabled = enabled;
    });
  }

  Future<void> _tap() async {
    final bio = ref.read(biometricServiceProvider);
    if (!_supported) return;
    if (_enabled == true) {
      await bio.disable();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            content: Text('Biometric unlock off — you\'ll sign in with your PIN')));
    } else {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            content: Text(
                'Sign in with your PIN next time — you\'ll find the enable option right here')));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = !_supported
        ? 'Not available on this device'
        : _enabled == null
            ? '…'
            : _enabled!
                ? 'On · Face/fingerprint starts your shift'
                : 'Off · tap for how to enable';
    return _SettingsRow(
      icon: Icons.fingerprint,
      title: 'Biometric unlock',
      subtitle: subtitle,
      onTap: _tap,
    );
  }
}
