// Auth Screen — username + PIN entry after successful pairing.
//
// The restaurant name + admin device are shown so the operator can confirm
// they paired with the right machine. Login mode (mobile vs desktop) is
// enforced server-side; PIN is verified via socket event.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../services/session_service.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/help_sheet.dart';
import '../widgets/pin_pad.dart';

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
      if (_pin.length < 6) {
        _pin.add(key);
        // Don't auto-submit — let user type 4–6 digits and use Submit key.
      }
    });
  }

  void _delete() {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.isNotEmpty) _pin.removeLast();
    });
  }

  void _maybeSubmit() {
    if (_pin.length < 4) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    HapticFeedback.mediumImpact();

    final pin = _pin.join();
    final socketService = ref.read(socketServiceProvider);
    final syncService = ref.read(syncServiceProvider);

    socketService.verifyPin(
      pin,
      onVerified: (response) {
        if (!mounted) return;
        // Apply initial sync data from the verify response.
        final syncData = response['sync'] as Map<String, dynamic>? ?? response;
        syncService.applyInitialSync(ref, syncData);
        syncService.unregisterListeners();
        syncService.registerListeners(ref);

        // Set operator info if provided.
        final opData = response['operator'];
        if (opData is Map) {
          final om = Map<String, dynamic>.from(opData);
          ref.read(operatorProvider.notifier).state = Operator(
            name: om['name']?.toString() ?? _username.text.trim(),
            role: om['role']?.toString() ?? 'Waiter',
            shift: om['shift']?.toString() ?? 'Day',
            username: om['id']?.toString() ?? om['username']?.toString() ?? _username.text.trim(),
          );
        }

        ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: true,
          label: 'Connected · ${ref.read(restaurantProvider)?.name ?? 'POS'}',
        );
        ref.read(isAuthenticatedProvider.notifier).state = true;
        context.go('/tables');
      },
      onRejected: (error) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _error = error;
          _pin.clear();
        });
      },
    );
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
              SessionService().clearPairing();
              ref.read(socketServiceProvider).disconnect();
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
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final deviceLabel = restaurant?.adminDeviceLabel ?? 'Admin Desktop';

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
                                Text('Paired · $restaurantName',
                                    style: AppTypography.bodyMd
                                        .copyWith(fontWeight: FontWeight.w600),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text(deviceLabel,
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
                    PinPad(
                      onKeyPress: _press,
                      onSubmit: _maybeSubmit,
                      onDelete: _delete,
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

