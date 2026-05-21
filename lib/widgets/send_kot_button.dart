import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../motion/motion.dart';

class SendKotButton extends ConsumerStatefulWidget {
  const SendKotButton({
    required this.controller,
    required this.onFire,
    super.key,
  });

  final SendKotButtonController controller;
  final Future<void> Function() onFire;

  @override
  ConsumerState<SendKotButton> createState() => _SendKotButtonState();
}

class _SendKotButtonState extends ConsumerState<SendKotButton> {
  RiveButtonPhase _phase = const RiveButtonIdle();

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
  }

  @override
  void dispose() {
    widget.controller._detach();
    super.dispose();
  }

  void _setPhase(RiveButtonPhase phase) {
    setState(() {
      _phase = phase;
    });
  }

  Future<void> _onTap() async {
    if (_phase is! RiveButtonIdle && _phase is! RiveButtonError) return;
    _setPhase(const RiveButtonLoading());
    try {
      await widget.onFire();
    } catch (_) {
      _setPhase(const RiveButtonError());
    }
  }

  @override
  Widget build(BuildContext context) {
    return RiveButton(
      assetPath: 'assets/rive/send_kot_button.riv',
      stateMachineName: 'Main',
      phase: _phase,
      onTap: _onTap,
      semanticLabel: switch (_phase) {
        RiveButtonIdle() => 'Send to kitchen',
        RiveButtonLoading() => 'Sending to kitchen',
        RiveButtonSuccess() => 'Sent to kitchen',
        RiveButtonError() => 'Retry send to kitchen',
      },
    );
  }
}

class SendKotButtonController {
  _SendKotButtonState? _state;

  void _attach(_SendKotButtonState s) {
    _state = s;
  }

  void _detach() {
    _state = null;
  }

  void confirmSuccess() {
    _state?._setPhase(const RiveButtonSuccess());
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      _state?._setPhase(const RiveButtonIdle());
    });
  }

  void confirmError() {
    _state?._setPhase(const RiveButtonError());
  }

  void reset() {
    _state?._setPhase(const RiveButtonIdle());
  }
}
