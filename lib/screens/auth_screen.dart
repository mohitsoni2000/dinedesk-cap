import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/demo_data.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/biometric_service.dart';
import '../services/kot_queue_service.dart';
import '../services/offline_order_queue_service.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/help_sheet.dart';
import '../widgets/page_content_clamp.dart';
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
  bool _verified = false;

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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometricUnlock());
  }

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
    if (_pin.length == 4) {
      Future.delayed(const Duration(milliseconds: 180), _maybeSubmit);
    }
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
    unawaited(SessionService().getSavedPairing().then((pairing) {
      if (kDebugMode && pairing?.token == 'demo-token') {
        unawaited(_submitDemo());
      } else {
        unawaited(_submitReal(pin));
      }
    }));
  }

  Future<void> _submitDemo() async {
    assert(kDebugMode, 'demo login must never run in a release build');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());

    ref.read(operatorProvider.notifier).state = const Operator(
      name: 'Demo Waiter',
      role: 'Waiter',
      shift: 'Day',
      id: 'op_demo',
    );

    final syncService = ref.read(syncServiceProvider);
    await syncService.applyInitialSync(buildDemoSyncPayload());
    syncService.registerListeners();

    ref.read(connectionProvider.notifier).state = ConnectionStatus(
      online: true,
      label: 'Connected · ${ref.read(restaurantProvider)?.name ?? 'POS'}',
    );
    ref.read(isAuthenticatedProvider.notifier).state = true;
    if (!mounted) return;
    setState(() => _verified = true);
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) context.go('/tables');
  }

  Future<void> _submitReal(String pin) async {
    final socketService = ref.read(socketServiceProvider);
    final syncService = ref.read(syncServiceProvider);

    final response = await socketService.verifyPin(pin);
    if (!mounted) return;

    if (response['kind'] != 'success') {
      ref.read(feedbackServiceProvider).fire(const FeedbackError());
      setState(() {
        _submitting = false;
        _error = response['message']?.toString() ?? 'Invalid PIN';
        _pin.clear();
      });
      _shakeCtrl.forward(from: 0);
      return;
    }

    ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
    final syncRaw = response['sync'];
    final syncData =
        (syncRaw is Map) ? Map<String, dynamic>.from(syncRaw) : response;
    await syncService.applyInitialSync(syncData);
    if (!mounted) return;
    syncService.registerListeners();

    final opData = response['operator'];
    if (opData is Map) {
      final om = Map<String, dynamic>.from(opData);
      ref.read(operatorProvider.notifier).state = Operator(
        name: om['name']?.toString() ?? 'Operator',
        role: om['role']?.toString() ?? 'Waiter',
        shift: om['shift']?.toString() ?? 'Day',
        id: om['id']?.toString() ?? om['username']?.toString() ?? '',
        employeeId: om['employeeId']?.toString(),
      );
    }

    ref.read(connectionProvider.notifier).state = ConnectionStatus(
      online: true,
      label: 'Connected · ${ref.read(restaurantProvider)?.name ?? 'POS'}',
    );
    ref.read(isAuthenticatedProvider.notifier).state = true;
    unawaited(ref.read(offlineOrderQueueProvider).flush(socketService).then(
        (_) => ref.read(kotQueueProvider).flush(socketService)));
    await _maybeOfferBiometric(pin);
    if (!mounted) return;
    setState(() => _verified = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) context.go('/tables');
  }

  Future<void> _tryBiometricUnlock() async {
    final bio = ref.read(biometricServiceProvider);
    if (!await bio.isEnabled()) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    final state = ref.read(socketServiceProvider).state;
    if (state != SocketState.connected && state != SocketState.verified) {
      return;
    }
    final pin = await bio.unlock();
    if (pin == null || pin.isEmpty || !mounted) return;
    await _submitReal(pin);
  }

  Future<void> _maybeOfferBiometric(String pin) async {
    final bio = ref.read(biometricServiceProvider);
    if (await bio.isEnabled() ||
        await bio.wasPrompted() ||
        !await bio.canUse()) {
      return;
    }
    await bio.markPrompted();
    if (!mounted) return;
    final enable = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Faster sign-in?'),
        content: const Text(
            'Use Face ID / fingerprint to start your shift — no PIN typing. '
            'Your PIN stays encrypted on this phone only.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable')),
        ],
      ),
    );
    if (enable == true) await bio.enable(pin);
  }

  void _cancelPairing() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.palette.surface,
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
    final online = ref.watch(connectionProvider.select((c) => c.online));
    final chipColor = online ? AppColors.success : AppColors.danger;

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.lg),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      constraints.maxHeight - AppSpacing.xl - AppSpacing.lg,
                ),
                child: PageContentClamp(
                  maxWidth: 480,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      AppSurface(
                        borderRadius: const BorderRadius.all(AppRadii.md),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: chipColor.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.wifi_rounded,
                                  color: chipColor, size: 16),
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
                                  Text(
                                      online
                                          ? 'Connected · $deviceLabel'
                                          : 'Reconnecting…',
                                      style: AppTypography.caption
                                          .copyWith(color: chipColor),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: chipColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Hero(
                        tag: HeroTags.appLogo,
                        child: RubberBand(
                            maxDrag: 42,
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
                            )),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Welcome back',
                        style: TextStyle(
                          fontFamily: AppTypography.cormorant,
                          fontWeight: FontWeight.w600,
                          fontSize: 36,
                          height: 1.05,
                          color: context.palette.ink,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Enter your PIN to start the shift',
                        style: AppTypography.caption.copyWith(
                          fontSize: 13,
                          color: context.palette.ink50,
                        ),
                      ),
                      const SizedBox(height: 32),
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
                                    ? Color.lerp(context.palette.ink10,
                                        AppColors.danger, t)!
                                    : Color.lerp(context.palette.ink30,
                                        AppColors.terra500, t)!;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  width: filled ? 18 : 16,
                                  height: filled ? 18 : 16,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: fillColor,
                                    border: Border.all(
                                      color: borderColor,
                                      width: 1.5,
                                    ),
                                  ),
                                );
                              },
                            );
                          }),
                        ),
                      ),
                      const SizedBox(height: 8),
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
                            : _verified
                                ? Padding(
                                    key: const ValueKey('verified'),
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      '✓ Verified',
                                      style: AppTypography.caption.copyWith(
                                        letterSpacing: 0.4,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.success,
                                      ),
                                    ),
                                  )
                                : _submitting
                                    ? Padding(
                                        key: const ValueKey('checking'),
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          '⟳ Checking with the desk…',
                                          style: AppTypography.caption.copyWith(
                                            color: context.palette.ink50,
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
                                            color: context.palette.ink30,
                                          ),
                                        ),
                                      ),
                      ),
                      const SizedBox(height: 24),
                      PinPad(
                        onKeyPress: _press,
                        onForgot: () => showForgotPinDialog(context),
                        onDelete: _delete,
                        enabled: !_submitting,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton.icon(
                            onPressed: _cancelPairing,
                            icon: const Icon(Icons.link_off_rounded, size: 15),
                            label: const Text('Cancel pairing'),
                            style: TextButton.styleFrom(
                              foregroundColor: context.palette.ink50,
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
                              foregroundColor: context.palette.ink50,
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
            ),
          ),
        ),
      ),
    );
  }
}
