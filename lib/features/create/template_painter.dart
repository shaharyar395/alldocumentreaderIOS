import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'template_model.dart';

/// Fonts offered in the editor's Fonts list (system families, so they work offline everywhere).
class TplFont {
  const TplFont(this.name, this.android, this.ios, {this.weight = FontWeight.normal});

  final String name;
  final String android;
  final String? ios;
  final FontWeight weight;

  String? get family => Platform.isIOS ? ios : android;
}

const tplFonts = <TplFont>[
  TplFont('Carrois Gothic SC', 'sans-serif-smallcaps', 'Avenir Next Condensed'),
  TplFont('Coming Soon', 'casual', 'Chalkboard SE'),
  TplFont('Cutive Mono', 'serif-monospace', 'Courier New'),
  TplFont('Dancing Script', 'cursive', 'Snell Roundhand'),
  TplFont('Droid Sans Mono', 'monospace', 'Menlo'),
  TplFont('Noto Serif', 'serif', 'Georgia'),
  TplFont('Noto Serif Bold', 'serif', 'Georgia', weight: FontWeight.bold),
  TplFont('Roboto', 'sans-serif', null),
  TplFont('Roboto Black', 'sans-serif-black', null, weight: FontWeight.w900),
  TplFont('Roboto Condensed', 'sans-serif-condensed', 'Avenir Next Condensed'),
  TplFont('Roboto Light', 'sans-serif-light', null, weight: FontWeight.w300),
  TplFont('Roboto Medium', 'sans-serif-medium', null, weight: FontWeight.w500),
  TplFont('Roboto Thin', 'sans-serif-thin', null, weight: FontWeight.w100),
];

TplFont tplFont(String name) => tplFonts.firstWhere((font) => font.name == name, orElse: () => tplFonts.firstWhere((font) => font.name == tplDefaultFont));

TextStyle tplTextStyle(String font, {double size = 16, int color = 0xFF1B1F2A, bool bold = false, bool italic = false, bool underline = false, bool strike = false, double height = 1.2}) {
  final f = tplFont(font);
  final decorations = <TextDecoration>[if (underline) TextDecoration.underline, if (strike) TextDecoration.lineThrough];
  return TextStyle(
    fontFamily: f.family,
    fontSize: size,
    color: Color(color),
    fontWeight: bold ? FontWeight.bold : f.weight,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    decoration: decorations.isEmpty ? TextDecoration.none : TextDecoration.combine(decorations),
    decorationColor: Color(color),
    height: height,
  );
}

/// Draws template pages on any canvas whose units are PDF points (screen, picture or export).
class TplRenderer {
  TplRenderer._();

  static final LinkedHashMap<String, TextPainter> _layouts = LinkedHashMap<String, TextPainter>();

  /// Photos picked in the editor, by path (loaded with [loadPhoto]).
  static final Map<String, ui.Image> photos = {};

  static Future<void> loadPhoto(String path) async {
    if (photos.containsKey(path)) return;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      photos[path] = frame.image;
    } catch (_) {
      // drawn as a grey box
    }
  }

  static Future<void> loadPhotos(TPage page) async {
    for (final el in page.elements) {
      if (el is TImage && el.path != null) await loadPhoto(el.path!);
    }
  }

  static String _listText(TText t) {
    if (t.list == 1) return t.text.split('\n').map((line) => '•  $line').join('\n');
    if (t.list == 2) {
      final lines = t.text.split('\n');
      return [for (var i = 0; i < lines.length; i++) '${i + 1}.  ${lines[i]}'].join('\n');
    }
    return t.text;
  }

  /// The text laid out in its box (list markers, style, alignment, spacing).
  static TextPainter layout(TText t) {
    final key = '${t.text}|${t.w}|${t.size}|${t.color}|${t.font}|${t.bold}|${t.italic}|${t.underline}|${t.strike}|${t.list}|${t.align}|${t.lineMult}';
    final hit = _layouts.remove(key);
    if (hit != null) {
      _layouts[key] = hit;
      return hit;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: _listText(t),
        style: tplTextStyle(t.font, size: t.size, color: t.color, bold: t.bold, italic: t.italic, underline: t.underline, strike: t.strike, height: t.lineMult),
      ),
      textAlign: switch (t.align) {
        1 => TextAlign.center,
        2 => TextAlign.right,
        _ => TextAlign.left,
      },
      textDirection: TextDirection.ltr,
    )..layout(minWidth: math.max(1.0, t.w), maxWidth: math.max(1.0, t.w));
    _layouts[key] = painter;
    while (_layouts.length > 300) {
      _layouts.remove(_layouts.keys.first)?.dispose();
    }
    return painter;
  }

  /// Width / height of an element's box in points.
  static Size size(TEl el) {
    if (el is TText) return Size(el.w, math.max(el.size, layout(el).height));
    if (el is TImage) return Size(el.w, el.h);
    if (el is TShape) return Size(el.w, el.h);
    return Size.zero;
  }

  static Offset center(TEl el) {
    final s = size(el);
    return Offset(el.x + s.width / 2, el.y + s.height / 2);
  }

  static void paint(Canvas canvas, TPage page) {
    canvas.drawRect(const Rect.fromLTWH(0, 0, tplPageW, tplPageH), Paint()..color = Color(page.bg));
    canvas.save();
    canvas.clipRect(const Rect.fromLTWH(0, 0, tplPageW, tplPageH));
    for (final el in page.elements) {
      paintEl(canvas, el);
    }
    canvas.restore();
  }

  static void paintEl(Canvas canvas, TEl el) {
    final c = center(el);
    canvas.save();
    if (el.rotation != 0) {
      canvas.translate(c.dx, c.dy);
      canvas.rotate(el.rotation * math.pi / 180);
      canvas.translate(-c.dx, -c.dy);
    }
    if (el is TShape) {
      _shape(canvas, el);
    } else if (el is TText) {
      layout(el).paint(canvas, Offset(el.x, el.y));
    } else if (el is TImage) {
      _image(canvas, el);
    }
    canvas.restore();
  }

  static void _shape(Canvas canvas, TShape s) {
    final r = Rect.fromLTWH(s.x, s.y, s.w, s.h);
    final paint = Paint()..isAntiAlias = true;
    if (s.kind == TShapeKind.line) {
      paint
        ..color = Color(s.color)
        ..strokeWidth = math.max(0.6, s.h);
      canvas.drawLine(Offset(s.x, s.y), Offset(s.x + s.w, s.y), paint);
      return;
    }
    if (s.stroke > 0) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.stroke
        ..color = Color(s.color);
    } else {
      paint.color = Color(s.color);
      final end = s.color2;
      if (end != null) {
        paint.shader = s.horizontal
            ? ui.Gradient.linear(r.centerLeft, r.centerRight, [Color(s.color), Color(end)])
            : ui.Gradient.linear(r.topCenter, r.bottomCenter, [Color(s.color), Color(end)]);
      }
    }
    if (s.kind == TShapeKind.oval) {
      canvas.drawOval(r, paint);
    } else if (s.radius > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(s.radius)), paint);
    } else {
      canvas.drawRect(r, paint);
    }
  }

  static void _image(Canvas canvas, TImage im) {
    final dst = Rect.fromLTWH(im.x, im.y, im.w, im.h);
    canvas.save();
    if (im.flipH || im.flipV) {
      canvas.translate(dst.center.dx, dst.center.dy);
      canvas.scale(im.flipH ? -1 : 1, im.flipV ? -1 : 1);
      canvas.translate(-dst.center.dx, -dst.center.dy);
    }
    if (im.circle) {
      canvas.clipPath(Path()..addOval(dst));
    } else if (im.corner > 0) {
      canvas.clipRRect(RRect.fromRectAndRadius(dst, Radius.circular(im.corner)));
    } else {
      canvas.clipRect(dst);
    }
    // the whole picture is drawn so that its crop part fills the box
    final crop = im.crop;
    final cw = math.max(0.01, crop.width);
    final ch = math.max(0.01, crop.height);
    final full = Rect.fromLTWH(dst.left - crop.left / cw * dst.width, dst.top - crop.top / ch * dst.height, dst.width / cw, dst.height / ch);
    final path = im.path;
    if (path != null) {
      final photo = photos[path];
      if (photo != null) {
        canvas.drawImageRect(photo, Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble()), full, Paint()..filterQuality = FilterQuality.medium);
      } else {
        canvas.drawRect(dst, Paint()..color = const Color(0xFFE3E7ED));
      }
    } else {
      paintArt(canvas, im.res ?? '', full);
    }
    canvas.restore();
  }

  /// A page picture [width] pixels wide (thumbnails, PNG / JPG / PDF export).
  static Future<ui.Image> render(TPage page, double width) async {
    final scale = width / tplPageW;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, width, tplPageH * scale), Paint()..color = Colors.white);
    canvas.scale(scale);
    paint(canvas, page);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.round(), (tplPageH * scale).round());
    picture.dispose();
    return image;
  }
}

// ---------------------------------------------------------------------------------------------
// built-in art (drawn, so it stays sharp at any size)
// ---------------------------------------------------------------------------------------------

void _icon(Canvas canvas, IconData icon, Rect r, Color color) {
  final painter = TextPainter(
    text: TextSpan(text: String.fromCharCode(icon.codePoint), style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: r.height, color: color, height: 1)),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, r.center - Offset(painter.width / 2, painter.height / 2));
  painter.dispose();
}

void paintArt(Canvas canvas, String res, Rect r) {
  final fill = Paint()..isAntiAlias = true;
  Offset at(double x, double y) => Offset(r.left + x * r.width, r.top + y * r.height);
  Rect box(double l, double t, double w, double h) => Rect.fromLTWH(r.left + l * r.width, r.top + t * r.height, w * r.width, h * r.height);
  switch (res) {
    case 'tpl_ic_pin':
      _icon(canvas, Icons.location_on_rounded, r, const Color(0xFF6B7380));
    case 'tpl_ic_mail':
      _icon(canvas, Icons.mail_rounded, r, const Color(0xFF6B7380));
    case 'tpl_ic_phone':
      _icon(canvas, Icons.phone_rounded, r, const Color(0xFF6B7380));
    case 'tpl_ic_web':
      _icon(canvas, Icons.language_rounded, r, const Color(0xFF6B7380));
    case 'tpl_logo':
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.25)), fill..color = const Color(0xFF1E6FE6));
      canvas.drawCircle(at(0.55, 0.6), r.width * 0.2, Paint()..color = Colors.white);
      canvas.drawRect(box(0.28, 0.2, 0.12, 0.6), Paint()..color = Colors.white);
      canvas.drawCircle(at(0.55, 0.6), r.width * 0.09, Paint()..color = const Color(0xFF1E6FE6));
    case 'tpl_avatar_1':
    case 'tpl_avatar_2':
      final second = res == 'tpl_avatar_2';
      canvas.drawRect(r, fill..color = second ? const Color(0xFFDCE7FF) : const Color(0xFFE9DDF8));
      final skin = Paint()..color = const Color(0xFFF2C9A5);
      final hair = Paint()..color = second ? const Color(0xFF3A2A20) : const Color(0xFF7A4A2A);
      final shirt = Paint()..color = second ? const Color(0xFF24407A) : const Color(0xFF8E5BD8);
      canvas.drawOval(box(0.18, 0.72, 0.64, 0.5), shirt);
      canvas.drawRect(box(0.43, 0.55, 0.14, 0.2), skin);
      canvas.drawOval(box(0.3, 0.22, 0.4, 0.42), hair);
      canvas.drawOval(box(0.33, 0.28, 0.34, 0.38), skin);
      canvas.drawArc(box(0.3, 0.2, 0.4, 0.3), math.pi, math.pi, true, hair);
    case 'tpl_art_flowers':
      const petals = [0xFFF4A6B8, 0xFFF7C98B, 0xFFB9D7F2, 0xFFF2B5D4, 0xFFC9E4B4];
      final stem = Paint()
        ..color = const Color(0xFF7BAE6E)
        ..strokeWidth = r.width * 0.012
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < 7; i++) {
        final cx = 0.1 + i * 0.13;
        final cy = 0.3 + (i % 3) * 0.16;
        canvas.drawLine(at(cx, cy), at(cx - 0.05 + (i % 2) * 0.08, 1.0), stem);
        canvas.drawOval(box(cx - 0.02, cy + 0.2, 0.06, 0.05), Paint()..color = const Color(0xFF9CCB8C));
        final petal = Paint()..color = Color(petals[i % petals.length]);
        for (var k = 0; k < 6; k++) {
          final a = k * math.pi / 3;
          canvas.drawCircle(at(cx + math.cos(a) * 0.035, cy + math.sin(a) * 0.05), r.width * 0.03, petal);
        }
        canvas.drawCircle(at(cx, cy), r.width * 0.022, Paint()..color = const Color(0xFFF6D365));
      }
    case 'tpl_art_cap':
      final navy = Paint()..color = const Color(0xFF24407A);
      canvas.drawPath(
        Path()
          ..moveTo(at(0.5, 0.18).dx, at(0.5, 0.18).dy)
          ..lineTo(at(0.96, 0.4).dx, at(0.96, 0.4).dy)
          ..lineTo(at(0.5, 0.62).dx, at(0.5, 0.62).dy)
          ..lineTo(at(0.04, 0.4).dx, at(0.04, 0.4).dy)
          ..close(),
        navy,
      );
      canvas.drawPath(
        Path()
          ..moveTo(at(0.22, 0.5).dx, at(0.22, 0.5).dy)
          ..lineTo(at(0.22, 0.72).dx, at(0.22, 0.72).dy)
          ..quadraticBezierTo(at(0.5, 0.86).dx, at(0.5, 0.86).dy, at(0.78, 0.72).dx, at(0.78, 0.72).dy)
          ..lineTo(at(0.78, 0.5).dx, at(0.78, 0.5).dy)
          ..lineTo(at(0.5, 0.62).dx, at(0.5, 0.62).dy)
          ..close(),
        Paint()..color = const Color(0xFF1B2F5C),
      );
      final gold = Paint()
        ..color = const Color(0xFFF2B233)
        ..strokeWidth = r.width * 0.012
        ..style = PaintingStyle.stroke;
      canvas.drawLine(at(0.5, 0.4), at(0.86, 0.48), gold);
      canvas.drawLine(at(0.86, 0.48), at(0.86, 0.74), gold);
      canvas.drawCircle(at(0.86, 0.76), r.width * 0.025, Paint()..color = const Color(0xFFF2B233));
      canvas.drawCircle(at(0.5, 0.4), r.width * 0.02, Paint()..color = const Color(0xFFF2B233));
    case 'tpl_art_megaphone':
      final body = Paint()..color = const Color(0xFF1B1F2A);
      canvas.drawPath(
        Path()
          ..moveTo(at(0.18, 0.4).dx, at(0.18, 0.4).dy)
          ..lineTo(at(0.75, 0.1).dx, at(0.75, 0.1).dy)
          ..lineTo(at(0.75, 0.9).dx, at(0.75, 0.9).dy)
          ..lineTo(at(0.18, 0.62).dx, at(0.18, 0.62).dy)
          ..close(),
        body,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(box(0.08, 0.38, 0.12, 0.26), Radius.circular(r.width * 0.02)), Paint()..color = const Color(0xFFE8453C));
      canvas.drawOval(box(0.71, 0.08, 0.1, 0.84), Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawRect(box(0.26, 0.62, 0.08, 0.26), Paint()..color = const Color(0xFF1B1F2A));
      final waves = Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width * 0.018
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 3; i++) {
        canvas.drawArc(box(0.78 + i * 0.05, 0.3 - i * 0.07, 0.12, 0.4 + i * 0.14), -0.6, 1.2, false, waves);
      }
    case 'tpl_art_sun':
      const colors = [0xFFF9C79A, 0xFFF6A86B, 0xFFF26B1D];
      for (var i = 0; i < 3; i++) {
        canvas.drawCircle(r.center, r.width * (0.5 - i * 0.14), Paint()..color = Color(colors[i]));
      }
    case 'tpl_art_bags':
      const bags = [(0.05, 0.3, 0.42, 0.66, 0xFFFFD447), (0.38, 0.18, 0.4, 0.78, 0xFF1B1F2A), (0.62, 0.38, 0.34, 0.58, 0xFFFFFFFF)];
      for (final (l, t, w, h, color) in bags) {
        final handle = Paint()
          ..color = Color(color == 0xFFFFFFFF ? 0xFFF5F5F5 : color)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r.width * 0.02;
        canvas.drawArc(box(l + w * 0.25, t - h * 0.18, w * 0.5, h * 0.36), math.pi, math.pi, false, handle);
        canvas.drawRRect(RRect.fromRectAndRadius(box(l, t, w, h), Radius.circular(r.width * 0.02)), Paint()..color = Color(color));
      }
    case 'tpl_art_tree':
      final green = Paint()..color = const Color(0xFF1F7A45);
      for (var i = 0; i < 3; i++) {
        final top = 0.12 + i * 0.2;
        final half = 0.22 + i * 0.12;
        canvas.drawPath(
          Path()
            ..moveTo(at(0.5, top).dx, at(0.5, top).dy)
            ..lineTo(at(0.5 + half, top + 0.34).dx, at(0.5 + half, top + 0.34).dy)
            ..lineTo(at(0.5 - half, top + 0.34).dx, at(0.5 - half, top + 0.34).dy)
            ..close(),
          green,
        );
      }
      canvas.drawRect(box(0.44, 0.86, 0.12, 0.12), Paint()..color = const Color(0xFF7A4A2A));
      final star = Path();
      for (var k = 0; k < 10; k++) {
        final radius = k.isEven ? 0.07 : 0.03;
        final a = -math.pi / 2 + k * math.pi / 5;
        final p = at(0.5 + math.cos(a) * radius, 0.1 + math.sin(a) * radius * r.width / r.height);
        if (k == 0) {
          star.moveTo(p.dx, p.dy);
        } else {
          star.lineTo(p.dx, p.dy);
        }
      }
      star.close();
      canvas.drawPath(star, Paint()..color = const Color(0xFFF2B233));
      const balls = [(0.42, 0.42, 0xFFB3262B), (0.6, 0.55, 0xFFF2B233), (0.36, 0.7, 0xFF3C8BE8), (0.66, 0.78, 0xFFB3262B), (0.5, 0.62, 0xFFFFFFFF)];
      for (final (x, y, color) in balls) {
        canvas.drawCircle(at(x, y), r.width * 0.03, Paint()..color = Color(color));
      }
    default:
      canvas.drawRect(r, fill..color = const Color(0xFFE3E7ED));
  }
}
