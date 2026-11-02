import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../create/tool_widgets.dart';

/// EditTutorialSheet: the "i" sheet with the looping Edit PDF / Sign demo (it switches tab at the
/// end of each loop), Try now and Later. Returns 'edit' or 'sign' for Try now.
Future<String?> showEditTutorial(BuildContext context) {
  final nc = NC.of(context);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: nc.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    clipBehavior: Clip.antiAlias,
    builder: (sheet) => const _Tutorial(),
  );
}

class _Tutorial extends StatefulWidget {
  const _Tutorial();

  @override
  State<_Tutorial> createState() => _TutorialState();
}

class _TutorialState extends State<_Tutorial> with SingleTickerProviderStateMixin {
  bool _sign = false;
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 5200))
    ..addStatusListener(_onStatus)
    ..forward();

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    // onLoop: the demo switches to the other tab and starts again
    setState(() => _sign = !_sign);
    _anim.forward(from: 0);
  }

  void _select(bool sign) {
    setState(() => _sign = sign);
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// sheet_edit_tutorial.xml: 300dp bg_tutorial_stage with the demo and an "Edit PDF | Sign" pill
  /// (bg_tut_tabs / bg_tut_tab), title 18sp bold, Try now (50dp bg_apply_btn), Later (primary).
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    Widget tab(String label, bool sign) {
      final on = _sign == sign;
      return GestureDetector(
        onTap: () => _select(sign),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? const Color(0xFFE3EDFD) : Colors.transparent, borderRadius: BorderRadius.circular(13)),
          child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? nc.primary : nc.textSecondary)),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 300,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFEDE9E4), Color(0xFFF4F1ED), Color(0xFFFFFFFF)],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: _anim,
                      builder: (context, _) => CustomPaint(painter: TutorialDemoPainter(t: _anim.value, sign: _sign)),
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [tab(s.t('editPdf'), false), tab(s.t('sign'), true)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _sign ? s.t('tutSignTitle') : s.t('tutEditTitle'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: NativePillButton(
                height: 50,
                fontSize: 17,
                label: s.t('tryNow'),
                onPressed: () => Navigator.pop(context, _sign ? 'sign' : 'edit'),
              ),
            ),
          ),
          InkWell(
            onTap: () => Navigator.pop(context),
            child: SizedBox(
              height: 44,
              width: double.infinity,
              child: Center(child: Text(s.t('later'), style: TextStyle(fontSize: 15, color: nc.primary))),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// TutorialDemoView: a phone showing how Edit PDF works (select a line, format bar, colour
/// change) or how Sign works (Add signature → sign → placed on the page). [t] runs 0 → 1.
class TutorialDemoPainter extends CustomPainter {
  TutorialDemoPainter({required this.t, required this.sign});

  final double t;
  final bool sign;

  double _seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  static Color _a(int color, double alpha) => Color(color).withValues(alpha: alpha.clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final pw = math.min(size.width * 0.62, 230.0);
    final left = (size.width - pw) / 2;
    const top = 52.0;
    final phone = Rect.fromLTRB(left, top, left + pw, size.height + 40);
    canvas.drawRRect(RRect.fromRectAndRadius(phone, const Radius.circular(26)), Paint()..color = const Color(0xFF1F2126));
    final screen = Rect.fromLTRB(phone.left + 7, phone.top + 7, phone.right - 7, phone.bottom);
    canvas.drawRRect(RRect.fromRectAndRadius(screen, const Radius.circular(20)), Paint()..color = Colors.white);
    canvas.save();
    canvas.clipRect(screen);
    if (sign) {
      _drawSign(canvas, screen);
    } else {
      _drawEdit(canvas, screen);
    }
    canvas.restore();
  }

  void _bars(Canvas c, double x, double y, double w, int n, {double gap = 7}) {
    final p = Paint()..color = const Color(0xFFD9DDE4);
    for (var i = 0; i < n; i++) {
      final lw = i % 3 == 2 ? w * 0.7 : w;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y + i * gap, lw, 3), const Radius.circular(1.5)), p);
    }
  }

  /// Text drawn with its baseline at [baseline] (like Canvas.drawText); returns its width.
  double _text(Canvas c, String text, double x, double baseline, double size, Color color, {bool bold = false, bool italic = false, bool measureOnly = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, fontStyle: italic ? FontStyle.italic : FontStyle.normal),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    if (!measureOnly) {
      final ascent = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      painter.paint(c, Offset(x, baseline - ascent));
    }
    painter.dispose();
    return width;
  }

  void _shadowRRect(Canvas c, RRect r, Color fill, double blur, Offset offset, Color shadow) {
    c.drawRRect(
      r.shift(offset),
      Paint()
        ..color = shadow
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur / 2),
    );
    c.drawRRect(r, Paint()..color = fill);
  }

  void _drawEdit(Canvas c, Rect sc) {
    final x = sc.left + 14;
    final w = sc.width - 28;
    _bars(c, x, sc.top + 18, w, 5);
    final hy = sc.top + 66;
    const heading = 'The Cognitive Load of Fixed Layouts';
    final red = _seg(0.66, 0.74);
    final headColor = Color.lerp(const Color(0xFF30343C), const Color(0xFFE53935), red)!;
    final headWidth = _text(c, heading, x, hy, 8.5, headColor, bold: true);
    _bars(c, x, hy + 12, w, 6);
    // selection box + mini toolbar
    final sel = _seg(0.18, 0.26);
    if (sel > 0) {
      final r = Rect.fromLTRB(x - 3, hy - 10, x + headWidth + 3, hy + 4);
      _dashed(
        c,
        r,
        Paint()
          ..color = _a(0xFF1E6FE6, sel)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
        4,
        3,
      );
      final tb = Rect.fromLTRB(r.left + 16, r.top - 22, r.left + 76, r.top - 5);
      _shadowRRect(c, RRect.fromRectAndRadius(tb, const Radius.circular(5)), _a(0xFFFFFFFF, sel), 4, const Offset(0, 1), _a(0x33000000, sel * 0.2));
      final bar = Paint()..color = _a(0xFF5B6475, sel);
      for (var i = 0; i < 3; i++) {
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(tb.left + 8 + i * 18, tb.top + 5, tb.left + 16 + i * 18, tb.bottom - 5), const Radius.circular(2)), bar);
      }
    }
    // bottom: tools row, then the format panel sliding up
    final panel = _seg(0.40, 0.50);
    final baseY = sc.bottom - 44;
    const panelH = 70.0;
    final py = baseY - panelH * panel;
    final sheet = Rect.fromLTRB(sc.left, py, sc.right, sc.bottom);
    c.drawRect(
      sheet.shift(const Offset(0, -1)),
      Paint()
        ..color = const Color(0x22000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    c.drawRect(sheet, Paint()..color = Colors.white);
    final iconsY = py + 16;
    final step = sc.width / 5;
    for (var i = 0; i < 5; i++) {
      final cx = sc.left + step * (i + 0.5);
      final active = i == 3 && red > 0;
      final color = (i == 0 && panel == 0) || active ? const Color(0xFF1E6FE6) : const Color(0xFF5B6475);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(cx - 6, iconsY - 6, cx + 6, iconsY + 6), const Radius.circular(2)), Paint()..color = color);
    }
    if (panel > 0) {
      // size slider + B I S U
      c.drawLine(
        Offset(sc.left + 14, iconsY + 20),
        Offset(sc.left + sc.width * 0.6, iconsY + 20),
        Paint()
          ..color = const Color(0xFF1E6FE6)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      c.drawCircle(Offset(sc.left + 40, iconsY + 20), 4, Paint()..color = const Color(0xFF1E6FE6));
      const labels = ['B', 'I', 'S', 'U'];
      for (var i = 0; i < labels.length; i++) {
        final cx = sc.left + step * (i + 0.8);
        if (i == 0 && red > 0) c.drawCircle(Offset(cx, iconsY + 40), 9, Paint()..color = const Color(0xFFE3EDFD));
        final lw = _text(c, labels[i], 0, 0, 9, const Color(0xFF30343C), bold: true, measureOnly: true);
        _text(c, labels[i], cx - lw / 2, iconsY + 43, 9, const Color(0xFF30343C), bold: true);
      }
    }
    // finger taps
    _tap(c, sc.left + sc.width * 0.35, hy - 3, _seg(0.10, 0.20));
    _tap(c, sc.left + step * 0.8, iconsY + 40, _seg(0.56, 0.66));
  }

  void _drawSign(Canvas c, Rect sc) {
    final x = sc.left + 14;
    final w = sc.width - 28;
    const ink = Color(0xFF30343C);
    _text(c, '2. DEFAULT & GOVERNING LAW', x, sc.top + 24, 7, ink, bold: true);
    _bars(c, x, sc.top + 32, w, 3);
    _text(c, 'LENDER', x, sc.top + 70, 6.5, ink, bold: true);
    final borrowerW = _text(c, 'BORROWER', 0, 0, 6.5, ink, bold: true, measureOnly: true);
    _text(c, 'BORROWER', sc.right - 14 - borrowerW, sc.top + 70, 6.5, ink, bold: true);
    final line = Paint()
      ..color = const Color(0xFF9AA3AF)
      ..strokeWidth = 1;
    c.drawLine(Offset(x, sc.top + 92), Offset(x + 60, sc.top + 92), line);
    c.drawLine(Offset(sc.right - 74, sc.top + 92), Offset(sc.right - 14, sc.top + 92), line);
    // "+ Add signature" bar
    final barY = sc.bottom - 34;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x, barY - 14, sc.right - 14, barY + 10), const Radius.circular(10)), Paint()..color = const Color(0xFFEAF1FE));
    const label = '+  Add signature';
    final labelW = _text(c, label, 0, 0, 8, const Color(0xFF1E6FE6), bold: true, measureOnly: true);
    _text(c, label, sc.center.dx - labelW / 2, barY + 1, 8, const Color(0xFF1E6FE6), bold: true);
    _tap(c, sc.center.dx, barY - 2, _seg(0.06, 0.18));

    // signature pad
    final pad = _seg(0.22, 0.28) * (1 - _seg(0.62, 0.68));
    final sigBox = Rect.fromLTRB(sc.left + 22, sc.top + 36, sc.right - 22, sc.top + 96);
    final sig = _signature(sigBox);
    if (pad > 0) {
      final r = Rect.fromLTRB(sc.left + 8, sc.top + 20, sc.right - 8, sc.top + 118);
      _shadowRRect(c, RRect.fromRectAndRadius(r, const Radius.circular(10)), _a(0xFFFFFFFF, pad), 8, const Offset(0, 2), _a(0x33000000, pad * 0.2));
      if (_seg(0.30, 0.32) == 0) {
        final hintW = _text(c, 'Sign here', 0, 0, 16, const Color(0xFFD3D8E0), italic: true, measureOnly: true);
        _text(c, 'Sign here', r.center.dx - hintW / 2, r.center.dy + 5, 16, const Color(0xFFD3D8E0), italic: true);
      }
      _drawSignature(c, sig, _seg(0.30, 0.56), 0xFF1F2A8C, pad);
      const colors = [0xFF111111, 0xFF5F6673, 0xFF1F2A5C, 0xFF1E5BE6, 0xFF7A1F2B, 0xFFE53935];
      for (var i = 0; i < colors.length; i++) {
        c.drawCircle(Offset(r.left + 14 + i * 12, r.bottom - 10), 3.5, Paint()..color = _a(colors[i], pad));
      }
    }
    // placed on the page next to BORROWER
    final placed = _seg(0.68, 0.76);
    if (placed > 0) {
      final target = Rect.fromLTRB(sc.right - 78, sc.top + 74, sc.right - 14, sc.top + 92);
      c.save();
      c.translate(target.left, target.top);
      c.scale(target.width / (sc.width - 44), target.height / 60);
      c.translate(-(sc.left + 22), -(sc.top + 36));
      _drawSignature(c, sig, 1, 0xFF1F2A8C, placed);
      c.restore();
      _dashed(
        c,
        target.inflate(3),
        Paint()
          ..color = _a(0xFF1E6FE6, placed)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
        3,
        2,
      );
    }
  }

  Path _signature(Rect r) {
    final w = r.width;
    final h = r.height;
    Offset at(double fx, double fy) => Offset(r.left + w * fx, r.top + h * fy);
    final path = Path();
    final start = at(0.18, 0.35);
    path.moveTo(start.dx, start.dy);
    void cubic(double a, double b, double c, double d, double e, double f) {
      final p1 = at(a, b);
      final p2 = at(c, d);
      final p3 = at(e, f);
      path.cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);
    }

    cubic(0.24, 0.05, 0.30, 0.95, 0.20, 0.85);
    cubic(0.12, 0.75, 0.30, 0.45, 0.40, 0.55);
    cubic(0.46, 0.62, 0.50, 0.35, 0.55, 0.20);
    cubic(0.56, 0.60, 0.60, 0.75, 0.66, 0.48);
    cubic(0.70, 0.40, 0.74, 0.75, 0.84, 0.50);
    return path;
  }

  void _drawSignature(Canvas c, Path sig, double progress, int color, double alpha) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = _a(color, alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final metrics = sig.computeMetrics().toList();
    final total = metrics.fold<double>(0, (sum, metric) => sum + metric.length);
    var left = total * progress;
    for (final metric in metrics) {
      if (left <= 0) break;
      c.drawPath(metric.extractPath(0, math.min(left, metric.length)), paint);
      left -= metric.length;
    }
  }

  /// Blue touch ripple.
  void _tap(Canvas c, double x, double y, double k) {
    if (k <= 0 || k >= 1) return;
    c.drawCircle(Offset(x, y), 6 + 8 * k, Paint()..color = _a(0xFF4D8DFF, 200 / 255 * (1 - k)));
  }

  void _dashed(Canvas c, Rect rect, Paint paint, double dash, double gap) {
    final path = Path()..addRect(rect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        c.drawPath(metric.extractPath(distance, math.min(metric.length, distance + dash)), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant TutorialDemoPainter oldDelegate) => oldDelegate.t != t || oldDelegate.sign != sign;
}
