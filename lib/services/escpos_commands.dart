/// ESC/POS commands shared by the emergency KOT (escpos_builder.dart) and the
/// gate's entry slips (escpos_slip.dart, ticket_slip_builder.dart).
///
/// Each command is a latin1 string, one character per byte, the way the
/// desk's `electron/printer/escpos.ts` writes them: a ticket is built by
/// joining strings and encoded once at the end, so the KOT stays
/// byte-for-byte what the desk sends.
library;

/// `ESC @`: reset the printer. Every ticket and every slip starts with it.
const String escInit = '\x1B@';

/// `ESC a n`: justification.
const String escAlignLeft = '\x1Ba\x00';
const String escAlignCenter = '\x1Ba\x01';

/// `ESC E n`: emphasis (bold).
const String escBoldOn = '\x1BE\x01';
const String escBoldOff = '\x1BE\x00';

/// `GS ! n`: character size. The high nibble is the width multiplier - 1,
/// the low nibble the height multiplier - 1.
const String escSizeNormal = '\x1D!\x00';
const String escSizeDouble = '\x1D!\x11';

/// `GS ! n` for an even multiplier, width and height both [scale]
/// (1..4, anything else clamped): `n = ((s-1) << 4) | (s-1)`, the desk's
/// `sizeCommand` (scale 1 = 00, 2 = 11, 3 = 22, 4 = 33).
String escSizeScale(int scale) {
  final s = scale.clamp(1, 4) - 1;
  return '\x1D!${String.fromCharCode((s << 4) | s)}';
}

/// `ESC d n`: print the buffer and feed [lines] lines.
String escFeedLines(int lines) =>
    '\x1Bd${String.fromCharCode(lines.clamp(0, 255))}';

/// `GS V 66 0`: feed to the cut position, partial cut.
const String escCutPartial = '\x1DV\x42\x00';

/// The native QR (`GS ( k`, function 165-169), byte for byte the desk's
/// `qrBlock` in `electron/printer/escpos.ts`. Every command is
/// `GS ( k pL pH 31 fn ...`, where `pL + 256*pH` counts the bytes after pH.
///
/// `1D 28 6B 04 00 31 41 32 00`: model 2.
const String escQrModel2 = '\x1D(k\x04\x00\x31\x41\x32\x00';

/// `1D 28 6B 03 00 31 43 NN`: module size in dots (1..16).
String escQrModuleSize(int dots) =>
    '\x1D(k\x03\x00\x31\x43${String.fromCharCode(dots.clamp(1, 16))}';

/// `1D 28 6B 03 00 31 45 31`: error correction M.
const String escQrEccM = '\x1D(k\x03\x00\x31\x45\x31';

/// `1D 28 6B pL pH 31 50 30 <data>`: store [data]; `pL + 256*pH` is
/// `data.length + 3` (the cn, fn and m bytes). [data] must be latin1.
String escQrStore(String data) {
  final length = data.length + 3;
  return '\x1D(k${String.fromCharCode(length & 0xff)}'
      '${String.fromCharCode((length >> 8) & 0xff)}\x31\x50\x30$data';
}

/// `1D 28 6B 03 00 31 51 30`: print the stored symbol.
const String escQrPrint = '\x1D(k\x03\x00\x31\x51\x30';

/// `GS v 0 0 xL xH yL yH`: a raster bit image, normal density, [widthBytes]
/// bytes per row and [heightDots] rows follow (MSB first, 1 = black).
String escRasterHeader(int widthBytes, int heightDots) =>
    '\x1Dv0\x00${String.fromCharCode(widthBytes & 0xff)}'
    '${String.fromCharCode((widthBytes >> 8) & 0xff)}'
    '${String.fromCharCode(heightDots & 0xff)}'
    '${String.fromCharCode((heightDots >> 8) & 0xff)}';
