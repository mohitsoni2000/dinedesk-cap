// Auth Screen — PIN-only entry after successful pairing.
//
// The operator is already identified by the JWT token from the QR scan.
// No username field is needed — PIN verifies the person holding the device.
// Server responds with operator profile + initial sync data.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
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

class _AuthScreenState extends ConsumerState<AuthScreen>
    with SingleTickerProviderStateMixin {
  final List<String> _pin = [];
  String? _error;
  bool _submitting = false;

  // Shake animation controller for wrong PIN
  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _shakeAnim = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: -12.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -12.0, end: 12.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 12.0, end: -8.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.easeInOut));

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _press(String key) {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.length < 4) {
        _pin.add(key);
        ref.read(feedbackServiceProvider).fire(const FeedbackLight());
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
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());

    final pin = _pin.join();
    final socketService = ref.read(socketServiceProvider);
    final syncService = ref.read(syncServiceProvider);

    socketService.verifyPin(
      pin,
      onVerified: (response) async {
        if (!mounted) return;
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
        final syncRaw = response['sync'];
        final syncData =
            (syncRaw is Map) ? Map<String, dynamic>.from(syncRaw) : response;
        await syncService.applyInitialSync(syncData);
        syncService.unregisterListeners();
        syncService.registerListeners();

        final opData = response['operator'];
        if (opData is Map) {
          final om = Map<String, dynamic>.from(opData);
          ref.read(operatorProvider.notifier).state = Operator(
            name: om['name']?.toString() ?? 'Operator',
            role: om['role']?.toString() ?? 'Waiter',
            shift: om['shift']?.toString() ?? 'Day',
            username: om['id']?.toString() ?? om['username']?.toString() ?? '',
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
        ref.read(feedbackServiceProvider).fire(const FeedbackError());
        setState(() {
          _submitting = false;
          _error = error;
          _pin.clear();
        });
        _shakeCtrl.forward(from: 0);
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
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.lg),
                sliver: SliverFillRemaining(
                  hasScrollBody: false,
                  child: Column(
                    children: [
                      // Paired restaurant badge — top strip
                      LiquidGlassSurface(
                        borderRadius: const BorderRadius.all(AppRadii.md),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.success.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.wifi_rounded,
                                  color: AppColors.success, size: 16),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(restaurantName,
                                      style: AppTypography.bodyMd.copyWith(
                                          fontWeight: FontWeight.w700),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  Text('Paired · $deviceLabel',
                                      style: AppTypography.caption.copyWith(
                                          color: AppColors.success),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: AppColors.success,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const Spacer(),

                      // Logo + headline block
                      Hero(
                        tag: HeroTags.appLogo,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            color: AppColors.logoBg,
                            borderRadius: BorderRadius.all(AppRadii.md),
                            boxShadow: AppShadows.terraGlow,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: const EdgeInsets.all(7),
                            child: Image.asset(
                              'assets/images/appicon_cream.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Headline: big Cormorant serif — feels editorial & premium
                      const Text(
                        'Welcome back',
                        style: TextStyle(
                          fontFamily: AppTypography.cormorant,
                          fontWeight: FontWeight.w600,
                          fontSize: 36,
                          height: 1.05,
                          color: AppColors.ink,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Enter your PIN to start your shift',
                        style: AppTypography.caption.copyWith(
                          fontSize: 13,
                          color: AppColors.ink50,
                        ),
                      ),

                      const SizedBox(height: 32),

                      // PIN dots — shakes on error
                      AnimatedBuilder(
                        animation: _shakeAnim,
                        builder: (_, child) => Transform.translate(
                          offset: Offset(_shakeAnim.value, 0),
                          child: child,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(4, (i) {
                            final filled = i < _pin.length;
                            final isError = _error != null;
                            return SpringBuilder(
                              to: filled ? 1.0 : 0.0,
                              spring: RestroSprings.snappy,
                              builder: (_, t, __) {
                                final fillColor = isError
                                    ? Color.lerp(Colors.transparent,
                                        AppColors.danger, t)!
                                    : Color.lerp(Colors.transparent,
                                        AppColors.terra500, t)!;
                                final borderColor = isError
                                    ? Color.lerp(AppColors.ink10,
                                        AppColors.danger, t)!
                                    : Color.lerp(AppColors.ink30,
                                        AppColors.terra500, t)!;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  width: filled ? 18 : 16,
                                  height: filled ? 18 : 16,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: fillColor,
                                    border: Border.all(
                                      color: borderColor,
                                      width: 1.5,
                                    ),
                                    boxShadow: filled && !isError
                                        ? [
                                            BoxShadow(
                                              color: AppColors.terra400
                                                  .withValues(alpha: 0.4 * t),
                                              blurRadius: 10,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : null,
                                  ),
                                );
                              },
                            );
                          }),
                        ),
                      ),

                      const SizedBox(height: 8),

                      // Error text or spacer label
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _error != null
                            ? Padding(
                                key: const ValueKey('error'),
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  _error!,
                                  style: AppTypography.caption.copyWith(
                                    color: AppColors.danger,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              )
                            : Padding(
                                key: const ValueKey('label'),
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  '4-DIGIT PIN',
                                  style: AppTypography.micro.copyWith(
                                    letterSpacing: 2.0,
                                    color: AppColors.ink30,
                                  ),
                                ),
                              ),
                      ),

                      const Spacer(),

                      // PIN Pad
                      PinPad(
                        onKeyPress: _press,
                        onSubmit: _maybeSubmit,
                        onDelete: _delete,
                      ),
                      const SizedBox(height: 16),

                      // Footer actions
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton.icon(
                            onPressed: _cancelPairing,
                            icon: const Icon(Icons.link_off_rounded, size: 15),
                            label: const Text('Cancel pairing'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.ink50,
                              textStyle: AppTypography.caption,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => HelpSheet.show(context),
                            icon: const Icon(Icons.help_outline_rounded,
                                size: 15),
                            label: const Text('Help'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.ink50,
                              textStyle: AppTypography.caption,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
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
