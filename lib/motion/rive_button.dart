import 'package:flutter/material.dart';
import 'package:rive/rive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'feedback_kind.dart';
import 'feedback_service.dart';

/// Sealed union of Rive-button visible states.
sealed class RiveButtonPhase {
  const RiveButtonPhase();
}

final class RiveButtonIdle extends RiveButtonPhase {
  const RiveButtonIdle();
}

final class RiveButtonLoading extends RiveButtonPhase {
  const RiveButtonLoading();
}

final class RiveButtonSuccess extends RiveButtonPhase {
  const RiveButtonSuccess();
}

final class RiveButtonError extends RiveButtonPhase {
  const RiveButtonError();
}

/// Wraps a Rive state-machine asset as a stateful button.
/// Parent owns [phase]; this widget renders and binds inputs.
class RiveButton extends ConsumerStatefulWidget {
  const RiveButton({
    required this.assetPath,
    required this.stateMachineName,
    required this.phase,
    required this.onTap,
    this.width = 280,
    this.height = 56,
    this.semanticLabel,
    super.key,
  });

  final String assetPath;
  final String stateMachineName;
  final RiveButtonPhase phase;
  final VoidCallback onTap;
  final double width;
  final double height;
  final String? semanticLabel;

  @override
  ConsumerState<RiveButton> createState() => _RiveButtonState();
}

class _RiveButtonState extends ConsumerState<RiveButton> {
  StateMachineController? _controller;
  SMITrigger? _fireInput;
  SMITrigger? _successInput;
  SMITrigger? _errorInput;
  SMITrigger? _resetInput;

  void _onRiveInit(Artboard artboard) {
    final StateMachineController? controller =
        StateMachineController.fromArtboard(artboard, widget.stateMachineName);
    if (controller == null) {
      assert(
          false, 'Rive state machine "${widget.stateMachineName}" not found.');
      return;
    }
    artboard.addController(controller);
    _controller = controller;
    // Rive API requires cast from SMIInput<bool> to SMITrigger — mathematically safe.
    _fireInput = controller.findInput<bool>('fire') as SMITrigger?;
    _successInput = controller.findInput<bool>('success') as SMITrigger?;
    _errorInput = controller.findInput<bool>('error') as SMITrigger?;
    _resetInput = controller.findInput<bool>('reset') as SMITrigger?;
    _syncPhase();
  }

  @override
  void didUpdateWidget(covariant RiveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) {
      _syncPhase();
    }
  }

  void _syncPhase() {
    switch (widget.phase) {
      case RiveButtonIdle():
        _resetInput?.fire();
      case RiveButtonLoading():
        _fireInput?.fire();
      case RiveButtonSuccess():
        _successInput?.fire();
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
      case RiveButtonError():
        _errorInput?.fire();
        ref.read(feedbackServiceProvider).fire(const FeedbackError());
    }
  }

  bool get _canTap =>
      widget.phase is RiveButtonIdle || widget.phase is RiveButtonError;

  void _handleTap() {
    if (!_canTap) return;
    ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
    widget.onTap();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel ?? 'Send to kitchen',
      button: true,
      child: GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: RiveAnimation.asset(
            widget.assetPath,
            stateMachines: <String>[widget.stateMachineName],
            onInit: _onRiveInit,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
