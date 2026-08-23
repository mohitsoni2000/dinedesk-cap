import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum ToastKind { info, success, error, warning }

class DynamicToast {
  DynamicToast._();

  static OverlayEntry? _entry;
  static GlobalKey<_DynamicIslandToastState>? _stateKey;

  static void show(
    BuildContext context, {
    required String message,
    ToastKind kind = ToastKind.info,
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _removeCurrent();

    final overlay = Overlay.of(context, rootOverlay: true);
    final stateKey = GlobalKey<_DynamicIslandToastState>();
    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _DynamicIslandToastView(
        key: stateKey,
        message: message,
        kind: kind,
        duration: duration,
        actionLabel: actionLabel,
        onAction: onAction,
        onDismissed: () {
          entry.remove();
          if (_entry == entry) {
            _entry = null;
            _stateKey = null;
          }
        },
      ),
    );

    _entry = entry;
    _stateKey = stateKey;
    overlay.insert(entry);
  }

  static void _removeCurrent() {
    _stateKey?.currentState?.dismissNow();
    _entry = null;
    _stateKey = null;
  }

  static void success(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 3)}) =>
      show(context,
          message: message, kind: ToastKind.success, duration: duration);

  static void error(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 4)}) =>
      show(context,
          message: message, kind: ToastKind.error, duration: duration);

  static void warning(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 3)}) =>
      show(context,
          message: message, kind: ToastKind.warning, duration: duration);
}

class _DynamicIslandToastView extends StatefulWidget {
  final String message;
  final ToastKind kind;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismissed;

  const _DynamicIslandToastView({
    super.key,
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_DynamicIslandToastView> createState() => _DynamicIslandToastState();
}

class _DynamicIslandToastState extends State<_DynamicIslandToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  Timer? _autoDismiss;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _scale = CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeIn)
        .drive(Tween(begin: 0.4, end: 1.0));
    _opacity = CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.5),
        reverseCurve: Curves.easeOut);
    _slide = CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeIn)
        .drive(Tween(begin: const Offset(0, -0.5), end: Offset.zero));

    _controller.forward();
    _autoDismiss = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _autoDismiss?.cancel();
    await _controller.reverse();
    widget.onDismissed();
  }

  void dismissNow() {
    _dismissing = true;
    _autoDismiss?.cancel();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _controller.dispose();
    super.dispose();
  }

  _ToastVisuals get _visuals => switch (widget.kind) {
        ToastKind.success =>
          const _ToastVisuals(Icons.check_circle_rounded, AppColors.success),
        ToastKind.error =>
          const _ToastVisuals(Icons.error_rounded, AppColors.danger),
        ToastKind.warning =>
          const _ToastVisuals(Icons.warning_rounded, AppColors.warn),
        ToastKind.info => const _ToastVisuals(
            Icons.circle_notifications_rounded, AppColors.terra400),
      };

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final visuals = _visuals;

    return Positioned(
      top: topInset + 10,
      left: 0,
      right: 0,
      child: Material(
        type: MaterialType.transparency,
        child: Center(
          child: SlideTransition(
            position: _slide,
            child: ScaleTransition(
              scale: _scale,
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: _opacity,
                child: GestureDetector(
                  onTap: _dismiss,
                  behavior: HitTestBehavior.opaque,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.9,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.night,
                        borderRadius: const BorderRadius.all(AppRadii.pill),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08)),
                        boxShadow: AppShadows.flat,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(visuals.icon, color: visuals.accent, size: 18),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              widget.message,
                              style: AppTypography.bodyMd
                                  .copyWith(color: Colors.white),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (widget.actionLabel != null &&
                              widget.onAction != null) ...[
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: () {
                                widget.onAction!();
                                _dismiss();
                              },
                              child: Text(
                                widget.actionLabel!.toUpperCase(),
                                style: AppTypography.bodyMd.copyWith(
                                  color: AppColors.terra400,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
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

class _ToastVisuals {
  final IconData icon;
  final Color accent;
  const _ToastVisuals(this.icon, this.accent);
}
