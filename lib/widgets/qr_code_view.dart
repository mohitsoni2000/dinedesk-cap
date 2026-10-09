import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../theme/tokens.dart';

/// The QR modules for [data] at error correction M (as the printed slips
/// use), or null when it cannot be encoded.
QrImage? qrImageFor(String data) {
  if (data.isEmpty) return null;
  try {
    return QrImage(QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    ));
  } catch (_) {
    return null;
  }
}

/// A QR code on screen: black modules on white with the four-module quiet
/// zone a scanner needs, whatever the theme. The code itself never goes
/// into the semantics label (it admits a guest).
class QrCodeView extends StatefulWidget {
  const QrCodeView({
    super.key,
    required this.data,
    this.size = 220,
    this.semanticLabel = 'Ticket QR code',
  });

  final String data;
  final double size;
  final String semanticLabel;

  @override
  State<QrCodeView> createState() => _QrCodeViewState();
}

class _QrCodeViewState extends State<QrCodeView> {
  late QrImage? _image = qrImageFor(widget.data);

  @override
  void didUpdateWidget(QrCodeView old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) _image = qrImageFor(widget.data);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Semantics(
      label: widget.semanticLabel,
      image: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: image == null
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.hairline),
                ),
                child: const Center(
                  child: Icon(Icons.qr_code_2, color: AppColors.ink30),
                ),
              )
            : CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  static const int _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final count = image.moduleCount + _quiet * 2;
    // Whole logical pixels per module: no seams between neighbours.
    final cell = math.max(1, (size.shortestSide / count).floor()).toDouble();
    final origin = Offset(
      (size.width - cell * count) / 2 + cell * _quiet,
      (size.height - cell * count) / 2 + cell * _quiet,
    );
    final path = Path();
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          path.addRect(Rect.fromLTWH(
              origin.dx + col * cell, origin.dy + row * cell, cell, cell));
        }
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..isAntiAlias = false);
  }

  @override
  bool shouldRepaint(_QrPainter old) => !identical(old.image, image);
}
