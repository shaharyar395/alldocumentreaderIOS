import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import 'pdf_tools.dart';

// ---------------------------------------------------------------------------------------------
// Paper sizes (Create PDF, Manage pages → Insert blank pages)
// ---------------------------------------------------------------------------------------------

enum PaperSize { a5, a4, a3, b5, b4, letter, legal }

PdfPageFormat paperBase(PaperSize size) {
  return switch (size) {
    PaperSize.a5 => PdfPageFormat.a5,
    PaperSize.a4 => PdfPageFormat.a4,
    PaperSize.a3 => PdfPageFormat.a3,
    PaperSize.b5 => const PdfPageFormat(176 * PdfPageFormat.mm, 250 * PdfPageFormat.mm),
    PaperSize.b4 => const PdfPageFormat(250 * PdfPageFormat.mm, 353 * PdfPageFormat.mm),
    PaperSize.letter => PdfPageFormat.letter,
    PaperSize.legal => PdfPageFormat.legal,
  };
}

String paperLabel(PaperSize size) {
  return switch (size) {
    PaperSize.a5 => 'A5',
    PaperSize.a4 => 'A4',
    PaperSize.a3 => 'A3',
    PaperSize.b5 => 'B5',
    PaperSize.b4 => 'B4',
    PaperSize.letter => 'Letter',
    PaperSize.legal => 'Legal',
  };
}

PdfPageFormat paperFormat(PaperSize size, {required bool landscape}) {
  return orientFormat(paperBase(size), landscape: landscape);
}

/// [format] turned to portrait or landscape, without margins.
PdfPageFormat orientFormat(PdfPageFormat format, {required bool landscape}) {
  final short = math.min(format.width, format.height);
  final long = math.max(format.width, format.height);
  return landscape ? PdfPageFormat(long, short) : PdfPageFormat(short, long);
}

(int, int) paperPixels(PaperSize size, {required bool landscape}) {
  final format = paperFormat(size, landscape: landscape);
  return (format.width.round(), format.height.round());
}

/// A small picture of a blank page in [style] (preview of new blank pages), [width] × [height] px.
Uint8List renderPaperSized({
  required int width,
  required int height,
  required BlankStyle style,
  int background = 0xFFFFFF,
}) {
  final image = img.Image(width: math.max(8, width), height: math.max(8, height));
  img.fill(image, color: _rgb(background));
  final w = image.width;
  final h = image.height;
  final unit = w / 595.0;
  final ink = img.ColorRgb8(176, 196, 216);
  final strong = img.ColorRgb8(140, 164, 190);
  final margin = img.ColorRgb8(214, 96, 96);
  if (style == BlankStyle.blank) {
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }
  if (style == BlankStyle.grid || style == BlankStyle.graph) {
    final step = math.max(3, ((style == BlankStyle.graph ? 18 : 36) * unit).round());
    for (var x = 0; x < w; x += step) {
      final color = style == BlankStyle.graph && (x ~/ step) % 5 == 0 ? strong : ink;
      img.drawLine(image, x1: x, y1: 0, x2: x, y2: h - 1, color: color);
    }
    for (var y = 0; y < h; y += step) {
      final color = style == BlankStyle.graph && (y ~/ step) % 5 == 0 ? strong : ink;
      img.drawLine(image, x1: 0, y1: y, x2: w - 1, y2: y, color: color);
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }
  final left = style == BlankStyle.cornell ? (w * 0.28).round() : ((style == BlankStyle.notebook ? 56 : 28) * unit).round();
  final step = math.max(3, (28 * unit).round());
  for (var y = (48 * unit).round(); y < h - (36 * unit).round(); y += step) {
    img.drawLine(image, x1: left, y1: y, x2: w - (24 * unit).round(), y2: y, color: ink);
  }
  if (style == BlankStyle.notebook || style == BlankStyle.cornell) {
    final x = left - (10 * unit).round();
    img.drawLine(image, x1: x, y1: (20 * unit).round(), x2: x, y2: h - (20 * unit).round(), color: margin, thickness: 2);
  }
  if (style == BlankStyle.cornell) {
    final split = (h * 0.82).round();
    img.drawLine(image, x1: (20 * unit).round(), y1: split, x2: w - (20 * unit).round(), y2: split, color: strong, thickness: 2);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

Uint8List renderPaper({
  required PaperSize size,
  required bool landscape,
  required BlankStyle style,
  int background = 0xFFFFFF,
}) {
  final (width, height) = paperPixels(size, landscape: landscape);
  return renderPaperSized(width: width, height: height, style: style, background: background);
}

img.Color _rgb(int value) => img.ColorRgb8((value >> 16) & 255, (value >> 8) & 255, value & 255);

/// Turns a JPEG / PNG by [quarterTurns] × 90° clockwise.
Future<Uint8List> rotateImageBytes(Uint8List bytes, {int quarterTurns = 1}) async {
  return Isolate.run(() {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final rotated = img.copyRotate(img.bakeOrientation(decoded), angle: 90.0 * quarterTurns);
    return Uint8List.fromList(img.encodeJpg(rotated, quality: 90));
  });
}

// ---------------------------------------------------------------------------------------------
// Scan pipeline (port of the Android app's ImageOps): upright decode → perspective crop →
// rotation → look filter.
// ---------------------------------------------------------------------------------------------

const int previewPx = 1400;
const int finalPx = 2200;
const int thumbPx = 240;

/// Look filters offered under the page in the scan editor, in the original app's order.
enum ScanFilter { original, auto, docs, color, image, superClear, enhance, enhance2, bw, bw2, gray, invert }

/// Pixels as 0xFFRRGGBB (always opaque).
class PixelBuf {
  PixelBuf(this.width, this.height, this.px);

  final int width;
  final int height;
  final Uint32List px;

  PixelBuf copy() => PixelBuf(width, height, Uint32List.fromList(px));
}

/// TL, TR, BR, BL corners as 0..1 fractions = the whole picture.
const List<double> fullQuad = [0, 0, 1, 0, 1, 1, 0, 1];

bool isFullQuad(List<double> q) {
  for (var i = 0; i < 8; i++) {
    if ((q[i] - fullQuad[i]).abs() >= 0.004) return false;
  }
  return true;
}

/// Maps crop corners of the upright source into the picture as shown after [rotation] (clockwise).
List<double> rotateQuad(List<double> q, int rotation) {
  var r = List<double>.of(q);
  final turns = (((rotation % 360) + 360) % 360) ~/ 90;
  for (var t = 0; t < turns; t++) {
    final n = List<double>.filled(8, 0);
    // 90° clockwise: (x, y) → (1 - y, x); the corner order shifts by one
    for (var i = 0; i < 4; i++) {
      final x = r[i * 2];
      final y = r[i * 2 + 1];
      final j = (i + 1) % 4;
      n[j * 2] = 1 - y;
      n[j * 2 + 1] = x;
    }
    r = n;
  }
  return r;
}

List<double> unrotateQuad(List<double> q, int rotation) => rotateQuad(q, 360 - (((rotation % 360) + 360) % 360));

/// Decodes the picture at [path] with the platform decoder (fast, EXIF orientation applied), no
/// larger than [maxPx] on its long side. Transparent pictures are put on white.
Future<PixelBuf?> loadPixels(String path, int maxPx) async {
  try {
    final bytes = await File(path).readAsBytes();
    return await decodePixels(bytes, maxPx);
  } catch (_) {
    return null;
  }
}

Future<PixelBuf?> decodePixels(Uint8List bytes, int maxPx) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int width, int height) {
        final long = math.max(width, height);
        if (long <= maxPx) return ui.TargetImageSize(width: width, height: height);
        // only one side is given, so the proportions stay right whatever the orientation is
        return width >= height ? ui.TargetImageSize(width: maxPx) : ui.TargetImageSize(height: maxPx);
      },
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    final height = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final buf = await Isolate.run(() => _fromRgba(rgba, width, height));
    if (math.max(buf.width, buf.height) > maxPx * 1.05) {
      return await Isolate.run(() => scaleToMax(buf, maxPx));
    }
    return buf;
  } catch (_) {
    // the image package as a fallback (slower; EXIF applied with bakeOrientation)
    try {
      return await Isolate.run(() {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;
        var upright = img.bakeOrientation(decoded);
        final long = math.max(upright.width, upright.height);
        if (long > maxPx) {
          upright = upright.width >= upright.height
              ? img.copyResize(upright, width: maxPx, interpolation: img.Interpolation.average)
              : img.copyResize(upright, height: maxPx, interpolation: img.Interpolation.average);
        }
        return fromImage(upright);
      });
    } catch (_) {
      return null;
    }
  }
}

PixelBuf _fromRgba(Uint8List rgba, int width, int height) {
  final n = width * height;
  final px = Uint32List(n);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    var r = rgba[o];
    var g = rgba[o + 1];
    var b = rgba[o + 2];
    final a = rgba[o + 3];
    if (a < 255) {
      // premultiplied or not, putting it on white is close enough for pages
      r = 255 - (((255 - r) * a) ~/ 255);
      g = 255 - (((255 - g) * a) ~/ 255);
      b = 255 - (((255 - b) * a) ~/ 255);
    }
    px[i] = 0xFF000000 | (r << 16) | (g << 8) | b;
  }
  return PixelBuf(width, height, px);
}

/// Pixels of an image package [img.Image] (put on white when it has transparency).
PixelBuf fromImage(img.Image source) {
  final w = source.width;
  final h = source.height;
  final px = Uint32List(w * h);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = source.getPixel(x, y);
      var r = p.rNormalized * 255;
      var g = p.gNormalized * 255;
      var b = p.bNormalized * 255;
      if (source.hasAlpha) {
        final a = p.aNormalized;
        r = 255 - (255 - r) * a;
        g = 255 - (255 - g) * a;
        b = 255 - (255 - b) * a;
      }
      px[i++] = 0xFF000000 | (_c(r.round()) << 16) | (_c(g.round()) << 8) | _c(b.round());
    }
  }
  return PixelBuf(w, h, px);
}

/// JPEG of raw RGBA pixels (e.g. from a ui.Image), made in the background.
Future<Uint8List> rgbaToJpeg(Uint8List rgba, int width, int height, {int quality = 90}) =>
    Isolate.run(() => encodeJpeg(_fromRgba(rgba, width, height), quality: quality));

/// JPEG bytes of [buf], made in the background.
Future<Uint8List> jpegOf(PixelBuf buf, {int quality = 90}) => Isolate.run(() => encodeJpeg(buf, quality: quality));

/// JPEG bytes of [buf].
Uint8List encodeJpeg(PixelBuf buf, {int quality = 90}) {
  final n = buf.width * buf.height;
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    final c = buf.px[i];
    rgb[i * 3] = (c >> 16) & 0xFF;
    rgb[i * 3 + 1] = (c >> 8) & 0xFF;
    rgb[i * 3 + 2] = c & 0xFF;
  }
  final image = img.Image.fromBytes(width: buf.width, height: buf.height, bytes: rgb.buffer, numChannels: 3);
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

int _c(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int _rgbInt(int r, int g, int b) => 0xFF000000 | (_c(r) << 16) | (_c(g) << 8) | _c(b);

/// Area-average (shrinking) / bilinear (growing) resize to exactly [w] × [h].
PixelBuf resizeExact(PixelBuf src, int w, int h) {
  if (w == src.width && h == src.height) return src.copy();
  final out = Uint32List(w * h);
  final sx = src.width / w;
  final sy = src.height / h;
  if (sx >= 1 && sy >= 1) {
    for (var y = 0; y < h; y++) {
      final y0 = (y * sy).floor();
      final y1 = math.max(y0 + 1, math.min(src.height, ((y + 1) * sy).floor()));
      for (var x = 0; x < w; x++) {
        final x0 = (x * sx).floor();
        final x1 = math.max(x0 + 1, math.min(src.width, ((x + 1) * sx).floor()));
        var r = 0;
        var g = 0;
        var b = 0;
        var count = 0;
        for (var yy = y0; yy < y1; yy++) {
          final row = yy * src.width;
          for (var xx = x0; xx < x1; xx++) {
            final c = src.px[row + xx];
            r += (c >> 16) & 0xFF;
            g += (c >> 8) & 0xFF;
            b += c & 0xFF;
            count++;
          }
        }
        out[y * w + x] = _rgbInt(r ~/ count, g ~/ count, b ~/ count);
      }
    }
    return PixelBuf(w, h, out);
  }
  for (var y = 0; y < h; y++) {
    final fy = math.max(0.0, (y + 0.5) * sy - 0.5);
    for (var x = 0; x < w; x++) {
      final fx = math.max(0.0, (x + 0.5) * sx - 0.5);
      out[y * w + x] = _bilinear(src, fx, fy);
    }
  }
  return PixelBuf(w, h, out);
}

PixelBuf scaleToMax(PixelBuf src, int maxPx) {
  final long = math.max(src.width, src.height);
  if (long <= maxPx) return src;
  final s = maxPx / long;
  return resizeExact(src, math.max(1, (src.width * s).round()), math.max(1, (src.height * s).round()));
}

int _bilinear(PixelBuf src, double fx, double fy) {
  final x0 = math.min(src.width - 1, fx.floor());
  final y0 = math.min(src.height - 1, fy.floor());
  final x1 = math.min(src.width - 1, x0 + 1);
  final y1 = math.min(src.height - 1, y0 + 1);
  final tx = fx - x0;
  final ty = fy - y0;
  final c00 = src.px[y0 * src.width + x0];
  final c01 = src.px[y0 * src.width + x1];
  final c10 = src.px[y1 * src.width + x0];
  final c11 = src.px[y1 * src.width + x1];
  int ch(int shift) {
    final a = (c00 >> shift) & 0xFF;
    final b = (c01 >> shift) & 0xFF;
    final c = (c10 >> shift) & 0xFF;
    final d = (c11 >> shift) & 0xFF;
    final top = a + (b - a) * tx;
    final bottom = c + (d - c) * tx;
    return (top + (bottom - top) * ty).round();
  }

  return _rgbInt(ch(16), ch(8), ch(0));
}

PixelBuf rotateBuf(PixelBuf src, int degrees) {
  final d = ((degrees % 360) + 360) % 360;
  if (d == 0) return src;
  final w = src.width;
  final h = src.height;
  if (d == 180) {
    final out = Uint32List(w * h);
    for (var i = 0; i < w * h; i++) {
      out[w * h - 1 - i] = src.px[i];
    }
    return PixelBuf(w, h, out);
  }
  // 90 / 270: width and height swap
  final out = Uint32List(w * h);
  final nw = h;
  final nh = w;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = src.px[y * w + x];
      if (d == 90) {
        // clockwise: (x, y) → (h - 1 - y, x)
        out[x * nw + (h - 1 - y)] = c;
      } else {
        // counter-clockwise: (x, y) → (y, w - 1 - x)
        out[(w - 1 - x) * nw + y] = c;
      }
    }
  }
  return PixelBuf(nw, nh, out);
}

/// Straightens the quadrilateral [q] (TL, TR, BR, BL fractions) into a rectangle.
PixelBuf warpQuad(PixelBuf src, List<double> q) {
  final w = src.width.toDouble();
  final h = src.height.toDouble();
  final p = [for (var i = 0; i < 8; i++) q[i] * (i.isEven ? w : h)];
  double dist(int a, int b) => math.sqrt(math.pow(p[b * 2] - p[a * 2], 2) + math.pow(p[b * 2 + 1] - p[a * 2 + 1], 2));
  final top = dist(0, 1);
  final bottom = dist(3, 2);
  final left = dist(0, 3);
  final right = dist(1, 2);
  final ow = math.max(top, bottom).round().clamp(8, 6000);
  final oh = math.max(left, right).round().clamp(8, 6000);
  // homography from the output rectangle to the source quad
  final m = _homography(
    [0, 0, ow.toDouble(), 0, ow.toDouble(), oh.toDouble(), 0, oh.toDouble()],
    p,
  );
  if (m == null) return src;
  final out = Uint32List(ow * oh);
  for (var y = 0; y < oh; y++) {
    final yy = y + 0.5;
    for (var x = 0; x < ow; x++) {
      final xx = x + 0.5;
      final den = m[6] * xx + m[7] * yy + 1;
      final sx = (m[0] * xx + m[1] * yy + m[2]) / den - 0.5;
      final sy = (m[3] * xx + m[4] * yy + m[5]) / den - 0.5;
      if (sx < -1 || sy < -1 || sx > w || sy > h) {
        out[y * ow + x] = 0xFFFFFFFF;
      } else {
        out[y * ow + x] = _bilinear(src, sx.clamp(0, w - 1).toDouble(), sy.clamp(0, h - 1).toDouble());
      }
    }
  }
  return PixelBuf(ow, oh, out);
}

/// 3×3 projective matrix (a..h, i = 1) mapping the 4 points [from] onto [to].
List<double>? _homography(List<double> from, List<double> to) {
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final x = from[i * 2];
    final y = from[i * 2 + 1];
    final u = to[i * 2];
    final v = to[i * 2 + 1];
    a[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
    a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
  }
  // Gauss-Jordan with partial pivoting
  for (var col = 0; col < 8; col++) {
    var pivot = col;
    for (var r = col + 1; r < 8; r++) {
      if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
    }
    if (a[pivot][col].abs() < 1e-12) return null;
    final tmp = a[col];
    a[col] = a[pivot];
    a[pivot] = tmp;
    final div = a[col][col];
    for (var k = col; k < 9; k++) {
      a[col][k] /= div;
    }
    for (var r = 0; r < 8; r++) {
      if (r == col) continue;
      final f = a[r][col];
      if (f == 0) continue;
      for (var k = col; k < 9; k++) {
        a[r][k] -= f * a[col][k];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) a[i][8]];
}

/// The finished page: upright source → crop → rotation → filter, as a JPEG.
Uint8List renderScanPage(PixelBuf source, {List<double>? quad, int rotation = 0, ScanFilter filter = ScanFilter.auto, int quality = 88}) {
  var buf = source;
  if (quad != null && !isFullQuad(quad)) buf = warpQuad(buf, quad);
  buf = rotateBuf(buf, rotation);
  buf = applyScanFilter(buf, filter);
  return encodeJpeg(buf, quality: quality);
}

/// Small previews of one page in every filter, in [ScanFilter] order.
List<Uint8List> renderFilterThumbs(PixelBuf source, {List<double>? quad, int rotation = 0, int maxPx = thumbPx}) {
  var buf = scaleToMax(source, math.max(maxPx * 2, 400));
  if (quad != null && !isFullQuad(quad)) buf = warpQuad(buf, quad);
  buf = scaleToMax(rotateBuf(buf, rotation), maxPx);
  return [for (final f in ScanFilter.values) encodeJpeg(applyScanFilter(buf, f), quality: 80)];
}

// ------------------------------------------------------------------ document detection

/// Finds a document (sheet of paper, receipt, card…) in the picture and returns its corners
/// TL, TR, BR, BL as fractions, or null if nothing clear stands out.
///
/// The page is assumed to cover the middle of the picture. On a small copy, four "paper"
/// measures are built (brightness, whiteness, coolness and a mix), each with the text wiped out
/// by a closing filter. For each measure and several tolerances the region like the middle is
/// grown, its holes filled and the largest 4-corner shape inside its outline taken. Candidates
/// are scored by how well their sides sit on real edges and how much they stand out; the best
/// one then has each side snapped onto the page's edge.
List<double>? detectDocument(PixelBuf src) {
  final scale = 360 / math.max(src.width, src.height);
  final w = math.max(16, (src.width * scale).round());
  final h = math.max(16, (src.height * scale).round());
  final small = resizeExact(src, w, h);
  final n = w * h;
  final lum = Int32List(n);
  final white = Int32List(n);
  final cool = Int32List(n);
  final mix = Int32List(n);
  for (var i = 0; i < n; i++) {
    final c = small.px[i];
    final r = (c >> 16) & 0xFF;
    final g = (c >> 8) & 0xFF;
    final b = c & 0xFF;
    final l = (r * 299 + g * 587 + b * 114) ~/ 1000;
    final sat = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    lum[i] = l;
    white[i] = (l - 2 * sat).clamp(0, 255).toInt();
    cool[i] = (128 + 3 * (b - r)).clamp(0, 255).toInt();
    mix[i] = (l + 2 * (b - r)).clamp(0, 255).toInt();
  }
  final feats = <Int32List>[];
  for (final f in [lum, white, cool, mix]) {
    var c = f;
    for (var k = 0; k < 3; k++) {
      c = _minMax(c, w, h, true); // closing: removes dark text / lines
    }
    for (var k = 0; k < 3; k++) {
      c = _minMax(c, w, h, false);
    }
    feats.add(_boxBlur(_boxBlur(c, w, h), w, h));
  }
  final grad = Int32List(n);
  for (final f in feats) {
    final g = _gradient(f, w, h);
    for (var i = 0; i < n; i++) {
      if (g[i] > grad[i]) grad[i] = g[i];
    }
  }
  final sortedGrad = Int32List.fromList(grad)..sort();
  final gThr = sortedGrad[(n * 0.85).toInt().clamp(0, n - 1)].toDouble();

  final cy0 = (h * 0.4).toInt();
  final cy1 = (h * 0.6).toInt();
  final cx0 = (w * 0.4).toInt();
  final cx1 = (w * 0.6).toInt();
  List<double>? best;
  var bestScore = -1.0;
  var bestSupport = 0.0;
  var bestContrast = 0.0;
  for (final f in feats) {
    final centre = <int>[];
    for (var y = cy0; y < cy1; y++) {
      for (var x = cx0; x < cx1; x++) {
        centre.add(f[y * w + x]);
      }
    }
    if (centre.isEmpty) continue;
    centre.sort();
    final v = centre[centre.length ~/ 2];
    for (final delta in const [8, 14, 20, 28, 36, 46, 58, 72]) {
      final t = v - delta;
      final region = _growFrom(f, w, h, t, v, cx0, cx1, cy0, cy1);
      if (region == null) continue;
      var count = 0;
      for (final bit in region) {
        if (bit != 0) count++;
      }
      if (count < n * 0.08 || count > n * 0.96) continue;
      final filled = _fillHoles(region, w, h);
      var filledCount = 0;
      for (final bit in filled) {
        if (bit != 0) filledCount++;
      }
      final q = _maxQuad(_hullOf(filled, w, h));
      if (q == null) continue;
      final area = _polyArea(q) / n;
      if (area < 0.08 || area > 0.97) continue;
      if (filledCount / n / area < 0.88 || !_goodShape(q)) continue;
      final (support, border) = _sideSupport(q, grad, w, h, gThr);
      final contrast = _contrast(f, filled, w, h);
      final score = support + math.min(contrast, 40.0) / 80.0 + 0.2 * area - 0.15 * border;
      if (score > bestScore) {
        bestScore = score;
        best = q;
        bestSupport = support;
        bestContrast = contrast;
      }
    }
  }
  final q = best;
  if (q == null) return null;
  // sure enough: its sides sit on real edges, or it clearly stands out from what is around it
  if (bestSupport < 0.45 && !(bestContrast >= 40 && bestSupport >= 0.33)) return null;
  final r = _refineSides(q, grad, w, h);
  return [
    for (var i = 0; i < 8; i++) i.isEven ? ((r[i] + 0.5) / w).clamp(0.0, 1.0) : ((r[i] + 0.5) / h).clamp(0.0, 1.0),
  ];
}

/// 3×3 maximum (or minimum) filter.
Int32List _minMax(Int32List a, int w, int h, bool max) {
  final out = Int32List(a.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = max ? -1 << 30 : 1 << 30;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -1; dx <= 1; dx++) {
          final c = a[yy * w + (x + dx).clamp(0, w - 1)];
          if (max ? c > v : c < v) v = c;
        }
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

Int32List _gradient(Int32List a, int w, int h) {
  final g = Int32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      // Sobel
      final gx = (a[i - w + 1] + 2 * a[i + 1] + a[i + w + 1]) - (a[i - w - 1] + 2 * a[i - 1] + a[i + w - 1]);
      final gy = (a[i + w - 1] + 2 * a[i + w] + a[i + w + 1]) - (a[i - w - 1] + 2 * a[i - w] + a[i - w + 1]);
      g[i] = gx.abs() + gy.abs();
    }
  }
  return g;
}

Int32List _boxBlur(Int32List a, int w, int h) {
  final out = Int32List(a.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0;
      var count = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          s += a[yy * w + xx];
          count++;
        }
      }
      out[y * w + x] = s ~/ count;
    }
  }
  return out;
}

/// Region of pixels ≥ [t] connected to the bright part (≥ [v]) of the central box.
Uint8List? _growFrom(Int32List f, int w, int h, int t, int v, int cx0, int cx1, int cy0, int cy1) {
  final seen = Uint8List(w * h);
  final stack = Int32List(w * h);
  var sp = 0;
  for (var y = cy0; y < cy1; y++) {
    for (var x = cx0; x < cx1; x++) {
      final i = y * w + x;
      if (f[i] >= v && seen[i] == 0) {
        seen[i] = 1;
        stack[sp++] = i;
      }
    }
  }
  if (sp == 0) return null;
  while (sp > 0) {
    final i = stack[--sp];
    final x = i % w;
    final y = i ~/ w;
    if (x > 0) {
      final j = i - 1;
      if (seen[j] == 0 && f[j] >= t) {
        seen[j] = 1;
        stack[sp++] = j;
      }
    }
    if (x < w - 1) {
      final j = i + 1;
      if (seen[j] == 0 && f[j] >= t) {
        seen[j] = 1;
        stack[sp++] = j;
      }
    }
    if (y > 0) {
      final j = i - w;
      if (seen[j] == 0 && f[j] >= t) {
        seen[j] = 1;
        stack[sp++] = j;
      }
    }
    if (y < h - 1) {
      final j = i + w;
      if (seen[j] == 0 && f[j] >= t) {
        seen[j] = 1;
        stack[sp++] = j;
      }
    }
  }
  return seen;
}

/// The region plus every hole inside it (words, shadows, logos on the page).
Uint8List _fillHoles(Uint8List m, int w, int h) {
  final outside = Uint8List(m.length);
  final stack = Int32List(m.length);
  var sp = 0;
  void push(int i) {
    if (m[i] == 0 && outside[i] == 0) {
      outside[i] = 1;
      stack[sp++] = i;
    }
  }

  for (var x = 0; x < w; x++) {
    push(x);
    push((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    push(y * w);
    push(y * w + w - 1);
  }
  while (sp > 0) {
    final i = stack[--sp];
    final x = i % w;
    final y = i ~/ w;
    if (x > 0) push(i - 1);
    if (x < w - 1) push(i + 1);
    if (y > 0) push(i - w);
    if (y < h - 1) push(i + w);
  }
  final out = Uint8List(m.length);
  for (var i = 0; i < m.length; i++) {
    out[i] = outside[i] == 0 ? 1 : 0;
  }
  return out;
}

/// Convex hull (x, y pairs) of the region, from its row ends.
List<double> _hullOf(Uint8List m, int w, int h) {
  final pts = <int>[];
  for (var y = 0; y < h; y++) {
    var first = -1;
    var last = -1;
    for (var x = 0; x < w; x++) {
      if (m[y * w + x] != 0) {
        if (first < 0) first = x;
        last = x;
      }
    }
    if (first >= 0) {
      pts.add((first << 32) | y);
      if (last != first) pts.add((last << 32) | y);
    }
  }
  pts.sort();
  if (pts.length < 3) return const [];
  double px(int p) => (p >> 32).toDouble();
  double py(int p) => (p & 0xFFFFFFFF).toDouble();
  double cross(int o, int a, int b) => (px(a) - px(o)) * (py(b) - py(o)) - (py(a) - py(o)) * (px(b) - px(o));
  final hull = <int>[];
  for (final p in pts) {
    while (hull.length >= 2 && cross(hull[hull.length - 2], hull[hull.length - 1], p) <= 0) {
      hull.removeLast();
    }
    hull.add(p);
  }
  final lower = hull.length + 1;
  for (var i = pts.length - 2; i >= 0; i--) {
    final p = pts[i];
    while (hull.length >= lower && cross(hull[hull.length - 2], hull[hull.length - 1], p) <= 0) {
      hull.removeLast();
    }
    hull.add(p);
  }
  hull.removeLast();
  return [
    for (final p in hull) ...[px(p), py(p)],
  ];
}

/// Largest 4-corner shape with its corners on the hull, as TL, TR, BR, BL (pixels).
List<double>? _maxQuad(List<double> hull) {
  final m = hull.length ~/ 2;
  if (m < 4) return null;
  double area(List<int> idx) {
    var a = 0.0;
    for (var k = 0; k < 4; k++) {
      final i = idx[k];
      final j = idx[(k + 1) % 4];
      a += hull[i * 2] * hull[j * 2 + 1] - hull[j * 2] * hull[i * 2 + 1];
    }
    return a.abs() / 2;
  }

  var idx = [0, m ~/ 4, m ~/ 2, 3 * m ~/ 4];
  var best = area(idx);
  var improved = true;
  var rounds = 0;
  while (improved && rounds++ < 50) {
    improved = false;
    for (var k = 0; k < 4; k++) {
      final a = idx[(k + 3) % 4];
      final b = idx[(k + 1) % 4];
      var j = (a + 1) % m;
      while (j != b) {
        final cand = List<int>.of(idx);
        cand[k] = j;
        final ar = area(cand);
        if (ar > best + 1e-4) {
          best = ar;
          idx = cand;
          improved = true;
        }
        j = (j + 1) % m;
      }
    }
  }
  // order TL, TR, BR, BL (clockwise on screen, starting at the smallest x + y)
  final cx = idx.fold<double>(0, (s, i) => s + hull[i * 2]) / 4;
  final cy = idx.fold<double>(0, (s, i) => s + hull[i * 2 + 1]) / 4;
  final sorted = List<int>.of(idx)..sort((a, b) => math.atan2(hull[a * 2 + 1] - cy, hull[a * 2] - cx).compareTo(math.atan2(hull[b * 2 + 1] - cy, hull[b * 2] - cx)));
  var start = 0;
  for (var i = 1; i < 4; i++) {
    if (hull[sorted[i] * 2] + hull[sorted[i] * 2 + 1] < hull[sorted[start] * 2] + hull[sorted[start] * 2 + 1]) start = i;
  }
  return [
    for (var i = 0; i < 8; i++) i.isEven ? hull[sorted[(start + i ~/ 2) % 4] * 2] : hull[sorted[(start + i ~/ 2) % 4] * 2 + 1],
  ];
}

double _polyArea(List<double> q) {
  var a = 0.0;
  for (var i = 0; i < 4; i++) {
    final j = (i + 1) % 4;
    a += q[i * 2] * q[j * 2 + 1] - q[j * 2] * q[i * 2 + 1];
  }
  return a.abs() / 2;
}

/// Convex with corner angles between 45° and 135° (a page seen at a reasonable slant).
bool _goodShape(List<double> q) {
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final ax = q[((i + 3) % 4) * 2];
    final ay = q[((i + 3) % 4) * 2 + 1];
    final bx = q[i * 2];
    final by = q[i * 2 + 1];
    final cx = q[((i + 1) % 4) * 2];
    final cy = q[((i + 1) % 4) * 2 + 1];
    final cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx);
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
    final v1x = ax - bx;
    final v1y = ay - by;
    final v2x = cx - bx;
    final v2y = cy - by;
    final l = math.sqrt(v1x * v1x + v1y * v1y) * math.sqrt(v2x * v2x + v2y * v2y);
    if (l < 1e-3) return false;
    final ang = math.acos(((v1x * v2x + v1y * v2y) / l).clamp(-1.0, 1.0)) * 180 / math.pi;
    if (ang < 45 || ang > 135) return false;
  }
  return true;
}

/// Share of the four sides that runs along a real edge (0…1), and how much of them lies on the
/// picture's border (page running off the photo).
(double, double) _sideSupport(List<double> q, Int32List g, int w, int h, double thr) {
  var total = 0.0;
  var border = 0.0;
  for (var s = 0; s < 4; s++) {
    final x0 = q[s * 2];
    final y0 = q[s * 2 + 1];
    final x1 = q[((s + 1) % 4) * 2];
    final y1 = q[((s + 1) % 4) * 2 + 1];
    final len = math.max(2, math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).toInt());
    final nx = -(y1 - y0) / len;
    final ny = (x1 - x0) / len;
    var hits = 0.0;
    var onBorder = 0;
    for (var t = 0; t < len; t++) {
      final x = x0 + (x1 - x0) * t / len;
      final y = y0 + (y1 - y0) * t / len;
      var b = 0;
      for (var d = -2; d <= 2; d++) {
        final xx = (x + nx * d).round();
        final yy = (y + ny * d).round();
        if (xx >= 0 && xx < w && yy >= 0 && yy < h) b = math.max(b, g[yy * w + xx]);
      }
      if (b > thr) {
        hits += 1;
      } else if (x <= 2 || y <= 2 || x >= w - 3 || y >= h - 3) {
        hits += 0.6;
        onBorder++;
      }
    }
    total += hits / len;
    border += onBorder / len;
  }
  return (total / 4, border);
}

/// How much brighter (paper-like) the region is than a thin ring around it.
double _contrast(Int32List f, Uint8List m, int w, int h) {
  var ring = m;
  for (var k = 0; k < 4; k++) {
    final prev = ring;
    final next = Uint8List(prev.length);
    for (var i = 0; i < prev.length; i++) {
      final x = i % w;
      final y = i ~/ w;
      if (prev[i] != 0 ||
          (x > 0 && prev[i - 1] != 0) ||
          (x < w - 1 && prev[i + 1] != 0) ||
          (y > 0 && prev[i - w] != 0) ||
          (y < h - 1 && prev[i + w] != 0)) {
        next[i] = 1;
      }
    }
    ring = next;
  }
  var sIn = 0;
  var nIn = 0;
  var sOut = 0;
  var nOut = 0;
  for (var i = 0; i < m.length; i++) {
    if (m[i] != 0) {
      sIn += f[i];
      nIn++;
    } else if (ring[i] != 0) {
      sOut += f[i];
      nOut++;
    }
  }
  if (nIn == 0 || nOut == 0) return 0;
  return sIn / nIn - sOut / nOut;
}

/// Moves each side a few pixels (both ends independently) onto the strongest edge, then re-corners.
List<double> _refineSides(List<double> q, Int32List g, int w, int h) {
  double segScore(double x0, double y0, double x1, double y1) {
    final len = math.max(4, math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).toInt());
    var s = 0;
    var c = 0;
    for (var t = (len * 0.1).toInt(); t < (len * 0.9).toInt(); t++) {
      final x = (x0 + (x1 - x0) * t / len).round();
      final y = (y0 + (y1 - y0) * t / len).round();
      if (x >= 0 && x < w && y >= 0 && y < h) {
        s += g[y * w + x];
        c++;
      }
    }
    return c == 0 ? 0 : s / c;
  }

  final lines = List.generate(4, (_) => List<double>.filled(4, 0));
  for (var s = 0; s < 4; s++) {
    final x0 = q[s * 2];
    final y0 = q[s * 2 + 1];
    final x1 = q[((s + 1) % 4) * 2];
    final y1 = q[((s + 1) % 4) * 2 + 1];
    final len = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) + 1e-6;
    final nx = -(y1 - y0) / len;
    final ny = (x1 - x0) / len;
    var best = segScore(x0, y0, x1, y1);
    var ba = 0;
    var bb = 0;
    for (var da = -6; da <= 6; da++) {
      for (var db = -6; db <= 6; db++) {
        final sc = segScore(x0 + nx * da, y0 + ny * da, x1 + nx * db, y1 + ny * db);
        if (sc > best * 1.02) {
          best = sc;
          ba = da;
          bb = db;
        }
      }
    }
    lines[s] = [x0 + nx * ba, y0 + ny * ba, x1 + nx * bb, y1 + ny * bb];
  }
  final out = List<double>.filled(8, 0);
  for (var i = 0; i < 4; i++) {
    final a = lines[(i + 3) % 4];
    final b = lines[i];
    final d = (a[0] - a[2]) * (b[1] - b[3]) - (a[1] - a[3]) * (b[0] - b[2]);
    if (d.abs() < 1e-6) return q;
    final p = a[0] * a[3] - a[1] * a[2];
    final r = b[0] * b[3] - b[1] * b[2];
    out[i * 2] = ((p * (b[0] - b[2]) - (a[0] - a[2]) * r) / d).clamp(0.0, w - 1.0);
    out[i * 2 + 1] = ((p * (b[1] - b[3]) - (a[1] - a[3]) * r) / d).clamp(0.0, h - 1.0);
  }
  return _goodShape(out) && _polyArea(out) > _polyArea(q) * 0.7 ? out : q;
}

// ------------------------------------------------------------------ filters

PixelBuf applyScanFilter(PixelBuf src, ScanFilter f) {
  if (f == ScanFilter.original) return src;
  final w = src.width;
  final h = src.height;
  final px = Uint32List.fromList(src.px);
  switch (f) {
    case ScanFilter.original:
      break;
    case ScanFilter.auto:
      _autoScan(src, px, w, h);
    case ScanFilter.docs:
      _flatten(src, px, w, h);
      _curve(px, 70, 245);
      _saturate(px, 0.55);
    case ScanFilter.color:
      _flatten(src, px, w, h);
      _curve(px, 40, 250);
      _saturate(px, 1.45);
    case ScanFilter.image:
      _contrastK(px, 1.12, 0);
      _saturate(px, 1.4);
    case ScanFilter.superClear:
      _flatten(src, px, w, h);
      _curve(px, 90, 235);
      _saturate(px, 0.8);
      _sharpen(px, w, h);
    case ScanFilter.enhance:
      _contrastK(px, 1.25, 14);
      _saturate(px, 1.15);
    case ScanFilter.enhance2:
      _contrastK(px, 1.45, -10);
      _saturate(px, 1.3);
      _sharpen(px, w, h);
    case ScanFilter.bw:
      _flatten(src, px, w, h);
      _threshold(px, 185);
    case ScanFilter.bw2:
      _saturate(px, 0);
      _contrastK(px, 2.1, 10);
    case ScanFilter.gray:
      _saturate(px, 0);
    case ScanFilter.invert:
      for (var i = 0; i < px.length; i++) {
        px[i] = 0xFF000000 | (~px[i] & 0x00FFFFFF);
      }
  }
  return PixelBuf(w, h, px);
}

void _map(Uint32List px, int Function(int r, int g, int b) f) {
  for (var i = 0; i < px.length; i++) {
    final c = px[i];
    px[i] = f((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF);
  }
}

void _contrastK(Uint32List px, double k, int bright) => _map(
      px,
      (r, g, b) => _rgbInt(
        ((r - 128) * k + 128 + bright).toInt(),
        ((g - 128) * k + 128 + bright).toInt(),
        ((b - 128) * k + 128 + bright).toInt(),
      ),
    );

void _saturate(Uint32List px, double s) => _map(px, (r, g, b) {
      final l = (r * 299 + g * 587 + b * 114) / 1000;
      return _rgbInt((l + (r - l) * s).toInt(), (l + (g - l) * s).toInt(), (l + (b - l) * s).toInt());
    });

/// Linear stretch so [lo] becomes black and [hi] white.
void _curve(Uint32List px, int lo, int hi) {
  final k = 255 / math.max(1, hi - lo);
  _map(px, (r, g, b) => _rgbInt(((r - lo) * k).toInt(), ((g - lo) * k).toInt(), ((b - lo) * k).toInt()));
}

void _threshold(Uint32List px, int t) => _map(px, (r, g, b) {
      final l = (r * 299 + g * 587 + b * 114) ~/ 1000;
      return l > t ? 0xFFFFFFFF : 0xFF000000;
    });

const _modeMax = 0;
const _modeMin = 1;
const _modeMean = 2;

/// Separable (2·rad+1)² max / min / mean filter on one channel.
Int32List _slide(Int32List a, int w, int h, int rad, int mode) {
  Int32List pass(Int32List src, bool horizontal) {
    final out = Int32List(src.length);
    final n = horizontal ? w : h;
    final lines = horizontal ? h : w;
    for (var l = 0; l < lines; l++) {
      for (var k = 0; k < n; k++) {
        var v = mode == _modeMin ? 255 : 0;
        var cnt = 0;
        for (var d = -rad; d <= rad; d++) {
          final kk = (k + d).clamp(0, n - 1);
          final p = src[horizontal ? l * w + kk : kk * w + l];
          if (mode == _modeMax) {
            if (p > v) v = p;
          } else if (mode == _modeMin) {
            if (p < v) v = p;
          } else {
            v += p;
            cnt++;
          }
        }
        out[horizontal ? l * w + k : k * w + l] = mode == _modeMean ? v ~/ cnt : v;
      }
    }
    return out;
  }

  return pass(pass(a, true), false);
}

/// "Auto": clean scan look — paper turns pure white (shadows, creases and colour cast gone), text
/// deep black, coloured ink kept. Only areas that look like paper are cleaned that strongly; the
/// rest (table, laptop…) just gets brighter, even levels.
void _autoScan(PixelBuf src, Uint32List px, int w, int h) {
  final sw = math.max(8, w ~/ 6);
  final sh = math.max(8, h ~/ 6);
  final small = resizeExact(src, sw, sh);
  final sp = small.px;
  final r = math.max(3, (math.min(sw, sh) * 0.035).toInt());
  final bgCh = <Int32List>[];
  for (var ch = 0; ch < 3; ch++) {
    final shift = 16 - ch * 8;
    var a = Int32List(sp.length);
    for (var i = 0; i < sp.length; i++) {
      a[i] = (sp[i] >> shift) & 0xFF;
    }
    a = _slide(a, sw, sh, r, _modeMax);
    a = _slide(a, sw, sh, math.max(1, r ~/ 2), _modeMin);
    bgCh.add(_slide(a, sw, sh, math.max(1, r ~/ 2), _modeMean));
  }
  // brightest paper level (92nd percentile of the background brightness)
  final bgLum = Int32List(sp.length);
  for (var i = 0; i < sp.length; i++) {
    bgLum[i] = (bgCh[0][i] * 299 + bgCh[1][i] * 587 + bgCh[2][i] * 114) ~/ 1000;
  }
  final sortedLum = Int32List.fromList(bgLum)..sort();
  final lp = math.max(60, sortedLum[(bgLum.length * 0.92).toInt().clamp(0, bgLum.length - 1)]).toDouble();
  // gentle levels for non-paper areas (1st – 99.5th brightness percentiles)
  final hist = Int32List(256);
  for (final c in px) {
    hist[(((c >> 16) & 0xFF) * 299 + ((c >> 8) & 0xFF) * 587 + (c & 0xFF) * 114) ~/ 1000]++;
  }
  var lo = 0;
  var acc = 0;
  while (lo < 254 && acc + hist[lo] <= px.length ~/ 100) {
    acc += hist[lo];
    lo++;
  }
  var hi = 255;
  acc = 0;
  while (hi > lo + 1 && acc + hist[hi] <= px.length ~/ 200) {
    acc += hist[hi];
    hi--;
  }
  final span = math.max(1, hi - lo).toDouble();

  final fx = (sw - 1) / math.max(1, w - 1);
  final fy = (sh - 1) / math.max(1, h - 1);
  final bg = List<double>.filled(3, 0);
  final out = List<double>.filled(3, 0);
  for (var y = 0; y < h; y++) {
    final gy = y * fy;
    final y0 = math.min(gy.toInt(), sh - 1);
    final y1 = math.min(y0 + 1, sh - 1);
    final ty = gy - y0;
    for (var x = 0; x < w; x++) {
      final gx = x * fx;
      final x0 = math.min(gx.toInt(), sw - 1);
      final x1 = math.min(x0 + 1, sw - 1);
      final tx = gx - x0;
      final i00 = y0 * sw + x0;
      final i01 = y0 * sw + x1;
      final i10 = y1 * sw + x0;
      final i11 = y1 * sw + x1;
      for (var ch = 0; ch < 3; ch++) {
        final c = bgCh[ch];
        final top = c[i00] + (c[i01] - c[i00]) * tx;
        final bot = c[i10] + (c[i11] - c[i10]) * tx;
        bg[ch] = top + (bot - top) * ty;
      }
      final lb = bg[0] * 0.299 + bg[1] * 0.587 + bg[2] * 0.114;
      final sat = math.max(bg[0], math.max(bg[1], bg[2])) - math.min(bg[0], math.min(bg[1], bg[2]));
      final wgt = ((lb - 0.76 * lp) / (0.16 * lp)).clamp(0.0, 1.0) * ((70 - sat) / 40).clamp(0.0, 1.0);
      final i = y * w + x;
      final c = px[i];
      for (var ch = 0; ch < 3; ch++) {
        final v = ((c >> (16 - ch * 8)) & 0xFF).toDouble();
        final norm = math.min(v * 255 / math.max(25.0, bg[ch]), 255.0);
        final base = ((v - lo) * 255 / span).clamp(0.0, 255.0);
        final mixed = base * (1 - wgt) + norm * wgt;
        final clean = ((mixed - 70) * 255 / 162).clamp(0.0, 255.0); // white paper, deep ink
        out[ch] = mixed * (1 - wgt) + clean * wgt;
      }
      // on paper, greyish pixels become neutral; really coloured ink stays and gets a bit richer
      final g = out[0] * 0.299 + out[1] * 0.587 + out[2] * 0.114;
      final chroma = math.max(out[0], math.max(out[1], out[2])) - math.min(out[0], math.min(out[1], out[2]));
      final paperK = ((chroma - 30) / 45).clamp(0.0, 1.0) * 1.25;
      final k = 1.1 * (1 - wgt) + paperK * wgt;
      px[i] = _rgbInt((g + (out[0] - g) * k).round(), (g + (out[1] - g) * k).round(), (g + (out[2] - g) * k).round());
    }
  }
  _sharpenMild(px, w, h);
}

/// Light unsharp mask (text edges crisper without halos).
void _sharpenMild(Uint32List px, int w, int h) {
  final src = Uint32List.fromList(px);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      var out = 0xFF000000;
      for (final s in const [16, 8, 0]) {
        final c = (src[i] >> s) & 0xFF;
        final avg = (((src[i - 1] >> s) & 0xFF) + ((src[i + 1] >> s) & 0xFF) + ((src[i - w] >> s) & 0xFF) + ((src[i + w] >> s) & 0xFF)) ~/ 4;
        out |= _c(c + (c - avg) * 6 ~/ 10) << s;
      }
      px[i] = out;
    }
  }
}

/// Evens out lighting and shadows: divides each pixel by an estimate of the paper colour around
/// it (a heavily blurred, text-free copy of the page), so the paper turns white.
void _flatten(PixelBuf src, Uint32List px, int w, int h) {
  final sw = math.max(4, w ~/ 24);
  final sh = math.max(4, h ~/ 24);
  var cur = resizeExact(src, sw, sh).px;
  // dilate twice: text (dark) disappears, paper (light) remains
  for (var k = 0; k < 2; k++) {
    final next = Uint32List(cur.length);
    for (var y = 0; y < sh; y++) {
      for (var x = 0; x < sw; x++) {
        var r = 0;
        var g = 0;
        var b = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = (y + dy).clamp(0, sh - 1);
          for (var dx = -1; dx <= 1; dx++) {
            final c = cur[yy * sw + (x + dx).clamp(0, sw - 1)];
            r = math.max(r, (c >> 16) & 0xFF);
            g = math.max(g, (c >> 8) & 0xFF);
            b = math.max(b, c & 0xFF);
          }
        }
        next[y * sw + x] = _rgbInt(r, g, b);
      }
    }
    cur = next;
  }
  final bgSmall = PixelBuf(sw, sh, cur);
  final sx = sw / w;
  final sy = sh / h;
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) * sy - 0.5).clamp(0.0, sh - 1.0);
    for (var x = 0; x < w; x++) {
      final fx = ((x + 0.5) * sx - 0.5).clamp(0.0, sw - 1.0);
      final d = _bilinear(bgSmall, fx, fy);
      final c = px[y * w + x];
      final br = math.max(40, (d >> 16) & 0xFF);
      final bgc = math.max(40, (d >> 8) & 0xFF);
      final bb = math.max(40, d & 0xFF);
      px[y * w + x] = _rgbInt(((c >> 16) & 0xFF) * 255 ~/ br, ((c >> 8) & 0xFF) * 255 ~/ bgc, (c & 0xFF) * 255 ~/ bb);
    }
  }
}

void _sharpen(Uint32List px, int w, int h) {
  final src = Uint32List.fromList(px);
  int ch(int c, int s) => (c >> s) & 0xFF;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final v = <int>[
        for (final s in const [16, 8, 0]) 5 * ch(src[i], s) - ch(src[i - 1], s) - ch(src[i + 1], s) - ch(src[i - w], s) - ch(src[i + w], s),
      ];
      px[i] = _rgbInt(v[0], v[1], v[2]);
    }
  }
}
