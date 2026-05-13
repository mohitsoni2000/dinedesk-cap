// Auth Screen — username + PIN entry after successful pairing.
//
// The restaurant name + admin device are shown so the operator can confirm
// they paired with the right machine. Login mode (mobile vs desktop) is
// enforced server-side; here we mock-accept any 4-digit PIN.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/help_sheet.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final TextEditingController _username = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();
  final List<String> _pin = [];
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _username.dispose();
    _usernameFocus.dispose();
    super.dispose();
  }

  void _press(String key) {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (key == 'del') {
        if (_pin.isNotEmpty) _pin.removeLast();
      } else if (_pin.length < 6) {
        _pin.add(key);
        // Don't auto-submit — let user type 4–6 digits and use Submit key.
      }
    });
  }

  void _maybeSubmit() {
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Enter your username first');
      _usernameFocus.requestFocus();
      return;
    }
    if (_pin.length < 4) return;
    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();
    // Mock success after a small delay so the dots filled state is visible.
    Future.delayed(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      ref.read(isAuthenticatedProvider.notifier).state = true;
      context.go('/tables');
    }).catchError((_) {
      if (mounted) setState(() => _submitting = false);
    });
  }

  void _cancelPairing() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Cancel pairing?', style: AppTypography.title),
        content: const Text('You\'ll need to scan the QR again to reconnect.',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.go('/scan');
            },
            child: const Text('Cancel pairing',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final restaurant = ref.watch(restaurantProvider);

    return LiquidMeshBackground(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  children: [
                    // Restaurant header — confirms successful pairing.
                    LiquidGlassSurface(
                      borderRadius: const BorderRadius.all(AppRadii.md),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check_rounded,
                                color: AppColors.success, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Paired · ${restaurant.name}',
                                    style: AppTypography.bodyMd
                                        .copyWith(fontWeight: FontWeight.w600),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text(restaurant.adminDeviceLabel,
                                    style: AppTypography.caption,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    const Text('Welcome back', style: AppTypography.displayMd),
                    const SizedBox(height: 4),
                    const Text('Sign in to start your shift',
                        style: AppTypography.caption),
                    const SizedBox(height: 28),

                    // Username field.
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55),
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        border: Border.all(color: AppColors.ink10),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 4),
                      child: TextField(
                        controller: _username,
                        focusNode: _usernameFocus,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Username',
                          icon: Icon(Icons.person_outline,
                              color: AppColors.ink50),
                        ),
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                      ),
                    ),
                    const SizedBox(height: 18),

                    // PIN dots.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(6, (i) {
                        final filled = i < _pin.length;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: filled
                                ? AppColors.terra500
                                : Colors.transparent,
                            border: Border.all(
                              color:
                                  filled ? AppColors.terra500 : AppColors.ink30,
                              width: 1.5,
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 8),
                    Text('Enter 4–6 digit PIN',
                        style:
                            AppTypography.micro.copyWith(letterSpacing: 1.4)),

                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          style: AppTypography.caption
                              .copyWith(color: AppColors.danger)),
                    ],

                    const Spacer(),
                    _Pad(
                      onPress: _press,
                      onSubmit: _maybeSubmit,
                    ),
                    const SizedBox(height: 14),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: _cancelPairing,
                          icon: const Icon(Icons.close, size: 16),
                          label: const Text('Cancel pairing'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.ink70,
                            textStyle: AppTypography.caption,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => HelpSheet.show(context),
                          icon: const Icon(Icons.help_outline, size: 16),
                          label: const Text('Help'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.ink70,
                            textStyle: AppTypography.caption,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _Pad extends StatelessWidget {
  final void Function(String) onPress;
  final VoidCallback? onSubmit;
  const _Pad({required this.onPress, this.onSubmit});

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['submit', '0', 'del'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final row in _keys)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                for (final k in row) Expanded(child: _key(k)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _key(String k) {
    if (k == 'submit') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: LiquidGlassSurface(
          borderRadius: const BorderRadius.all(AppRadii.md),
          variant: LiquidGlassVariant.terra,
          padding: const EdgeInsets.symmetric(vertical: 18),
          onTap: onSubmit,
          child: const Center(
            child: Icon(Icons.arrow_forward_rounded, color: AppColors.terra600),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.md),
        padding: const EdgeInsets.symmetric(vertical: 18),
        onTap: () => onPress(k),
        child: Center(
          child: k == 'del'
              ? const Icon(Icons.backspace_outlined, color: AppColors.ink)
              : Text(k, style: AppTypography.headline),
        ),
      ),
    );
  }
}
