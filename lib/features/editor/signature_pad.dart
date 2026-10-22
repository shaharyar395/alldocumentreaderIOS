import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../create/tool_widgets.dart';
import '../../services/signature_store.dart';

const signatureColors = <int>[0xFF111111, 0xFF5F6673, 0xFF1F2A5C, 0xFF1E5BE6, 0xFF7A1F2B, 0xFFE53935];

/// Signature pad: draw with a finger; colours (changing it recolours the whole signature), pen
/// width, undo / redo, clear, ✓. Returns the signature trimmed to the drawn part.
class SignaturePadPage extends StatefulWidget {
  const SignaturePadPage({super.key});

  @override
  State<SignaturePadPage> createState() => _SignaturePadPageState();
}

class _SignaturePadPageState extends State<SignaturePadPage> {
  final List<List<Offset>> _strokes = [];
  final List<List<Offset>> _redo = [];
  int _color = signatureColors.first;

  /// Pen width 1–100 like the native pad ("20" by default): 1dp + value / 100 × 12dp.
  int _widthValue = 20;
  double get _width => 1 + _widthValue / 100 * 12;
  Size _pad = Size.zero;

  void _finish() {
    final points = _strokes.expand((stroke) => stroke).toList();
    if (points.isEmpty || _pad.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final point in points) {
      minX = math.min(minX, point.dx);
      maxX = math.max(maxX, point.dx);
      minY = math.min(minY, point.dy);
      maxY = math.max(maxY, point.dy);
    }
    final margin = _width;
    minX -= margin;
    minY -= margin;
    maxX += margin;
    maxY += margin;
    final w = math.max(8.0, maxX - minX);
    final h = math.max(8.0, maxY - minY);
    final strokes = [
      for (final stroke in _strokes) [for (final point in stroke) Offset((point.dx - minX) / w, (point.dy - minY) / h)],
    ];
    Navigator.of(context).pop(Signature(strokes: strokes, color: _color, width: _width / w, aspect: w / h));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final has = _strokes.isNotEmpty;
    return Scaffold(
      backgroundColor: nc.surface,
      body: SafeArea(
        child: Column(
          children: [
            // activity_signature_pad.xml: × … undo redo … [Done]
            Container(
              height: 52,
              padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
              child: Row(
                children: [
                  NativeIconButton(ND.icClose, padding: 11, tint: nc.textPrimary, tooltip: s.t('cancel'), onPressed: () => Navigator.of(context).pop()),
                  const Spacer(),
                  NativeIconButton(
                    ND.icUndo,
                    tint: has ? nc.textPrimary : const Color(0xFFC3C8D0),
                    tooltip: s.t('undo'),
                    onPressed: has ? () => setState(() => _redo.add(_strokes.removeLast())) : null,
                  ),
                  NativeIconButton(
                    ND.icRedo,
                    tint: _redo.isNotEmpty ? nc.textPrimary : const Color(0xFFC3C8D0),
                    tooltip: s.t('redo'),
                    onPressed: _redo.isEmpty ? null : () => setState(() => _strokes.add(_redo.removeLast())),
                  ),
                  const Spacer(),
                  Material(
                    color: has ? const Color(0xFF111317) : const Color(0xFFD9DCE1),
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: has ? _finish : null,
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        alignment: Alignment.center,
                        child: Text(s.t('done'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: nc.surfaceVariant,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _pad = constraints.biggest;
                    return GestureDetector(
                      onPanStart: (details) => setState(() {
                        _redo.clear();
                        _strokes.add([details.localPosition]);
                      }),
                      onPanUpdate: (details) => setState(() => _strokes.last.add(details.localPosition)),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _PadPainter(_strokes, Color(_color), _width, hint: has ? null : s.t('signHere')),
                      ),
                    );
                  },
                ),
              ),
            ),
            // colours (26dp, ✓ 14dp), pen width SeekBar + value, clear
            Container(
              height: 56,
              padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
              child: Row(
                children: [
                  for (final color in signatureColors)
                    GestureDetector(
                      onTap: () => setState(() => _color = color),
                      child: Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsetsDirectional.only(end: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: Color(color), shape: BoxShape.circle),
                        child: _color == color ? const NativeIcon(ND.icCheck, size: 14, tint: Colors.white) : null,
                      ),
                    ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: nc.primary,
                        inactiveTrackColor: nc.primary.withValues(alpha: 0.24),
                        thumbColor: nc.primary,
                        overlayColor: nc.primary.withValues(alpha: 0.12),
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      ),
                      child: Slider(
                        value: _widthValue.toDouble(),
                        min: 1,
                        max: 100,
                        onChanged: (value) => setState(() => _widthValue = value.round()),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text('$_widthValue', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: nc.textSecondary)),
                  ),
                  NativeIconButton(
                    ND.icDelete,
                    padding: 11,
                    tint: nc.textSecondary,
                    tooltip: s.t('clearText'),
                    onPressed: has || _redo.isNotEmpty
                        ? () => setState(() {
                              _strokes.clear();
                              _redo.clear();
                            })
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color, this.width, {this.hint});

  final List<List<Offset>> strokes;
  final Color color;
  final double width;
  final String? hint;

  /// "Sign here" 44sp italic #D3D8E0 in the middle, a 1dp #D3D8E0 line 48dp above the bottom
  /// with 48dp side margins.
  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = const Color(0xFFD3D8E0)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(48, size.height - 48.5), Offset(size.width - 48, size.height - 48.5), baseline);
    final text = hint;
    if (text != null) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Color(0xFFD3D8E0), fontSize: 44, fontStyle: FontStyle.italic)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: size.width);
      painter.paint(canvas, Offset((size.width - painter.width) / 2, (size.height - painter.height) / 2));
      painter.dispose();
    }
    drawStrokes(canvas, strokes, color, width);
  }

  @override
  bool shouldRepaint(covariant _PadPainter oldDelegate) => true;
}

/// Smooth pen strokes (quadratic curves through the points).
void drawStrokes(Canvas canvas, List<List<Offset>> strokes, Color color, double width) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  for (final stroke in strokes) {
    if (stroke.isEmpty) continue;
    if (stroke.length == 1) {
      canvas.drawCircle(stroke.first, width / 2, Paint()..color = color);
      continue;
    }
    final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
    for (var i = 1; i < stroke.length - 1; i++) {
      final mid = (stroke[i] + stroke[i + 1]) / 2;
      path.quadraticBezierTo(stroke[i].dx, stroke[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(stroke.last.dx, stroke.last.dy);
    canvas.drawPath(path, paint);
  }
}

/// "How to edit": Edit PDF / Sign tabs with a small illustration, Try now and Later.
/// Returns 'edit' or 'sign' for Try now.
Future<String?> showEditTutorial(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => const _Tutorial(),
  );
}

class _Tutorial extends StatefulWidget {
  const _Tutorial();

  @override
  State<_Tutorial> createState() => _TutorialState();
}

class _TutorialState extends State<_Tutorial> with TickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _anim.dispose();
    super.dispose();
  }

  /// sheet_edit_tutorial.xml: 300dp bg_tutorial_stage with the demo and an "Edit PDF | Sign" pill
  /// (bg_tut_tabs / bg_tut_tab), title 18sp bold, Try now (50dp bg_apply_btn), Later (primary).
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final sign = _tabs.index == 1;
    Widget tab(String label, int index) {
      final on = _tabs.index == index;
      return GestureDetector(
        onTap: () => _tabs.animateTo(index),
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
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(
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
                    top: 52,
                    child: AnimatedBuilder(
                      animation: _anim,
                      builder: (context, _) => CustomPaint(
                        painter: _TutorialPainter(progress: _anim.value, sign: sign, blue: const Color(0xFF1E6FE6)),
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
                          children: [tab(s.t('editPdf'), 0), tab(s.t('sign'), 1)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              sign ? s.t('tutSignTitle') : s.t('tutEditTitle'),
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
                onPressed: () => Navigator.pop(context, sign ? 'sign' : 'edit'),
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

class _TutorialPainter extends CustomPainter {
  _TutorialPainter({required this.progress, required this.sign, required this.blue});

  final double progress;
  final bool sign;
  final Color blue;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Rect.fromCenter(center: Offset(size.width / 2, math.min(size.height / 2, 110)), width: 150, height: 186);
    canvas.drawRRect(RRect.fromRectAndRadius(page.shift(const Offset(0, 3)), const Radius.circular(8)), Paint()..color = const Color(0x22000000));
    canvas.drawRRect(RRect.fromRectAndRadius(page, const Radius.circular(8)), Paint()..color = Colors.white);
    final ink = Paint()
      ..color = const Color(0xFFC9D0DC)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final y = page.top + 26 + i * 18.0;
      canvas.drawLine(Offset(page.left + 16, y), Offset(page.right - (i.isOdd ? 40 : 16), y), ink);
    }
    final t = Curves.easeInOut.transform(progress < 0.8 ? progress / 0.8 : 1);
    if (sign) {
      final strokes = <Offset>[];
      const steps = 40;
      for (var i = 0; i <= (steps * t).round(); i++) {
        final x = i / steps;
        strokes.add(Offset(page.left + 24 + x * 100, page.bottom - 40 + math.sin(x * math.pi * 3) * 12 - x * 6));
      }
      drawStrokes(canvas, [strokes], const Color(0xFF1E5BE6), 3);
      final box = Rect.fromLTWH(page.left + 16, page.bottom - 66, 118, 46);
      canvas.drawRect(
        box,
        Paint()
          ..color = blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    } else {
      final box = Rect.fromLTWH(page.left + 12, page.top + 60, 126 * t + 4, 26);
      canvas.drawRect(box, Paint()..color = Colors.white);
      canvas.drawRect(
        box,
        Paint()
          ..color = blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final painter = TextPainter(
        text: TextSpan(text: 'Hello PDF'.substring(0, (9 * t).round().clamp(0, 9)), style: const TextStyle(color: Color(0xFFE91E8C), fontSize: 18, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(box.left + 6, box.top + 2));
    }
    // finger
    final finger = sign ? Offset(page.left + 24 + 100 * t, page.bottom - 30) : Offset(page.left + 20 + 120 * t, page.top + 92);
    canvas.drawCircle(finger, 12, Paint()..color = blue.withValues(alpha: 0.25));
    canvas.drawCircle(finger, 6, Paint()..color = blue);
  }

  @override
  bool shouldRepaint(covariant _TutorialPainter oldDelegate) => true;
}
