import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/signature_store.dart';
import '../create/tool_widgets.dart';

/// SignaturePadActivity.colors: black, grey, navy, blue, wine, red.
const signatureColors = <int>[0xFF111111, 0xFF5F6673, 0xFF1F2A5C, 0xFF1E5BE6, 0xFF7A1F2B, 0xFFE53935];

/// Opens the signature pad and returns the drawn signature (not saved yet), or null.
Future<Signature?> drawSignature(BuildContext context) {
  return Navigator.of(context).push<Signature>(MaterialPageRoute(builder: (_) => const SignaturePadPage()));
}

class _Stroke {
  _Stroke(this.points, this.width);
  final List<Offset> points;
  final double width;
}

/// SignaturePadActivity (screenOrientation sensorLandscape): "Sign here", 6 ink colours (picking
/// one recolours the whole signature), pen width 1–100 (20 by default), clear, undo / redo, Done.
/// Returns the signature trimmed to the ink (+ the widest pen + 6 px around it, like export()).
class SignaturePadPage extends StatefulWidget {
  const SignaturePadPage({super.key});

  @override
  State<SignaturePadPage> createState() => _SignaturePadPageState();
}

class _SignaturePadPageState extends State<SignaturePadPage> {
  final List<_Stroke> _strokes = [];
  final List<_Stroke> _undone = [];
  _Stroke? _current;
  int _color = signatureColors.first;

  /// Pen width 1–100 like the native pad ("20" by default): 1dp + value / 100 × 12dp.
  int _widthValue = 20;
  double get _width => 1 + _widthValue / 100 * 12;
  Size _pad = Size.zero;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  bool get _hasInk => _strokes.isNotEmpty;

  void _done() {
    if (_strokes.isEmpty || _pad.isEmpty) return;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    var widest = 0.0;
    for (final stroke in _strokes) {
      widest = math.max(widest, stroke.width);
      for (final point in stroke.points) {
        minX = math.min(minX, point.dx);
        maxX = math.max(maxX, point.dx);
        minY = math.min(minY, point.dy);
        maxY = math.max(maxY, point.dy);
      }
    }
    final pad = widest + 6;
    final left = math.max(0.0, minX - pad);
    final top = math.max(0.0, minY - pad);
    final right = math.min(_pad.width, maxX + pad);
    final bottom = math.min(_pad.height, maxY + pad);
    final w = math.max(1.0, right - left);
    final h = math.max(1.0, bottom - top);
    final strokes = [
      for (final stroke in _strokes) [for (final point in stroke.points) Offset((point.dx - left) / w, (point.dy - top) / h)],
    ];
    Navigator.of(context).pop(
      Signature(
        strokes: strokes,
        color: _color,
        width: widest / w,
        widths: [for (final stroke in _strokes) stroke.width / w],
        aspect: w / h,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    const off = Color(0xFFC3C8D0);
    return PopScope(
      // back to portrait as soon as the pad starts closing (not after the animation)
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      },
      child: Scaffold(
      backgroundColor: nc.surface,
      body: SafeArea(
        child: Column(
          children: [
            // × … undo redo … [Done]
            Container(
              height: 52,
              padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
              child: Row(
                children: [
                  NativeIconButton(ND.icClose, padding: 11, tint: nc.textPrimary, tooltip: s.t('cancel'), onPressed: () => Navigator.of(context).pop()),
                  const Spacer(),
                  NativeIconButton(
                    ND.icUndo,
                    tint: _strokes.isNotEmpty ? nc.textPrimary : off,
                    tooltip: s.t('undo'),
                    onPressed: _strokes.isEmpty ? null : () => setState(() => _undone.add(_strokes.removeLast())),
                  ),
                  NativeIconButton(
                    ND.icRedo,
                    tint: _undone.isNotEmpty ? nc.textPrimary : off,
                    tooltip: s.t('redo'),
                    onPressed: _undone.isEmpty ? null : () => setState(() => _strokes.add(_undone.removeLast())),
                  ),
                  const Spacer(),
                  // bg_done_btn: #111317, #D9DCE1 while there is no ink
                  Material(
                    color: _hasInk ? const Color(0xFF111317) : const Color(0xFFD9DCE1),
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: _hasInk ? _done : null,
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
                      behavior: HitTestBehavior.opaque,
                      onPanDown: (details) => setState(() => _current = _Stroke([details.localPosition], _width)),
                      onPanUpdate: (details) {
                        final current = _current;
                        if (current == null) return;
                        setState(() => current.points.add(details.localPosition));
                      },
                      onPanEnd: (_) => _endStroke(),
                      onPanCancel: _endStroke,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _PadPainter(
                          [..._strokes, if (_current != null) _current!],
                          Color(_color),
                          hint: _hasInk ? null : s.t('signHere'),
                        ),
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
                        showValueIndicator: ShowValueIndicator.never,
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
                    onPressed: () => setState(() {
                      _strokes.clear();
                      _undone.clear();
                      _current = null;
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _endStroke() {
    final current = _current;
    if (current == null) return;
    setState(() {
      _strokes.add(current);
      _undone.clear();
      _current = null;
    });
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color, {this.hint});

  final List<_Stroke> strokes;
  final Color color;
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
    drawStrokes(canvas, [for (final stroke in strokes) stroke.points], color, 1, widths: [for (final stroke in strokes) stroke.width]);
  }

  @override
  bool shouldRepaint(covariant _PadPainter oldDelegate) => true;
}

/// Smooth pen strokes (quadratic curves through the points, like SignatureView's quadTo), round
/// caps and joins. [widths] (one per stroke) wins over [width].
void drawStrokes(Canvas canvas, List<List<Offset>> strokes, Color color, double width, {List<double>? widths}) {
  for (var index = 0; index < strokes.length; index++) {
    final stroke = strokes[index];
    if (stroke.isEmpty) continue;
    final strokeWidth = widths != null && index < widths.length ? widths[index] : width;
    if (stroke.length == 1) {
      canvas.drawCircle(stroke.first, strokeWidth / 2, Paint()..color = color);
      continue;
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(strokePath(stroke), paint);
  }
}

/// The smoothed path of one stroke.
Path strokePath(List<Offset> stroke) {
  final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
  for (var i = 1; i < stroke.length - 1; i++) {
    final mid = (stroke[i] + stroke[i + 1]) / 2;
    path.quadraticBezierTo(stroke[i].dx, stroke[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(stroke.last.dx, stroke.last.dy);
  return path;
}
