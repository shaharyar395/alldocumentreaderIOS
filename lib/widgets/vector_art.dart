import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One path of an Android vector drawable (pathData + fill / stroke), drawn by [VectorArt].
/// Used to show the Android app's own small drawings (widget previews, onboarding tiles,
/// settings icons) exactly as they are there.
@immutable
class VPath {
  const VPath(this.data, {this.fill, this.stroke, this.strokeWidth = 1, this.alpha = 1});

  final String data;
  final Color? fill;
  final Color? stroke;
  final double strokeWidth;

  /// android:fillAlpha
  final double alpha;
}

/// A drawing made of [VPath]s in a [viewport] (android:viewportWidth/Height), scaled to
/// [width] x [height]. [tint] replaces every colour (like app:tint), keeping the alpha.
class VectorArt extends StatelessWidget {
  const VectorArt(
    this.paths, {
    super.key,
    this.viewport = const Size(24, 24),
    required this.width,
    required this.height,
    this.tint,
  });

  final List<VPath> paths;
  final Size viewport;
  final double width;
  final double height;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _VectorPainter(paths, viewport, tint)),
    );
  }
}

class _VectorPainter extends CustomPainter {
  _VectorPainter(this.paths, this.viewport, this.tint);

  final List<VPath> paths;
  final Size viewport;
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) {
    // like Android: the viewport is scaled to the view (fitCenter)
    final scale = math.min(size.width / viewport.width, size.height / viewport.height);
    canvas.save();
    canvas.translate((size.width - viewport.width * scale) / 2, (size.height - viewport.height * scale) / 2);
    canvas.scale(scale);
    for (final item in paths) {
      final path = parseVectorPath(item.data);
      final fill = item.fill;
      if (fill != null) {
        final color = tint == null ? fill : tint!.withValues(alpha: fill.a);
        canvas.drawPath(
          path,
          Paint()
            ..isAntiAlias = true
            ..color = color.withValues(alpha: color.a * item.alpha),
        );
      }
      final stroke = item.stroke;
      if (stroke != null) {
        final color = tint == null ? stroke : tint!.withValues(alpha: stroke.a);
        canvas.drawPath(
          path,
          Paint()
            ..isAntiAlias = true
            ..style = PaintingStyle.stroke
            ..strokeWidth = item.strokeWidth
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = color,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VectorPainter oldDelegate) =>
      oldDelegate.paths != paths || oldDelegate.viewport != viewport || oldDelegate.tint != tint;
}

final Map<String, Path> _cache = {};

/// Turns SVG / Android pathData (M L H V C S Q T A Z, absolute and relative, implicit repeats)
/// into a [Path]. Parsed paths are cached.
Path parseVectorPath(String data) {
  final cached = _cache[data];
  if (cached != null) return cached;
  final path = _PathParser(data).parse();
  _cache[data] = path;
  return path;
}

class _PathParser {
  _PathParser(this.src);

  static const _commands = 'MmLlHhVvCcSsQqTtAaZz';

  final String src;
  int _i = 0;

  void _skip() {
    while (_i < src.length) {
      final c = src[_i];
      if (c == ' ' || c == ',' || c == '\n' || c == '\r' || c == '\t') {
        _i++;
      } else {
        break;
      }
    }
  }

  bool _atNumber() {
    _skip();
    if (_i >= src.length) return false;
    final c = src.codeUnitAt(_i);
    return (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46; // 0-9 - + .
  }

  double _num() {
    _skip();
    final start = _i;
    if (_i < src.length && (src[_i] == '-' || src[_i] == '+')) _i++;
    var dot = false;
    var exp = false;
    while (_i < src.length) {
      final c = src[_i];
      if (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) {
        _i++;
      } else if (c == '.' && !dot && !exp) {
        dot = true;
        _i++;
      } else if ((c == 'e' || c == 'E') && !exp) {
        exp = true;
        _i++;
        if (_i < src.length && (src[_i] == '-' || src[_i] == '+')) _i++;
      } else {
        break;
      }
    }
    return double.tryParse(src.substring(start, _i)) ?? 0;
  }

  /// Arc flags may be written without separators ("a1,1 0 01 5,5").
  bool _flag() {
    _skip();
    if (_i >= src.length) return false;
    final c = src[_i];
    _i++;
    return c == '1';
  }

  Path parse() {
    final path = Path();
    var x = 0.0, y = 0.0; // current point
    var sx = 0.0, sy = 0.0; // start of the sub-path
    var cx = 0.0, cy = 0.0; // last control point (for S / T)
    var last = '';
    var cmd = ''; // '' = no command yet (or after Z)
    while (true) {
      _skip();
      if (_i >= src.length) break;
      final c = src[_i];
      if (_commands.contains(c)) {
        cmd = c;
        _i++;
      } else if (cmd.isEmpty || !_atNumber()) {
        _i++;
        continue;
      }
      final command = cmd;
      final rel = command == command.toLowerCase();
      final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
      switch (command.toUpperCase()) {
        case 'M':
          x = ox + _num();
          y = oy + _num();
          path.moveTo(x, y);
          sx = x;
          sy = y;
          // further pairs are line-tos
          cmd = rel ? 'l' : 'L';
        case 'L':
          x = ox + _num();
          y = oy + _num();
          path.lineTo(x, y);
        case 'H':
          x = ox + _num();
          path.lineTo(x, y);
        case 'V':
          y = oy + _num();
          path.lineTo(x, y);
        case 'C':
          final x1 = ox + _num(), y1 = oy + _num();
          final x2 = ox + _num(), y2 = oy + _num();
          x = ox + _num();
          y = oy + _num();
          path.cubicTo(x1, y1, x2, y2, x, y);
          cx = x2;
          cy = y2;
        case 'S':
          final reflect = last == 'C' || last == 'S';
          final x1 = reflect ? 2 * x - cx : x, y1 = reflect ? 2 * y - cy : y;
          final x2 = ox + _num(), y2 = oy + _num();
          x = ox + _num();
          y = oy + _num();
          path.cubicTo(x1, y1, x2, y2, x, y);
          cx = x2;
          cy = y2;
        case 'Q':
          final x1 = ox + _num(), y1 = oy + _num();
          x = ox + _num();
          y = oy + _num();
          path.quadraticBezierTo(x1, y1, x, y);
          cx = x1;
          cy = y1;
        case 'T':
          final reflect = last == 'Q' || last == 'T';
          final x1 = reflect ? 2 * x - cx : x, y1 = reflect ? 2 * y - cy : y;
          x = ox + _num();
          y = oy + _num();
          path.quadraticBezierTo(x1, y1, x, y);
          cx = x1;
          cy = y1;
        case 'A':
          final rx = _num(), ry = _num();
          final rotation = _num();
          final large = _flag();
          final sweep = _flag();
          x = ox + _num();
          y = oy + _num();
          path.arcToPoint(
            Offset(x, y),
            radius: Radius.elliptical(rx, ry),
            rotation: rotation,
            largeArc: large,
            clockwise: sweep,
          );
        case 'Z':
          path.close();
          x = sx;
          y = sy;
          cmd = '';
      }
      last = command.toUpperCase();
    }
    return path;
  }
}
