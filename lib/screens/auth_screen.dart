// Auth Screen — PIN-only entry after successful pairing.
//
// The operator is already identified by the JWT token from the QR scan.
// No username field is needed — PIN verifies the person holding the device.
// Server responds with operator profile + initial sync data.

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
  final List<String> _pin = [];
  String? _error;
  bool _submitting = false;

  void _press(String key) {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.length < 4) {
        _pin.add(key);
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
    debugPrint('[Auth] Submitting PIN (${'*' * pin.length})...');
    final socketService = ref.read(socketServiceProvider);
    final syncService = ref.read(syncServiceProvider);

    socketService.verifyPin(
      pin,
      onVerified: (response) {
        if (!mounted) return;
        debugPrint('[Auth] ✓ PIN verified — applying initial sync');
        // Apply initial sync data from the verify response.
        final syncRaw = response['sync'];
        final syncData = (syncRaw is Map)
            ? Map<String, dynamic>.from(syncRaw)
            : response;
        syncService.applyInitialSync(syncData);
        syncService.unregisterListeners();
        syncService.registerListeners();

        // Set operator info if provided.
        final opData = response['operator'];
        if (opData is Map) {
          final om = Map<String, dynamic>.from(opData);
          final opName = om['name']?.toString() ?? 'Operator';
          final opRole = om['role']?.toString() ?? 'Waiter';
          debugPrint('[Auth] Operator: $opName ($opRole)');
          ref.read(operatorProvider.notifier).state = Operator(
            name: opName,
            role: opRole,
            shift: om['shift']?.toString() ?? 'Day',
            username: om['id']?.toString() ?? om['username']?.toString() ?? '',
          );
        } else {
          debugPrint('[Auth] ⚠ No operator data in response');
        }

        ref.read(connectionProvider.notifier).state = ConnectionStatus(
          online: true,
          label: 'Connected · ${ref.read(restaurantProvider)?.name ?? 'POS'}',
        );
        ref.read(isAuthenticatedProvider.notifier).state = true;
        debugPrint('[Auth] → Navigating to /tables');
        context.go('/tables');
      },
      onRejected: (error) {
        if (!mounted) return;
        debugPrint('[Auth] ✗ PIN rejected: $error');
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

                    // PIN dots — operator identified by JWT token, only PIN needed.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(4, (i) {
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
                    Text('Enter 4-digit PIN',
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

