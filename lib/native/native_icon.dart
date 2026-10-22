import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../widgets/vector_art.dart' show parseVectorPath;
import 'native_colors.dart';

/// A colour inside a native drawable: a fixed value or a reference to an Android @color
/// (resolved for the current theme, so icons using @color/icon_main turn light in dark mode).
@immutable
class NColor {
  const NColor.hex(int value)
      : _value = value,
        ref = null;
  const NColor.ref(String this.ref) : _value = 0;

  final int _value;
  final String? ref;

  Color resolve(NC colors) => ref == null ? Color(_value) : colors.byName(ref!);
}

/// aapt:attr linear gradient of a path (viewport coordinates).
@immutable
class NGradient {
  const NGradient({required this.start, required this.end, required this.colors});

  final Offset start;
  final Offset end;
  final List<NColor> colors;
}

/// One node of a vector drawable: [NPath] or [NGroup].
@immutable
sealed class NNode {
  const NNode();
}

/// `<path>` of an Android vector drawable.
class NPath extends NNode {
  const NPath(
    this.data, {
    this.fill,
    this.fillGradient,
    this.stroke,
    this.strokeGradient,
    this.strokeWidth = 0,
    this.cap = StrokeCap.butt,
    this.join = StrokeJoin.miter,
    this.fillAlpha = 1,
    this.strokeAlpha = 1,
    this.evenOdd = false,
  });

  final String data;
  final NColor? fill;
  final NGradient? fillGradient;
  final NColor? stroke;
  final NGradient? strokeGradient;
  final double strokeWidth;
  final StrokeCap cap;
  final StrokeJoin join;
  final double fillAlpha;
  final double strokeAlpha;
  final bool evenOdd;
}

/// `<group>` with its transform (translate / scale / rotation around the pivot).
class NGroup extends NNode {
  const NGroup({
    this.tx = 0,
    this.ty = 0,
    this.sx = 1,
    this.sy = 1,
    this.rotation = 0,
    this.px = 0,
    this.py = 0,
    required this.children,
  });

  final double tx;
  final double ty;
  final double sx;
  final double sy;
  final double rotation;
  final double px;
  final double py;
  final List<NNode> children;
}

/// A whole `<vector>` drawable: its default size (dp), viewport and nodes.
@immutable
class NDrawable {
  const NDrawable({
    required this.width,
    required this.height,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.children,
  });

  final double width;
  final double height;
  final double viewportWidth;
  final double viewportHeight;
  final List<NNode> children;
}

/// Draws an Android vector drawable (generated in native_drawables.dart) exactly as the native
/// app does. [size] sets both sides (else [width]/[height], else the drawable's own dp size).
/// [tint] replaces every colour keeping its alpha, like app:tint / android:tint.
class NativeIcon extends StatelessWidget {
  const NativeIcon(this.drawable, {super.key, this.size, this.width, this.height, this.tint});

  final NDrawable drawable;
  final double? size;
  final double? width;
  final double? height;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final w = size ?? width ?? drawable.width;
    final h = size ?? height ?? drawable.height;
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(painter: _NativePainter(drawable, NC.of(context), tint)),
    );
  }
}

class _NativePainter extends CustomPainter {
  _NativePainter(this.drawable, this.colors, this.tint);

  final NDrawable drawable;
  final NC colors;
  final Color? tint;

  Color _color(NColor c, double alpha) {
    final base = c.resolve(colors);
    final color = tint == null ? base : tint!.withValues(alpha: base.a * tint!.a);
    return color.withValues(alpha: color.a * alpha);
  }

  Shader _linear(NGradient g, double alpha) {
    return ui.Gradient.linear(g.start, g.end, [for (final c in g.colors) _color(c, alpha)]);
  }

  void _draw(Canvas canvas, List<NNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case NGroup():
          canvas.save();
          // Android order: translate, then rotate / scale around the pivot
          canvas.translate(node.tx + node.px, node.ty + node.py);
          if (node.rotation != 0) canvas.rotate(node.rotation * math.pi / 180);
          canvas.scale(node.sx, node.sy);
          canvas.translate(-node.px, -node.py);
          _draw(canvas, node.children);
          canvas.restore();
        case NPath():
          var path = parseVectorPath(node.data);
          if (node.evenOdd) {
            path = Path()
              ..fillType = PathFillType.evenOdd
              ..addPath(path, Offset.zero);
          }
          final fill = node.fill;
          final fillGradient = node.fillGradient;
          if (fill != null || fillGradient != null) {
            final paint = Paint()..isAntiAlias = true;
            if (fillGradient != null) {
              paint.shader = _linear(fillGradient, node.fillAlpha);
            } else {
              paint.color = _color(fill!, node.fillAlpha);
            }
            canvas.drawPath(path, paint);
          }
          final stroke = node.stroke;
          final strokeGradient = node.strokeGradient;
          if ((stroke != null || strokeGradient != null) && node.strokeWidth > 0) {
            final paint = Paint()
              ..isAntiAlias = true
              ..style = PaintingStyle.stroke
              ..strokeWidth = node.strokeWidth
              ..strokeCap = node.cap
              ..strokeJoin = node.join;
            if (strokeGradient != null) {
              paint.shader = _linear(strokeGradient, node.strokeAlpha);
            } else {
              paint.color = _color(stroke!, node.strokeAlpha);
            }
            canvas.drawPath(path, paint);
          }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final vw = drawable.viewportWidth, vh = drawable.viewportHeight;
    if (vw <= 0 || vh <= 0) return;
    // Android scales the viewport to the view size (an ImageView with fitCenter keeps the ratio)
    final scale = math.min(size.width / vw, size.height / vh);
    canvas.save();
    canvas.translate((size.width - vw * scale) / 2, (size.height - vh * scale) / 2);
    canvas.scale(scale);
    _draw(canvas, drawable.children);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NativePainter oldDelegate) =>
      oldDelegate.drawable != drawable || oldDelegate.colors != colors || oldDelegate.tint != tint;
}
