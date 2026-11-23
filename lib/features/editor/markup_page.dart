import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdfx/pdfx.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../services/image_ops.dart';
import '../../services/pdf_rewrite.dart';
import '../../services/pdf_tools.dart';
import '../../services/signature_store.dart';
import '../../widgets/chrome.dart';
import '../create/tool_widgets.dart';
import '../reader/pdf_pages.dart';
import 'edit_tutorial.dart';
import 'editor_flow.dart';
import 'signature_pad.dart';

/// The 15 colours of Add text / Annotate (PdfEditActivity.palette).
const editColors = <int>[
  0xFF000000, 0xFFFFFFFF, 0xFF8A8F98, 0xFFE53935, 0xFF22C55E, //
  0xFF1E3FE6, 0xFFE91E8C, 0xFF22D3EE, 0xFFFF6A13, 0xFFFBBF24,
  0xFFA3E635, 0xFF2DD4BF, 0xFF38BDF8, 0xFF8B3CF6, 0xFFF87171,
];

const _pink = 0xFFE91E8C;
const _red = 0xFFE53935;
const _yellow = 0xFFFBBF24;

/// PdfEditActivity.Mode: which bottom panel is open.
enum _Panel { none, editText, addText, annotate, sign }

/// EditTool: what a touch on a page does.
enum _Tool { none, editText, objects, pen, highlight, underline, strike, eraser }

/// EditLayerView gesture state.
enum _Op { none, tap, move, rotate, scale, widthL, widthR, draw, mark, erase }

enum _Claim { ignore, pending, now }

// ------------------------------------------------------------------ items (EditModels.kt)
//
// Everything placed on a page. Coordinates are in "page-width units": x and y are both divided
// by the page's width, so 1.0 = the page width in either direction.

abstract class _Item {
  _Item copy();
}

/// Typed text in a box of [width]; [size] = font size; [cover] = white-out behind it (Edit text).
class _TextItem extends _Item {
  _TextItem({required this.text, required this.cx, required this.cy, required this.width, required this.size, required this.color, this.rotation = 0, this.cover});

  String text;
  double cx;
  double cy;
  double width;
  double size;
  int color;
  double rotation;
  final Rect? cover;

  @override
  _TextItem copy() => _TextItem(text: text, cx: cx, cy: cy, width: width, size: size, color: color, rotation: rotation, cover: cover);
}

/// A picture ([bytes] / [image]) or a signature ([sign]). Height follows its proportions.
class _ImageItem extends _Item {
  _ImageItem({required this.cx, required this.cy, required this.width, this.rotation = 0, this.bytes, this.image, this.sign});

  double cx;
  double cy;
  double width;
  double rotation;
  Uint8List? bytes;
  ui.Image? image;
  Signature? sign;

  bool get signature => sign != null;

  /// width / height.
  double get aspect {
    final s = sign;
    if (s != null) return math.max(0.05, s.aspect);
    final picture = image;
    if (picture == null) return 1;
    return picture.width / math.max(1, picture.height);
  }

  double get height => width / aspect;

  @override
  _ImageItem copy() => _ImageItem(cx: cx, cy: cy, width: width, rotation: rotation, bytes: bytes, image: image, sign: sign);
}

/// Free-hand pen line.
class _InkItem extends _Item {
  _InkItem(this.points, this.color, this.width);

  final List<Offset> points;
  final int color;
  final double width;

  @override
  _InkItem copy() => _InkItem(List<Offset>.of(points), color, width);
}

enum _MarkKind { highlight, underline, strike }

/// Highlight / underline / strikethrough over a span of the page.
class _MarkItem extends _Item {
  _MarkItem(this.kind, this.rect, this.color);

  final _MarkKind kind;
  final Rect rect;
  final int color;

  @override
  _MarkItem copy() => _MarkItem(kind, rect, color);
}

/// A line of real text found in the PDF (for Edit text), in page-width units.
class _Line {
  _Line(this.text, this.rect, this.size);

  final String text;
  final Rect rect;
  final double size;
}

// ------------------------------------------------------------------ EditRenderer

/// First strong character decides the paragraph direction (StaticLayout's FIRSTSTRONG_LTR).
TextDirection _direction(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x08FF) || (rune >= 0xFB1D && rune <= 0xFDFF) || (rune >= 0xFE70 && rune <= 0xFEFF)) return TextDirection.rtl;
    final neutral = rune < 0x41 || (rune >= 0x5B && rune <= 0x60) || (rune >= 0x7B && rune <= 0xBF) || (rune >= 0x2000 && rune <= 0x206F);
    if (!neutral) return TextDirection.ltr;
  }
  return TextDirection.ltr;
}

/// Laid-out texts, reused while nothing about them changes.
final Map<String, TextPainter> _layouts = {};

/// StaticLayout of [t] on a page [w] pixels wide: font size size × w, box width width × w.
TextPainter _textLayout(_TextItem t, double w) {
  final fontSize = math.max(1.0, t.size * w);
  final boxWidth = math.max(1.0, t.width * w);
  final key = '${t.color}|${fontSize.toStringAsFixed(2)}|${boxWidth.toStringAsFixed(2)}|${t.text}';
  final cached = _layouts.remove(key);
  if (cached != null) {
    _layouts[key] = cached;
    return cached;
  }
  final painter = TextPainter(
    text: TextSpan(text: t.text, style: TextStyle(fontSize: fontSize, color: Color(t.color))),
    textDirection: _direction(t.text),
  )..layout(minWidth: boxWidth, maxWidth: boxWidth);
  _layouts[key] = painter;
  while (_layouts.length > 80) {
    final oldest = _layouts.keys.first;
    _layouts.remove(oldest)?.dispose();
  }
  return painter;
}

/// Natural single-line width of [text] at [size] (page-width units).
double _measure(String text, double size) {
  var widest = 0.0;
  for (final line in text.split('\n')) {
    final painter = TextPainter(
      text: TextSpan(text: line.isEmpty ? ' ' : line, style: const TextStyle(fontSize: 100)),
      textDirection: _direction(line),
    )..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  return widest / 100 * size * 1.04 + size * 0.1;
}

/// Box size of a text or image item in pixels.
Size _boxSize(_Item item, double w) {
  if (item is _TextItem) return Size(item.width * w, _textLayout(item, w).height);
  if (item is _ImageItem) return Size(item.width * w, item.height * w);
  return Size.zero;
}

Offset _center(_Item item, double w) {
  if (item is _TextItem) return Offset(item.cx * w, item.cy * w);
  if (item is _ImageItem) return Offset(item.cx * w, item.cy * w);
  return Offset.zero;
}

/// Degrees, clockwise.
double _rotationOf(_Item item) {
  if (item is _TextItem) return item.rotation;
  if (item is _ImageItem) return item.rotation;
  return 0;
}

double _rad(double degrees) => degrees * math.pi / 180;

/// Point in the item's local frame (unrotated, centre = 0,0).
Offset _toLocal(_Item item, double w, Offset p) {
  final v = p - _center(item, w);
  final a = -_rad(_rotationOf(item));
  return Offset(v.dx * math.cos(a) - v.dy * math.sin(a), v.dx * math.sin(a) + v.dy * math.cos(a));
}

void _drawItems(Canvas canvas, List<_Item> items, double w, {_Item? skip}) {
  // white-out under edited text first
  final white = Paint()..color = Colors.white;
  for (final item in items) {
    if (item is _TextItem && item.cover != null) {
      final c = item.cover!;
      canvas.drawRect(Rect.fromLTRB(c.left * w, c.top * w, c.right * w, c.bottom * w), white);
    }
  }
  for (final item in items) {
    if (!identical(item, skip)) _drawItem(canvas, item, w);
  }
}

void _drawItem(Canvas canvas, _Item item, double w) {
  if (item is _MarkItem) {
    final r = item.rect;
    if (item.kind == _MarkKind.highlight) {
      canvas.drawRect(Rect.fromLTRB(r.left * w, r.top * w, r.right * w, r.bottom * w), Paint()..color = Color(item.color).withAlpha(90));
    } else {
      final y = item.kind == _MarkKind.underline ? r.bottom * w : (r.top + r.bottom) / 2 * w;
      canvas.drawLine(
        Offset(r.left * w, y),
        Offset(r.right * w, y),
        Paint()
          ..color = Color(item.color)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1.5, (r.bottom - r.top) * w * 0.09),
      );
    }
  } else if (item is _InkItem) {
    final p = item.points;
    if (p.isEmpty) return;
    final path = Path()..moveTo(p.first.dx * w, p.first.dy * w);
    if (p.length == 1) path.lineTo(p.first.dx * w + 0.1, p.first.dy * w);
    for (final point in p.skip(1)) {
      path.lineTo(point.dx * w, point.dy * w);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Color(item.color)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.max(1.0, item.width * w),
    );
  } else if (item is _TextItem) {
    final layout = _textLayout(item, w);
    canvas.save();
    canvas.translate(item.cx * w, item.cy * w);
    canvas.rotate(_rad(item.rotation));
    layout.paint(canvas, Offset(-item.width * w / 2, -layout.height / 2));
    canvas.restore();
  } else if (item is _ImageItem) {
    final bw = item.width * w;
    final bh = item.height * w;
    canvas.save();
    canvas.translate(item.cx * w, item.cy * w);
    canvas.rotate(_rad(item.rotation));
    final rect = Rect.fromLTWH(-bw / 2, -bh / 2, bw, bh);
    final sign = item.sign;
    final picture = item.image;
    if (sign != null) {
      canvas.translate(rect.left, rect.top);
      drawStrokes(
        canvas,
        [
          for (final stroke in sign.strokes) [for (final p in stroke) Offset(p.dx * bw, p.dy * bh)],
        ],
        Color(sign.color),
        sign.width * bw,
        widths: [for (final value in sign.widths) math.max(0.5, value * bw)],
      );
    } else if (picture != null) {
      canvas.drawImageRect(
        picture,
        Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..isAntiAlias = true,
      );
    }
    canvas.restore();
  }
}

/// Handles around a selected item, in its local frame: × delete (top-left), duplicate
/// (bottom-left), resize + rotate (bottom-right); text has side dots for the box width,
/// pictures and signatures a pencil (top-right) to replace them.
Map<String, Offset> _handles(_Item item, double w, double pad) {
  final box = _boxSize(item, w);
  final l = -box.width / 2 - pad;
  final r = box.width / 2 + pad;
  final t = -box.height / 2 - pad;
  final b = box.height / 2 + pad;
  return {
    'delete': Offset(l, t),
    'copy': Offset(l, b),
    'scale': Offset(r, b),
    if (item is _TextItem) 'left': Offset(l, 0),
    if (item is _TextItem) 'right': Offset(r, 0),
    if (item is _ImageItem) 'edit': Offset(r, t),
  };
}

/// A dashed rectangle ([dash] on, [gap] off, starting [phase] into the pattern).
void _dashedRect(Canvas canvas, Rect rect, Paint paint, double dash, double gap, double phase) {
  final path = Path()..addRect(rect);
  for (final metric in path.computeMetrics()) {
    var distance = -phase;
    while (distance < metric.length) {
      final start = math.max(0.0, distance);
      final end = math.min(metric.length, distance + dash);
      if (end > start) canvas.drawPath(metric.extractPath(start, end), paint);
      distance += dash + gap;
    }
  }
}

/// EditRenderer.drawSelection: pictures / signatures get a solid #1E6FE6 box, text a
/// white-over-dark dashed box; white 9dp handles with a #33000000 ring and stroked icons.
void _drawSelection(Canvas canvas, _Item item, double w) {
  const pad = 6.0;
  final box = _boxSize(item, w);
  final c = _center(item, w);
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.rotate(_rad(_rotationOf(item)));
  final rect = Rect.fromLTRB(-box.width / 2 - pad, -box.height / 2 - pad, box.width / 2 + pad, box.height / 2 + pad);
  if (item is _ImageItem) {
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF1E6FE6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  } else {
    _dashedRect(
      canvas,
      rect,
      Paint()
        ..color = const Color(0x99000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
      5,
      4,
      0,
    );
    _dashedRect(
      canvas,
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
      5,
      4,
      5,
    );
  }
  const r = 9.0;
  const k = r * 0.45;
  final fill = Paint()..color = Colors.white;
  final ring = Paint()
    ..color = const Color(0x33000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  Paint icon(int color) => Paint()
    ..color = Color(color)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = 1.5;
  _handles(item, w, pad).forEach((name, p) {
    final x = p.dx;
    final y = p.dy;
    if (name == 'left' || name == 'right') {
      canvas.drawCircle(p, 4, fill);
      canvas.drawCircle(p, 4, ring);
      return;
    }
    canvas.drawCircle(p, r, fill);
    canvas.drawCircle(p, r, ring);
    final ink = icon(0xFF1B1F2A);
    switch (name) {
      case 'delete':
        final red = icon(0xFFF0483E);
        const d = r * 0.38;
        canvas.drawLine(Offset(x - d, y - d), Offset(x + d, y + d), red);
        canvas.drawLine(Offset(x + d, y - d), Offset(x - d, y + d), red);
      case 'copy':
        const s = k * 1.1;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x - s * 0.9, y - s * 0.4, x + s * 0.4, y + s * 0.9), const Radius.circular(1.5)), ink);
        canvas.drawLine(Offset(x - s * 0.4, y - s * 0.9), Offset(x + s * 0.9, y - s * 0.9), ink);
        canvas.drawLine(Offset(x + s * 0.9, y - s * 0.9), Offset(x + s * 0.9, y + s * 0.4), ink);
      case 'edit':
        canvas.drawLine(Offset(x - k, y + k), Offset(x + k * 0.8, y - k * 0.8), ink);
        canvas.drawLine(Offset(x - k, y + k), Offset(x - k * 0.55, y + k * 0.1), ink);
        canvas.drawLine(Offset(x - k, y + k), Offset(x - k * 0.1, y + k * 0.55), ink);
      case 'scale':
        if (item is _ImageItem) {
          // circular arrows: rotate + resize
          final arc = Rect.fromLTRB(x - k, y - k, x + k, y + k);
          canvas.drawArc(arc, _rad(200), _rad(130), false, ink);
          canvas.drawArc(arc, _rad(20), _rad(130), false, ink);
          canvas.drawLine(Offset(x + k * 0.5, y - k * 0.87), Offset(x + k * 0.95, y - k * 0.95), ink);
          canvas.drawLine(Offset(x - k * 0.5, y + k * 0.87), Offset(x - k * 0.95, y + k * 0.95), ink);
        } else {
          canvas.drawLine(Offset(x - k, y - k), Offset(x + k, y + k), ink);
          canvas.drawLine(Offset(x + k, y + k), Offset(x + k * 0.1, y + k), ink);
          canvas.drawLine(Offset(x + k, y + k), Offset(x + k, y + k * 0.1), ink);
          canvas.drawLine(Offset(x - k, y - k), Offset(x - k * 0.1, y - k), ink);
          canvas.drawLine(Offset(x - k, y - k), Offset(x - k, y - k * 0.1), ink);
        }
    }
  });
  canvas.restore();
}

// ------------------------------------------------------------------ the editor

/// PDF editor (PdfEditActivity): every page in a scrolling list on black; Edit text (retype real
/// text lines), Add text, Add image, Annotate (pen, highlight, underline, strikethrough, eraser;
/// colour and size), Sign (signature pad, saved signatures). Texts, pictures and signatures can
/// be moved (also onto another page), resized + turned (bottom-right), made wider (text side
/// dots), duplicated, replaced (pencil) and deleted. Undo / redo; Done writes everything into the
/// PDF, shows "Saved successfully" and stays open; "i" shows the animated how-to.
/// Pops with true when the PDF was saved at least once.
class MarkupPage extends StatefulWidget {
  const MarkupPage({super.key, required this.entry, required this.tool, this.page = 0});

  final DocEntry entry;
  final MarkTool tool;

  /// 0-based page shown first (the reader's current page).
  final int page;

  @override
  State<MarkupPage> createState() => _MarkupPageState();
}

class _MarkupPageState extends State<MarkupPage> {
  String _path = '';
  PdfPages? _pdf;
  int _docGen = 0;
  int _count = 0;
  Future<void>? _sizesJob;
  bool _userScrolled = false;

  final Map<int, List<_Item>> _items = {};
  List<List<PdfTextLine>>? _rawLines;
  bool _linesLoaded = false;
  List<Signature> _signatures = [];

  _Panel _panel = _Panel.none;
  _Tool _annTool = _Tool.pen;
  bool _saving = false;
  bool _savedOnce = false;
  _Item? _selected;

  // tool settings
  int _textColor = _pink;
  int _textSizeValue = 72;
  int _annColor = _red;
  int _annSize = 30;
  bool _annColorsTab = true;
  bool _sizeListOpen = false;

  // history
  final List<Map<int, List<_Item>>> _undo = [];
  final List<Map<int, List<_Item>>> _redo = [];
  Map<int, List<_Item>> _last = {};

  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _layerKeys = {};
  final GlobalKey _viewportKey = GlobalKey();
  final _Ticker _repaint = _Ticker();

  // gesture state (EditLayerView)
  _Op _op = _Op.none;
  int _gesturePage = -1;
  _Item? _target;
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  bool _moved = false;
  bool _changed = false;
  bool _wasSelected = false;
  double _startAngle = 0;
  double _startRotation = 0;
  double _startDist = 1;
  double _startWidth = 0;
  double _startSize = 0;
  List<Offset> _drawing = [];
  Rect? _markRect;

  // a text / picture being dragged is drawn above every page
  bool _lifted = false;
  Offset _liftOrigin = Offset.zero;
  double _liftWidth = 1;

  static const _textSizes = <int>[6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 36, 48, 56, 72];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_path.isNotEmpty) return;
    _path = AppScope.of(context).library.fileOf(widget.entry).path;
    _annTool = switch (widget.tool) {
      MarkTool.highlight => _Tool.highlight,
      MarkTool.underline => _Tool.underline,
      MarkTool.strike => _Tool.strike,
      MarkTool.eraser => _Tool.eraser,
      _ => _Tool.pen,
    };
    _start();
  }

  @override
  void dispose() {
    _detachDoc()?.close();
    _scroll.dispose();
    _repaint.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _openDoc()) {
      if (!mounted) return;
      showToast(context, S.of(context).t('pdfProtected'), warning: true);
      Navigator.of(context).pop(false);
      return;
    }
    if (widget.page > 0) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToStart());
    final initial = switch (widget.tool) {
      MarkTool.editText => _Panel.editText,
      MarkTool.text => _Panel.addText,
      MarkTool.sign => _Panel.sign,
      MarkTool.none || MarkTool.image => _Panel.none,
      _ => _Panel.annotate,
    };
    _loadSignatures();
    _loadLines(initial: initial);
  }

  Future<bool> _openDoc() async {
    final pdf = PdfPages(_path);
    try {
      await pdf.open();
    } catch (_) {
      await pdf.close();
      return false;
    }
    if (!mounted) {
      await pdf.close();
      return false;
    }
    if (pdf.pageCount == 0) {
      await pdf.close();
      return false;
    }
    pdf.sizesVersion.addListener(_onSizes);
    setState(() {
      _pdf = pdf;
      _count = pdf.pageCount;
      _docGen++;
    });
    _sizesJob = pdf.loadSizes(() => mounted && identical(_pdf, pdf));
    return true;
  }

  /// Takes the open document off the screen (the caller closes it).
  PdfPages? _detachDoc() {
    final pdf = _pdf;
    if (pdf == null) return null;
    pdf.sizesVersion.removeListener(_onSizes);
    _pdf = null;
    return pdf;
  }

  void _onSizes() {
    if (!mounted) return;
    setState(() {});
    if (widget.page > 0 && !_userScrolled) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToStart());
  }

  void _jumpToStart() {
    if (!mounted || _userScrolled || !_scroll.hasClients) return;
    final offset = _offsetOfPage(widget.page.clamp(0, math.max(0, _count - 1)));
    _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  double _offsetOfPage(int page) {
    final pdf = _pdf;
    final view = _viewportKey.currentContext?.findRenderObject();
    if (pdf == null || view is! RenderBox || !view.hasSize) return 0;
    final w = view.size.width;
    var offset = 12.0;
    for (var i = 0; i < page; i++) {
      offset += 12 + w * pdf.aspectOf(i);
    }
    return offset;
  }

  Future<void> _loadSignatures() async {
    final list = await SignatureStore.list();
    if (mounted) setState(() => _signatures = list);
  }

  /// Real text lines (for Edit text); then opens the panel the screen was started with.
  Future<void> _loadLines({_Panel initial = _Panel.none}) async {
    _linesLoaded = false;
    List<List<PdfTextLine>>? found;
    try {
      final bytes = await File(_path).readAsBytes();
      found = await _readLinesIsolated(bytes);
    } catch (_) {
      found = null;
    }
    if (!mounted) return;
    setState(() {
      _rawLines = found;
      _linesLoaded = true;
    });
    switch (initial) {
      // scanned pages have no text to edit: go quietly to Add text (no message, like the original)
      case _Panel.editText:
        _openPanel(_hasLines ? _Panel.editText : _Panel.addText);
      case _Panel.none:
        break;
      default:
        _openPanel(initial);
    }
  }

  bool get _hasLines => _rawLines?.any((page) => page.isNotEmpty) ?? false;

  // ------------------------------------------------------------------ EditHost

  _Tool get _tool {
    switch (_panel) {
      case _Panel.none:
        final any = _items.values.any((list) => list.any((item) => item is _TextItem || item is _ImageItem));
        return any ? _Tool.objects : _Tool.none;
      case _Panel.editText:
        return _Tool.editText;
      case _Panel.addText:
      case _Panel.sign:
        return _Tool.objects;
      case _Panel.annotate:
        return _annTool;
    }
  }

  List<_Item> _itemsOf(int page) => _items.putIfAbsent(page, () => <_Item>[]);

  /// Text lines still editable: the ones not covered by an edited-text box (undo brings them back).
  List<_Line> _linesOf(int page) {
    final raw = _rawLines;
    final pdf = _pdf;
    if (raw == null || pdf == null || page >= raw.length) return const [];
    final a = pdf.aspectOf(page);
    final all = [
      for (final line in raw[page]) _Line(line.readable ? line.text : '', Rect.fromLTRB(line.left, line.top * a, line.right, line.bottom * a), line.size * a),
    ];
    final covers = [
      for (final item in _items[page] ?? const <_Item>[])
        if (item is _TextItem && item.cover != null) item.cover!,
    ];
    if (covers.isEmpty) return all;
    return all.where((line) => !covers.any((c) => c.contains(line.rect.center))).toList();
  }

  int get _penColor => _annColor;
  double get _penWidth => (1 + _annSize / 100 * 14) / 600;
  int get _markColor => _annTool == _Tool.highlight && _annColor == _red ? _yellow : _annColor;

  bool get _hasChanges => _items.values.any((list) => list.isNotEmpty);

  void _bump() => _repaint.tick();

  /// A change is finished: push it on the undo stack.
  void _commit() {
    _undo.add(_last);
    _redo.clear();
    _last = _snapshot();
    setState(() {});
    _bump();
  }

  Map<int, List<_Item>> _snapshot() => {
        for (final entry in _items.entries) entry.key: [for (final item in entry.value) item.copy()],
      };

  void _restore(Map<int, List<_Item>> state) {
    _items
      ..clear()
      ..addAll({for (final entry in state.entries) entry.key: [for (final item in entry.value) item.copy()]});
    _selected = null;
    _last = _snapshot();
    setState(() {});
    _bump();
  }

  void _undoStep() {
    if (_undo.isEmpty || _saving) return;
    final previous = _undo.removeLast();
    _redo.add(_snapshot());
    _restore(previous);
  }

  void _redoStep() {
    if (_redo.isEmpty || _saving) return;
    final next = _redo.removeLast();
    _undo.add(_snapshot());
    _restore(next);
  }

  void _onSelectionChanged() {
    final t = _selected;
    if (t is _TextItem) {
      _textColor = t.color;
      _textSizeValue = (t.size * 600).toInt().clamp(6, 72);
    }
    setState(() {});
    _bump();
  }

  // ------------------------------------------------------------------ geometry on screen

  RenderBox? _box(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  double _layerWidth(int page) => _box(_layerKeys[page])?.size.width ?? (_box(_viewportKey)?.size.width ?? 360);

  /// Where page [page]'s layer is, in the page list's viewport.
  Rect? _layerRect(int page) {
    final layer = _box(_layerKeys[page]);
    final view = _box(_viewportKey);
    if (layer == null || view == null) return null;
    return layer.localToGlobal(Offset.zero, ancestor: view) & layer.size;
  }

  /// The pages with a layer on screen, top to bottom, with where they are.
  List<(int, Rect)> _shownPages() {
    final view = _box(_viewportKey);
    if (view == null) return const [];
    final out = <(int, Rect)>[];
    for (final page in _layerKeys.keys.toList()..sort()) {
      final rect = _layerRect(page);
      if (rect == null) continue;
      if (rect.bottom <= 0 || rect.top >= view.size.height) continue;
      out.add((page, rect));
    }
    return out;
  }

  /// The page the person is looking at: the one that shows the most on screen; when two pages
  /// show about the same amount, the upper one.
  int _currentPage() {
    final view = _box(_viewportKey);
    final shown = _shownPages();
    if (view == null || shown.isEmpty) return widget.page.clamp(0, math.max(0, _count - 1));
    final h = view.size.height;
    var best = shown.first.$1;
    var bestShown = -1.0;
    for (final (page, rect) in shown) {
      final visible = math.max(0.0, math.min(rect.bottom, h) - math.max(rect.top, 0.0));
      // a lower page must show clearly more (10 % of the screen) to win over the upper one
      if (bestShown < 0 || visible > bestShown + h / 10) {
        best = page;
        bestShown = visible;
      }
    }
    return best;
  }

  /// Middle of the part of [page] that is on screen, in page-width units.
  double _visibleCentreY(int page) {
    final aspect = _pdf?.aspectOf(page) ?? 1.414;
    final rect = _layerRect(page);
    final view = _box(_viewportKey);
    if (rect == null || view == null || rect.width <= 0) return aspect / 2;
    final top = math.max(0.0, -rect.top);
    final bottom = math.min(rect.height, view.size.height - rect.top);
    return ((top + bottom) / 2 / rect.width).clamp(0.05, math.max(0.05, aspect - 0.05));
  }

  // ------------------------------------------------------------------ touches (EditLayerView)

  _Claim _layerDown(int page, Offset p) {
    final tool = _tool;
    if (tool == _Tool.none || _saving) return _Claim.ignore;
    final w = _layerWidth(page);
    _gesturePage = page;
    _downPos = p;
    _lastPos = p;
    _moved = false;
    _changed = false;
    _op = _Op.tap;
    _target = null;
    var claim = _Claim.now;
    switch (tool) {
      case _Tool.pen:
        _op = _Op.draw;
        _drawing = [p / w];
      case _Tool.highlight:
      case _Tool.underline:
      case _Tool.strike:
        _op = _Op.mark;
        _markRect = _markAt(page, p.dx, p.dx, p.dy, w);
      case _Tool.eraser:
        _op = _Op.erase;
        _eraseAt(page, p, w);
      default:
        claim = _startObjectGesture(page, p, w);
    }
    _bump();
    return claim;
  }

  _Claim _startObjectGesture(int page, Offset p, double w) {
    final sel = _selected;
    final items = _itemsOf(page);
    // 1) handles of the selected item
    if (sel != null && items.contains(sel)) {
      final local = _toLocal(sel, w, p);
      String? hit;
      for (final entry in _handles(sel, w, 6).entries) {
        if ((local - entry.value).distance < 18) {
          hit = entry.key;
          break;
        }
      }
      if (hit != null) {
        _target = sel;
        switch (hit) {
          case 'delete':
            _op = _Op.none;
            _target = null;
            _onDelete(page, sel);
            return _Claim.now;
          case 'copy':
            _op = _Op.none;
            _target = null;
            _onDuplicate(page, sel);
            return _Claim.now;
          case 'edit':
            _op = _Op.none;
            _target = null;
            if (sel is _ImageItem) _onEditImage(page, sel);
            return _Claim.now;
          case 'scale':
            _op = _Op.scale;
            final c = _center(sel, w);
            _startDist = math.max(1.0, (p - c).distance);
            _startAngle = math.atan2(p.dy - c.dy, p.dx - c.dx) * 180 / math.pi;
            _startRotation = _rotationOf(sel);
            _startWidth = sel is _TextItem ? sel.width : (sel is _ImageItem ? sel.width : 0.0);
            _startSize = sel is _TextItem ? sel.size : 0.0;
          case 'left':
            _op = _Op.widthL;
          case 'right':
            _op = _Op.widthR;
        }
        return _Claim.now;
      }
    }
    // 2) an item under the finger (topmost first)
    for (final item in items.reversed) {
      if ((item is _TextItem || item is _ImageItem) && _contains(item, p, w)) {
        _wasSelected = identical(item, sel);
        _selected = item;
        _onSelectionChanged();
        _target = item;
        _op = _Op.move;
        return _Claim.now;
      }
    }
    _op = _Op.tap;
    return _Claim.pending;
  }

  bool _contains(_Item item, Offset p, double w) {
    final box = _boxSize(item, w);
    final local = _toLocal(item, w, p);
    const pad = 8.0;
    return local.dx.abs() <= box.width / 2 + pad && local.dy.abs() <= box.height / 2 + pad;
  }

  void _layerMove(int page, Offset p) {
    if (page != _gesturePage) return;
    final w = _layerWidth(page);
    if (!_moved && (p - _downPos).distance > kTouchSlop) _moved = true;
    final t = _target;
    switch (_op) {
      case _Op.draw:
        _drawing.add(p / w);
      case _Op.mark:
        _markRect = _markAt(page, _downPos.dx, p.dx, _downPos.dy, w);
      case _Op.erase:
        _eraseAt(page, p, w);
      case _Op.move:
        if (t != null && _moved) {
          _lift(page, true);
          final d = (p - _lastPos) / w;
          if (t is _TextItem) {
            t.cx += d.dx;
            t.cy += d.dy;
          } else if (t is _ImageItem) {
            t.cx += d.dx;
            t.cy += d.dy;
          }
          _changed = true;
        }
      case _Op.rotate:
        if (t != null) {
          final c = _center(t, w);
          final a = math.atan2(p.dy - c.dy, p.dx - c.dx) * 180 / math.pi;
          _setRotation(t, _startRotation + (a - _startAngle));
          _changed = true;
        }
      case _Op.scale:
        if (t != null) {
          final c = _center(t, w);
          // the corner handle resizes and turns at the same time
          final a = math.atan2(p.dy - c.dy, p.dx - c.dx) * 180 / math.pi;
          _setRotation(t, _startRotation + (a - _startAngle));
          final k = ((p - c).distance / _startDist).clamp(0.15, 8.0);
          if (t is _TextItem) {
            t.size = (_startSize * k).clamp(0.008, 0.5);
            t.width = _startWidth * (t.size / _startSize);
          } else if (t is _ImageItem) {
            t.width = (_startWidth * k).clamp(0.03, 3.0);
          }
          _changed = true;
        }
      case _Op.widthL:
      case _Op.widthR:
        if (t is _TextItem) {
          final local = _toLocal(t, w, p);
          final half = local.dx.abs() / w;
          t.width = math.min(1.5, math.max(t.size * 1.2, half * 2));
          _changed = true;
        }
      case _Op.tap:
      case _Op.none:
        break;
    }
    _lastPos = p;
    _bump();
  }

  void _layerUp(int page, Offset p) {
    if (page != _gesturePage) return;
    final w = _layerWidth(page);
    switch (_op) {
      case _Op.draw:
        if (_drawing.isNotEmpty) {
          _itemsOf(page).add(_InkItem(_drawing, _penColor, _penWidth));
          _commit();
        }
        _drawing = [];
      case _Op.mark:
        final r = _markRect;
        if (r != null && r.width > 0.01) {
          _itemsOf(page).add(_MarkItem(_markKind, r, _markColor));
          _commit();
        }
        _markRect = null;
      case _Op.erase:
        if (_changed) _commit();
      case _Op.tap:
        if (!_moved) _onTap(page, p, w);
      case _Op.move:
        final t = _target;
        _lift(page, false);
        if (!_moved && _wasSelected && t is _TextItem) {
          _onEditTextItem(page, t);
        } else if (_changed && t != null) {
          final c = _center(t, w);
          final height = _box(_layerKeys[page])?.size.height ?? double.infinity;
          if (c.dy < 0 || c.dy > height) {
            // dragged onto another page (or into the gap): move it to the page under the finger
            final layer = _box(_layerKeys[page]);
            final view = _box(_viewportKey);
            if (layer != null && view != null) {
              _onMovedOffPage(page, t, layer.localToGlobal(c, ancestor: view));
            } else {
              _commit();
            }
          } else {
            _commit();
          }
        }
      default:
        if (_changed) _commit();
    }
    _op = _Op.none;
    _target = null;
    _gesturePage = -1;
    _bump();
  }

  void _layerCancel(int page) {
    if (page != _gesturePage) return;
    _lift(page, false);
    if (_changed) _commit();
    _op = _Op.none;
    _target = null;
    _drawing = [];
    _markRect = null;
    _gesturePage = -1;
    _bump();
  }

  _MarkKind get _markKind => switch (_tool) {
        _Tool.underline => _MarkKind.underline,
        _Tool.strike => _MarkKind.strike,
        _ => _MarkKind.highlight,
      };

  void _onTap(int page, Offset p, double w) {
    if (_tool == _Tool.editText) {
      final x = p.dx / w;
      final y = p.dy / w;
      for (final line in _linesOf(page)) {
        final r = line.rect;
        if (x >= r.left - 0.01 && x <= r.right + 0.01 && y >= r.top - 0.005 && y <= r.bottom + 0.005) {
          _onLineTap(page, line);
          return;
        }
      }
    }
    if (_selected != null) {
      _selected = null;
      _onSelectionChanged();
      return;
    }
    _onTapEmpty(page, p.dx / w, p.dy / w);
  }

  /// While a text / picture is dragged it is drawn above the neighbouring pages (not clipped),
  /// so it stays visible when it is pulled across the gap onto another page.
  void _lift(int page, bool on) {
    if (!on) {
      _lifted = false;
      return;
    }
    if (_lifted) return;
    final rect = _layerRect(page);
    if (rect == null) return;
    _lifted = true;
    _liftOrigin = rect.topLeft;
    _liftWidth = rect.width;
  }

  void _setRotation(_Item item, double degrees) {
    var r = ((degrees % 360) + 360) % 360;
    // snap near straight angles
    for (final s in const [0.0, 90.0, 180.0, 270.0, 360.0]) {
      if ((r - s).abs() < 4) r = s % 360;
    }
    if (item is _TextItem) item.rotation = r;
    if (item is _ImageItem) item.rotation = r;
  }

  /// Highlight / underline / strike span: snaps to a text line when there is one under the finger.
  Rect _markAt(int page, double x0, double x1, double y, double w) {
    final nx0 = math.min(x0, x1) / w;
    final nx1 = math.max(x0, x1) / w;
    final ny = y / w;
    for (final line in _linesOf(page)) {
      final r = line.rect;
      if (ny >= r.top && ny <= r.bottom) {
        return Rect.fromLTRB(math.max(nx0, r.left - 0.01), r.top, math.min(math.max(nx1, nx0 + 0.005), r.right + 0.01), r.bottom);
      }
    }
    const half = 0.016;
    return Rect.fromLTRB(nx0, ny - half, math.max(nx1, nx0 + 0.005), ny + half);
  }

  void _eraseAt(int page, Offset p, double w) {
    const r = 14.0;
    final items = _itemsOf(page);
    final before = items.length;
    items.removeWhere((item) {
      if (item is _InkItem) {
        return item.points.any((point) => (point * w - p).distance < r + item.width * w / 2);
      }
      if (item is _MarkItem) {
        final m = item.rect;
        return Rect.fromLTRB(m.left * w - r, m.top * w - r, m.right * w + r, m.bottom * w + r).contains(p);
      }
      return false;
    });
    if (items.length != before) _changed = true;
  }

  // ------------------------------------------------------------------ actions

  Future<void> _onTapEmpty(int page, double x, double y) async {
    if (_panel != _Panel.addText) return;
    final text = await enterText(context);
    if (text == null || !mounted) return;
    _addText(page, text, x, y, centred: false);
  }

  /// The "Tap anywhere to add text" bar: type first, the text lands in the middle of the page on
  /// screen.
  Future<void> _addTextFromBar() async {
    if (_saving) return;
    if (_panel == _Panel.editText) {
      showToast(context, S.of(context).t('tapTextToEdit'));
      return;
    }
    final page = _currentPage();
    final text = await enterText(context);
    if (text == null || !mounted) return;
    _addText(page, text, 0.5, _visibleCentreY(page), centred: true);
  }

  void _addText(int page, String text, double x, double y, {required bool centred}) {
    final t = text.trim();
    if (t.isEmpty) return;
    final size = _textSizeValue / 600;
    final width = math.min(0.96, _measure(t, size));
    final cx = centred ? 0.5 : (x + width / 2).clamp(width / 2, math.max(width / 2, 1 - width / 2 + 0.2)).toDouble();
    final item = _TextItem(text: t, cx: cx, cy: y, width: width, size: size, color: _textColor);
    _itemsOf(page).add(item);
    _selected = item;
    _commit();
  }

  Future<void> _onEditTextItem(int page, _TextItem item) async {
    final text = await enterText(context, initial: item.text);
    if (text == null || !mounted) return;
    final t = text.trim();
    if (t.isEmpty) {
      _itemsOf(page).remove(item);
      if (identical(_selected, item)) _selected = null;
    } else {
      item.text = t;
      item.width = math.max(item.width, math.min(0.96, _measure(t, item.size)));
    }
    _commit();
  }

  Future<void> _onLineTap(int page, _Line line) async {
    final text = await enterText(context, initial: line.text);
    if (text == null || !mounted) return;
    final t = text.trim().isEmpty ? ' ' : text.trim();
    final r = line.rect;
    final cover = Rect.fromLTRB(r.left - 0.004, r.top - 0.003, r.right + 0.004, r.bottom + 0.003);
    final size = math.max(0.008, line.size * 0.95);
    final width = math.min(1.0, math.max(r.width, _measure(t, size)));
    final item = _TextItem(
      text: t,
      cx: r.left + width / 2,
      cy: (r.top + r.bottom) / 2,
      width: width,
      size: size,
      color: _textColor == 0xFFFFFFFF ? 0xFF000000 : _textColor,
      cover: cover,
    );
    _itemsOf(page).add(item);
    _selected = item;
    _commit();
  }

  void _onDelete(int page, _Item item) {
    _itemsOf(page).remove(item);
    if (identical(_selected, item)) _selected = null;
    _commit();
  }

  void _onDuplicate(int page, _Item item) {
    final copy = item.copy();
    if (copy is _TextItem) {
      copy.cx += 0.04;
      copy.cy += 0.06;
    } else if (copy is _ImageItem) {
      copy.cx += 0.04;
      copy.cy += 0.06;
    }
    _itemsOf(page).add(copy);
    _selected = copy;
    _onSelectionChanged();
    _commit();
  }

  /// [at] = the drop point in the viewport: the item goes to the page under it (or the nearest
  /// one when dropped in the gap).
  void _onMovedOffPage(int page, _Item item, Offset at) {
    var best = -1;
    var bestDist = double.infinity;
    Rect? bestRect;
    for (final (index, rect) in _shownPages()) {
      final dist = at.dy < rect.top ? rect.top - at.dy : (at.dy > rect.bottom ? at.dy - rect.bottom : 0.0);
      if (dist < bestDist) {
        bestDist = dist;
        best = index;
        bestRect = rect;
      }
    }
    final rect = bestRect;
    if (best < 0 || rect == null || rect.width <= 0) {
      _commit();
      return;
    }
    final maxY = rect.height / rect.width;
    final nx = ((at.dx - rect.left) / rect.width).clamp(0.0, 1.0).toDouble();
    final ny = ((at.dy - rect.top) / rect.width).clamp(0.02, math.max(0.02, maxY - 0.02)).toDouble();
    if (item is _TextItem) {
      item.cx = nx;
      item.cy = ny;
    } else if (item is _ImageItem) {
      item.cx = nx;
      item.cy = ny;
    }
    if (best != page) {
      _itemsOf(page).remove(item);
      _itemsOf(best).add(item);
    }
    _selected = item;
    _onSelectionChanged();
    _commit();
  }

  /// Pencil on a picture / signature: draw a new signature or pick a new picture in its place.
  Future<void> _onEditImage(int page, _ImageItem item) async {
    if (item.signature) {
      final sign = await _newSignature();
      if (sign == null || !mounted) return;
      item.sign = sign;
    } else {
      final picked = await _pickPicture();
      if (picked == null || !mounted) return;
      item.bytes = picked.$1;
      item.image = picked.$2;
      item.sign = null;
    }
    _selected = item;
    _commit();
  }

  /// Draws a signature in the pad, keeps it with the saved ones and returns it.
  Future<Signature?> _newSignature() async {
    final drawn = await drawSignature(context);
    if (drawn == null) return null;
    final saved = await SignatureStore.save(drawn);
    await _loadSignatures();
    return saved;
  }

  Future<void> _addSignature() async {
    if (_saving) return;
    final sign = await _newSignature();
    if (sign == null || !mounted) return;
    _placeImage(_ImageItem(cx: 0.5, cy: 0, width: 0.35, sign: sign));
  }

  Future<void> _deleteSignature(Signature sign) async {
    final s = S.of(context);
    final ok = await confirmSheet(context, title: s.t('deleteSignature'), message: s.t('deleteSignatureMessage'), ok: s.t('delete'));
    if (!ok) return;
    await SignatureStore.delete(sign);
    await _loadSignatures();
  }

  /// Add image: the photo picker, then the picture goes in the middle of the page on screen.
  Future<void> _addImage() async {
    if (_saving) return;
    final picked = await _pickPicture();
    if (picked == null || !mounted) return;
    _placeImage(_ImageItem(cx: 0.5, cy: 0, width: 0.5, bytes: picked.$1, image: picked.$2));
  }

  /// A picture from the gallery (at most 1600 px, like PdfEditor.decode): the bytes that go into
  /// the PDF (PNG kept for its transparency, anything else re-encoded as an upright JPEG) and
  /// the decoded image.
  Future<(Uint8List, ui.Image)?> _pickPicture() async {
    final scope = AppScope.of(context);
    final s = S.of(context);
    scope.guard.arm(scope.settings);
    XFile? file;
    try {
      file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600, imageQuality: 92);
    } catch (_) {
      if (mounted) showToast(context, s.t('convertFailed'));
      return null;
    }
    if (file == null) return null;
    try {
      var bytes = await File(file.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      var image = frame.image;
      if (image.width > 1600 || image.height > 1600) {
        final k = 1600 / math.max(image.width, image.height);
        image = await _scaled(image, (image.width * k).round(), (image.height * k).round());
      }
      final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
      if (png && identical(image, frame.image)) return (bytes, image);
      if (png) {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return (data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), image);
      }
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      bytes = await rgbaToJpeg(rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes), image.width, image.height, quality: 90);
      return (bytes, image);
    } catch (_) {
      if (mounted) showToast(context, s.t('convertFailed'));
      return null;
    }
  }

  Future<ui.Image> _scaled(ui.Image source, int width, int height) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  /// Puts a picture / signature in the middle of the page on screen, selected.
  void _placeImage(_ImageItem item) {
    final page = _currentPage();
    item.cy = _visibleCentreY(page);
    _itemsOf(page).add(item);
    _selected = item;
    _commit();
  }

  // ------------------------------------------------------------------ panels

  void _openPanel(_Panel mode) {
    setState(() {
      _panel = mode;
      if (mode == _Panel.none) _selected = null;
      if (mode == _Panel.editText && _textColor == _pink) _textColor = 0xFF000000;
    });
    if (mode == _Panel.sign) _loadSignatures();
    _bump();
  }

  void _editTextTool() {
    final s = S.of(context);
    if (!_linesLoaded) {
      showToast(context, s.t('loading'));
    } else if (!_hasLines) {
      showToast(context, s.t('noEditableText'));
    } else {
      _openPanel(_Panel.editText);
    }
  }

  Future<void> _showTutorial() async {
    final choice = await showEditTutorial(context);
    if (!mounted || choice == null) return;
    if (choice == 'sign') {
      _openPanel(_Panel.sign);
    } else {
      _openPanel(_hasLines ? _Panel.editText : _Panel.addText);
    }
  }

  void _applySizeToSelection() {
    final t = _selected;
    if (t is! _TextItem) return;
    final size = _textSizeValue / 600;
    final k = size / t.size;
    t.size = size;
    t.width *= k;
    _bump();
  }

  // ------------------------------------------------------------------ save / close

  Future<void> _save() async {
    if (_saving) return;
    if (!_hasChanges) {
      _openPanel(_Panel.none);
      return;
    }
    final s = S.of(context);
    final scope = AppScope.of(context);
    setState(() {
      _saving = true;
      _selected = null;
    });
    _bump();
    final state = _snapshot();
    var ok = false;
    try {
      await _sizesJob;
      final pdf = _pdf;
      if (pdf == null) throw StateError('closed');
      final aspects = <int, double>{for (var i = 0; i < _count; i++) i + 1: pdf.aspectOf(i)};
      final original = await File(_path).readAsBytes();
      final marks = await _marksOf(state, aspects);
      var bytes = await _rewriteIsolated(original, marks, aspects, _count);
      // the PDF could not be edited in place: every page as a picture with the edits on it
      bytes ??= await _bake(state);
      // the viewer must let go of the file before it is replaced
      await _detachDoc()?.close();
      await File(_path).writeAsBytes(bytes, flush: true);
      ok = true;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (!ok) {
      if (_pdf == null) await _openDoc();
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, s.t('saveFailed'), warning: true);
      return;
    }
    await scope.library.addFile(_path);
    _savedOnce = true;
    _items.clear();
    _undo.clear();
    _redo.clear();
    _last = {};
    _layouts.clear();
    await _openDoc();
    if (!mounted) return;
    setState(() => _saving = false);
    _openPanel(_Panel.none);
    _loadLines();
    showTopPill(context, s.t('savedSuccessfully'), icon: ND.icCheckCircleOutline, topMargin: 60, decoration: NS.bgTopPill(context));
    await scope.ads.showInterstitial(unit: 2);
  }

  /// Everything on the pages as PDF marks (page fractions; covers first on each page, like
  /// EditRenderer.draw).
  Future<List<PdfVectorMark>> _marksOf(Map<int, List<_Item>> state, Map<int, double> aspects) async {
    final out = <PdfVectorMark>[];
    for (final entry in state.entries) {
      final index = entry.key;
      final list = entry.value;
      if (list.isEmpty || index >= _count) continue;
      final pageNo = index + 1;
      final a = aspects[pageNo] ?? 1.414;
      (double, double) f(double x, double y) => (x, y / a);
      for (final item in list) {
        final c = item is _TextItem ? item.cover : null;
        if (c != null) out.add(PdfVectorMark(page: pageNo, tool: 'whiteout', points: [f(c.left, c.top), f(c.right, c.bottom)], color: 0xFFFFFFFF));
      }
      for (final item in list) {
        if (item is _MarkItem) {
          final r = item.rect;
          if (item.kind == _MarkKind.highlight) {
            out.add(PdfVectorMark(page: pageNo, tool: 'highlightRect', points: [f(r.left, r.top), f(r.right, r.bottom)], color: item.color));
          } else {
            final y = item.kind == _MarkKind.underline ? r.bottom : (r.top + r.bottom) / 2;
            out.add(PdfVectorMark(page: pageNo, tool: 'pen', points: [f(r.left, y), f(r.right, y)], color: item.color, strokeFraction: math.max(0.0009, (r.bottom - r.top) * 0.09)));
          }
        } else if (item is _InkItem) {
          if (item.points.isEmpty) continue;
          final points = [for (final p in item.points) f(p.dx, p.dy)];
          if (points.length == 1) points.add((points.first.$1 + 0.0002, points.first.$2));
          out.add(PdfVectorMark(page: pageNo, tool: 'pen', points: points, color: item.color, strokeFraction: math.max(0.0006, item.width)));
        } else if (item is _TextItem) {
          if (item.text.trim().isEmpty) continue;
          final shot = await _textPng(item);
          if (shot == null) continue;
          out.add(PdfVectorMark(page: pageNo, tool: 'stamp', points: [f(item.cx, item.cy)], image: shot.$1, width: item.width, height: shot.$2 / a, rotation: item.rotation));
        } else if (item is _ImageItem) {
          final sign = item.sign;
          final bytes = item.bytes;
          if (sign != null) {
            final bw = item.width;
            final bh = item.height;
            final angle = _rad(item.rotation);
            final cos = math.cos(angle);
            final sin = math.sin(angle);
            for (var i = 0; i < sign.strokes.length; i++) {
              final stroke = sign.strokes[i];
              if (stroke.isEmpty) continue;
              final points = <(double, double)>[];
              for (final p in _smooth(stroke)) {
                final lx = (p.dx - 0.5) * bw;
                final ly = (p.dy - 0.5) * bh;
                points.add(f(item.cx + lx * cos - ly * sin, item.cy + lx * sin + ly * cos));
              }
              if (points.length == 1) points.add((points.first.$1 + 0.0002, points.first.$2));
              final width = i < sign.widths.length ? sign.widths[i] : sign.width;
              out.add(PdfVectorMark(page: pageNo, tool: 'pen', points: points, color: sign.color, strokeFraction: math.max(0.0004, width * bw)));
            }
          } else if (bytes != null) {
            out.add(PdfVectorMark(page: pageNo, tool: 'stamp', points: [f(item.cx, item.cy)], image: bytes, width: item.width, height: item.height / a, rotation: item.rotation));
          }
        }
      }
    }
    return out;
  }

  /// The points of a stroke along the same curves the screen draws (quadratic segments through
  /// the midpoints), so the PDF line is as smooth as on screen.
  List<Offset> _smooth(List<Offset> stroke) {
    if (stroke.length < 3) return stroke;
    final out = <Offset>[stroke.first];
    for (var i = 1; i < stroke.length - 1; i++) {
      final start = out.last;
      final control = stroke[i];
      final end = (stroke[i] + stroke[i + 1]) / 2;
      for (var k = 1; k <= 4; k++) {
        final t = k / 4;
        final u = 1 - t;
        out.add(start * (u * u) + control * (2 * u * t) + end * (t * t));
      }
    }
    out.add(stroke.last);
    return out;
  }

  /// A text box as a transparent picture (1800 px per page width, at most 4096 px), drawn the
  /// way the screen draws it (wrapping, any script), and its height in page-width units.
  Future<(Uint8List, double)?> _textPng(_TextItem item) async {
    var unit = 1800.0;
    final probe = _boxSize(item, unit);
    final longest = math.max(probe.width, probe.height);
    if (longest > 4096) unit *= 4096 / longest;
    final layout = _textLayout(item, unit);
    final width = math.max(1, (item.width * unit).ceil());
    final height = math.max(1, layout.height.ceil());
    final recorder = ui.PictureRecorder();
    layout.paint(Canvas(recorder), Offset.zero);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return (data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), height / unit);
  }

  /// When the PDF can't be edited in place: every page as a picture with the edits drawn on it.
  Future<Uint8List> _bake(Map<int, List<_Item>> state) async {
    final document = await PdfDocument.openFile(_path);
    final pieces = <PdfPiece>[];
    try {
      for (var index = 0; index < document.pagesCount; index++) {
        final page = await document.getPage(index + 1);
        final pw = page.width;
        final ph = page.height;
        final scale = math.min(3.0, 2600 / math.max(pw, ph));
        final w = (pw * scale).round();
        final h = (ph * scale).round();
        final rendered = await page.render(width: w.toDouble(), height: h.toDouble(), format: PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
        await page.close();
        if (rendered == null) continue;
        final codec = await ui.instantiateImageCodec(rendered.bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImageRect(
          frame.image,
          Rect.fromLTWH(0, 0, frame.image.width.toDouble(), frame.image.height.toDouble()),
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint()..filterQuality = FilterQuality.medium,
        );
        _drawItems(canvas, state[index] ?? const [], w.toDouble());
        final picture = recorder.endRecording();
        final image = await picture.toImage(w, h);
        picture.dispose();
        frame.image.dispose();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        if (data == null) continue;
        final jpeg = await rgbaToJpeg(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), w, h, quality: 90);
        pieces.add(PdfPiece(image: jpeg, pageFormat: PdfPageFormat(pw, ph)));
      }
    } finally {
      await document.close();
    }
    if (pieces.isEmpty) throw StateError('nothing drawn');
    return rebuildPdf(pieces);
  }

  void _back() {
    if (_panel != _Panel.none) {
      _openPanel(_Panel.none);
    } else {
      _close();
    }
  }

  Future<void> _close() async {
    if (_saving) return;
    if (_hasChanges) {
      final s = S.of(context);
      final discard = await confirmSheet(context, title: s.t('discardTitle'), message: s.t('discardMessage'), ok: s.t('discard'));
      if (!discard || !mounted) return;
    }
    Navigator.of(context).pop(_savedOnce);
  }

  // ------------------------------------------------------------------ build

  /// updateBars(): undo / redo / Done show while editing; ⓘ when not (and in Sign).
  bool get _editing => _panel != _Panel.none || _hasChanges || _undo.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final editing = _editing;
    const off = Color(0xFFC3C8D0);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // × ⓘ … undo redo [Done]
              Container(
                height: 56,
                padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
                child: Row(
                  children: [
                    NativeIconButton(ND.icClose, padding: 11, tint: nc.textPrimary, tooltip: s.t('cancel'), onPressed: _close),
                    if (!editing || _panel == _Panel.sign)
                      NativeIconButton(ND.icInfo, size: 40, padding: 9, tint: nc.textPrimary, tooltip: s.t('howToEdit'), onPressed: _showTutorial),
                    const Spacer(),
                    if (editing) ...[
                      NativeIconButton(
                        ND.icUndo,
                        tint: _undo.isEmpty ? off : nc.textPrimary,
                        tooltip: s.t('undo'),
                        onPressed: _undo.isEmpty ? null : _undoStep,
                      ),
                      NativeIconButton(
                        ND.icRedo,
                        tint: _redo.isEmpty ? off : nc.textPrimary,
                        tooltip: s.t('redo'),
                        onPressed: _redo.isEmpty ? null : _redoStep,
                      ),
                      const SizedBox(width: 40),
                      _doneButton(s),
                    ],
                  ],
                ),
              ),
              Expanded(child: ColoredBox(color: Colors.black, child: _pages(nc))),
              Material(
                color: nc.surface,
                child: SafeArea(top: false, child: _bottom(s, nc)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// btnDone: 34dp bg_done_btn, min 64dp, a white spinner while saving.
  Widget _doneButton(S s) {
    return Material(
      color: const Color(0xFF111317),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _saving ? null : _save,
        child: Container(
          height: 34,
          constraints: const BoxConstraints(minWidth: 64),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(s.t('done'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ),
    );
  }

  /// rvPages: every page full width, 12dp above and below the list, 6dp around each page.
  Widget _pages(NC nc) {
    final pdf = _pdf;
    return Stack(
      key: _viewportKey,
      children: [
        if (pdf == null)
          Center(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: nc.primary)))
        else
          NotificationListener<ScrollStartNotification>(
            onNotification: (notification) {
              if (notification.dragDetails != null) _userScrolled = true;
              return false;
            },
            child: ListView.builder(
              key: ValueKey('pages$_docGen'),
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: _count,
              itemBuilder: (context, index) => _pageRow(pdf, index),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _LiftPainter(this, _repaint))),
        ),
      ],
    );
  }

  Widget _pageRow(PdfPages pdf, int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return SizedBox(
            width: w,
            height: w * pdf.aspectOf(index),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: PdfPageTile(key: ValueKey('tile$_docGen-$index'), pages: pdf, index: index)),
                Positioned.fill(
                  child: RawGestureDetector(
                    behavior: HitTestBehavior.translucent,
                    gestures: {
                      _LayerRecognizer: GestureRecognizerFactoryWithHandlers<_LayerRecognizer>(
                        _LayerRecognizer.new,
                        (recognizer) => recognizer
                          ..host = this
                          ..page = index,
                      ),
                    },
                    child: SizedBox.expand(
                      key: _layerKeys.putIfAbsent(index, GlobalKey.new),
                      child: CustomPaint(painter: _LayerPainter(this, index, _repaint)),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _bottom(S s, NC nc) {
    switch (_panel) {
      case _Panel.none:
        return _mainTools(s, nc);
      case _Panel.addText:
      case _Panel.editText:
        return _textPanel(s, nc);
      case _Panel.annotate:
        return _annotatePanel(s, nc);
      case _Panel.sign:
        return _signPanel(s, nc);
    }
  }

  /// mainTools: 62dp, item_bottom_tool × 5 (Edit text, Add text, Add image, Annotate, Sign).
  Widget _mainTools(S s, NC nc) {
    Widget tool(NDrawable icon, String label, VoidCallback onTap, {double opacity = 1}) {
      return Expanded(
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            radius: 36,
            onTap: _saving ? null : onTap,
            child: Opacity(
              opacity: opacity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  NativeIcon(icon, size: 22, tint: nc.textPrimary),
                  const SizedBox(height: 3),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: nc.textPrimary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 62,
      child: Row(
        children: [
          tool(ND.icEtEditText, s.t('editText'), _editTextTool, opacity: _linesLoaded && !_hasLines ? 0.4 : 1),
          tool(ND.icEtAddText, s.t('addText'), () => _openPanel(_Panel.addText)),
          tool(ND.icEtAddImage, s.t('addImage'), _addImage),
          tool(ND.icEtAnnotate, s.t('annotate'), () => _openPanel(_Panel.annotate)),
          tool(ND.icEtSign, s.t('sign'), () => _openPanel(_Panel.sign)),
        ],
      ),
    );
  }

  Widget _backChevron(NC nc, {double size = 40, double padding = 11}) {
    return Transform.rotate(
      angle: math.pi,
      child: NativeIconButton(ND.icChevronRight, size: size, padding: padding, tint: nc.textPrimary, onPressed: () => _openPanel(_Panel.none)),
    );
  }

  /// colorDot(): 28dp circles 10dp apart (white gets a 1dp #D5DAE1 ring), ✓ 16dp on the chosen one.
  Widget _colorRow(int current, void Function(int color) onPick, {EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 12)}) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: [
          for (final color in editColors)
            GestureDetector(
              onTap: () => onPick(color),
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsetsDirectional.only(end: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Color(color),
                    shape: BoxShape.circle,
                    border: color == 0xFFFFFFFF ? Border.all(color: const Color(0xFFD5DAE1)) : null,
                  ),
                  child: current == color
                      ? NativeIcon(
                          ND.icCheck,
                          size: 16,
                          tint: color == 0xFFFFFFFF || color == _yellow || color == 0xFFA3E635 ? Colors.black : Colors.white,
                        )
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// SeekBar look: primary track and thumb.
  Widget _seek({required double value, required double min, required double max, ValueChanged<double>? onEnd, required ValueChanged<double> onChanged}) {
    final nc = NC.of(context);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: nc.primary,
        inactiveTrackColor: nc.primary.withValues(alpha: 0.24),
        thumbColor: nc.primary,
        overlayColor: nc.primary.withValues(alpha: 0.12),
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: Slider(value: value.clamp(min, max), min: min, max: max, onChangeEnd: onEnd, onChanged: onChanged),
    );
  }

  /// textPanel: ‹ + hint field, colours, size SeekBar (6–72) + "72 ▾" list.
  Widget _textPanel(S s, NC nc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 44,
            padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
            child: Row(
              children: [
                _backChevron(nc),
                Expanded(
                  child: Material(
                    color: nc.surfaceVariant,
                    borderRadius: BorderRadius.circular(22),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: _addTextFromBar,
                      child: Container(
                        height: 32,
                        alignment: AlignmentDirectional.centerStart,
                        padding: const EdgeInsetsDirectional.only(start: 14),
                        child: Text(
                          _panel == _Panel.editText ? s.t('tapTextToEdit') : s.t('tapAnywhereAddText'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: nc.textHint),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _colorRow(_textColor, (value) {
            setState(() => _textColor = value);
            final t = _selected;
            if (t is _TextItem) {
              t.color = value;
              _commit();
            }
          }),
          Container(
            height: 36,
            padding: const EdgeInsetsDirectional.only(start: 4, end: 16),
            child: Row(
              children: [
                Expanded(
                  child: _seek(
                    value: _textSizeValue.toDouble(),
                    min: 6,
                    max: 72,
                    onChanged: (value) {
                      setState(() => _textSizeValue = value.round());
                      _applySizeToSelection();
                    },
                    onEnd: (_) {
                      if (_selected is _TextItem) _commit();
                    },
                  ),
                ),
                // tvTextSize: 52 × 30 bg_search_field with ▾ (▴ while the list is open)
                PopupMenuButton<int>(
                  tooltip: '',
                  padding: EdgeInsets.zero,
                  color: nc.surface,
                  elevation: 4,
                  constraints: const BoxConstraints(minWidth: 56, maxWidth: 56, maxHeight: 200),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: nc.divider)),
                  initialValue: _textSizes.contains(_textSizeValue) ? _textSizeValue : null,
                  onOpened: () => setState(() => _sizeListOpen = true),
                  onCanceled: () => setState(() => _sizeListOpen = false),
                  onSelected: (value) {
                    setState(() {
                      _sizeListOpen = false;
                      _textSizeValue = value;
                    });
                    if (_selected is _TextItem) {
                      _applySizeToSelection();
                      _commit();
                    }
                  },
                  itemBuilder: (context) => [
                    for (final option in _textSizes)
                      PopupMenuItem<int>(
                        value: option,
                        height: 34,
                        padding: EdgeInsetsDirectional.only(start: 14, end: 8).resolve(Directionality.of(context)),
                        child: Text('$option', style: TextStyle(fontSize: 13, color: option == _textSizeValue ? nc.primary : nc.textPrimary)),
                      ),
                  ],
                  child: Container(
                    width: 52,
                    height: 30,
                    padding: const EdgeInsetsDirectional.only(start: 8, end: 6),
                    decoration: NS.bgSearchField(context),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(child: Text('$_textSizeValue', maxLines: 1, style: TextStyle(fontSize: 13, color: nc.textPrimary))),
                        const SizedBox(width: 2),
                        NativeIcon(_sizeListOpen ? ND.icCaretUp : ND.icCaretDown, size: 12, tint: nc.textPrimary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// annotatePanel: Color / Size tabs + colours or SeekBar (0–100); ‹ eraser highlight underline
  /// strikethrough pen.
  Widget _annotatePanel(S s, NC nc) {
    Widget tab(bool on, Widget icon, String label, VoidCallback onTap) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Opacity(
            opacity: on ? 1 : 0.55,
            child: SizedBox(
              width: 40,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(height: 2),
                  Text(label, maxLines: 1, style: TextStyle(fontSize: 10, color: on ? nc.primary : nc.textPrimary)),
                ],
              ),
            ),
          ),
        );
    Widget tool(_Tool value, NDrawable icon, String tip) {
      final on = _annTool == value;
      return Expanded(
        child: Center(
          child: NativeIconButton(icon, padding: 11, tint: on ? nc.primary : nc.textPrimary, tooltip: tip, onPressed: () {
            setState(() => _annTool = value);
            _bump();
          }),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 48,
          padding: const EdgeInsetsDirectional.only(start: 8),
          child: Row(
            children: [
              tab(
                _annColorsTab,
                Container(width: 14, height: 14, decoration: BoxDecoration(color: Color(_annColor), shape: BoxShape.circle)),
                s.t('color'),
                () => setState(() => _annColorsTab = true),
              ),
              tab(!_annColorsTab, NativeIcon(ND.icPen, size: 16, tint: nc.textPrimary), s.t('sizeLabel'), () => setState(() => _annColorsTab = false)),
              Expanded(
                child: _annColorsTab
                    ? _colorRow(_annColor, (value) => setState(() => _annColor = value), padding: const EdgeInsetsDirectional.only(start: 8, end: 12))
                    : _seek(value: _annSize.toDouble(), min: 0, max: 100, onChanged: (value) => setState(() => _annSize = value.round())),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 52,
          child: Row(
            children: [
              Expanded(child: Center(child: _backChevron(nc, size: 44, padding: 12))),
              tool(_Tool.eraser, ND.icEraser, s.t('eraser')),
              tool(_Tool.highlight, ND.icTextHighlight, s.t('highlight')),
              tool(_Tool.underline, ND.icUnderline, s.t('underline')),
              tool(_Tool.strike, ND.icStrike, s.t('strike')),
              tool(_Tool.pen, ND.icPen, s.t('pen')),
            ],
          ),
        ),
      ],
    );
  }

  /// signPanel 72dp: ‹ and "+ Add signature", or "+ Add" followed by the saved signatures (tap to
  /// place, long-press or × to delete).
  Widget _signPanel(S s, NC nc) {
    Widget addButton({required Widget child, double? width}) => Material(
          color: nc.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            splashColor: const Color(0x1F1E6FE6),
            onTap: _addSignature,
            child: SizedBox(width: width, height: width ?? 44, child: Center(child: child)),
          ),
        );
    return Container(
      height: 72,
      padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
      child: Row(
        children: [
          _backChevron(nc),
          Expanded(
            child: _signatures.isEmpty
                ? addButton(child: Text(s.t('addSignature'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.primary)))
                : SizedBox(
                    height: 56,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        Center(
                          child: addButton(
                            width: 52,
                            child: Text(s.t('addShort'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: nc.primary)),
                          ),
                        ),
                        for (final sign in _signatures)
                          Container(
                            width: 98,
                            height: 56,
                            margin: const EdgeInsetsDirectional.only(start: 8),
                            child: Stack(
                              children: [
                                PositionedDirectional(
                                  start: 0,
                                  bottom: 0,
                                  child: GestureDetector(
                                    onTap: _saving ? null : () => _placeImage(_ImageItem(cx: 0.5, cy: 0, width: 0.35, sign: sign)),
                                    onLongPress: () => _deleteSignature(sign),
                                    child: Container(
                                      width: 90,
                                      height: 48,
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                      decoration: NS.bgSignatureItem(context),
                                      child: CustomPaint(painter: _SignaturePainter(sign)),
                                    ),
                                  ),
                                ),
                                PositionedDirectional(
                                  top: 0,
                                  end: 0,
                                  child: GestureDetector(
                                    onTap: () => _deleteSignature(sign),
                                    child: const NativeIcon(ND.icSignRemove, size: 18),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

Future<List<List<PdfTextLine>>?> _readLinesIsolated(Uint8List bytes) => Isolate.run(() => readPdfTextLines(bytes));

Future<Uint8List?> _rewriteIsolated(Uint8List data, List<PdfVectorMark> marks, Map<int, double> aspects, int count) =>
    Isolate.run(() => rewritePdf(data, marks: marks, aspects: aspects, pageCount: count));

/// Repaints every page layer without rebuilding the page list.
class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// Tracks one finger on a page layer. Draw / mark / erase and touches on a text or picture take
/// the finger at once (the list does not scroll); other touches wait: a tap goes to the layer,
/// a drag scrolls the list — like EditLayerView inside the RecyclerView.
class _LayerRecognizer extends OneSequenceGestureRecognizer {
  _MarkupPageState? host;
  int page = 0;
  int? _pointer;
  bool _accepted = false;
  Offset _down = Offset.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final h = host;
    if (h == null || _pointer != null) return;
    final claim = h._layerDown(page, event.localPosition);
    if (claim == _Claim.ignore) return;
    _pointer = event.pointer;
    _accepted = false;
    _down = event.localPosition;
    super.addAllowedPointer(event);
    if (claim == _Claim.now) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    final h = host;
    if (h == null || event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      if (!_accepted) {
        // a drag that started on an empty spot scrolls the page list
        if ((event.localPosition - _down).distance > kTouchSlop) resolve(GestureDisposition.rejected);
        return;
      }
      h._layerMove(page, event.localPosition);
    } else if (event is PointerUpEvent) {
      if (!_accepted) resolve(GestureDisposition.accepted);
      if (_pointer == event.pointer) h._layerUp(page, event.localPosition);
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      h._layerCancel(page);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer == _pointer) _accepted = true;
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer != _pointer) return;
    host?._layerCancel(page);
    _pointer = null;
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    _accepted = false;
  }

  @override
  String get debugDescription => 'pdf edit layer';
}

/// One page's drawing layer: editable lines (Edit text), the page's items, the stroke / mark in
/// progress and the selection.
class _LayerPainter extends CustomPainter {
  _LayerPainter(this.host, this.page, Listenable repaint) : super(repaint: repaint);

  final _MarkupPageState host;
  final int page;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (w <= 0) return;
    if (host._tool == _Tool.editText) {
      final fill = Paint()..color = const Color(0x141E6FE6);
      final outline = Paint()
        ..color = const Color(0xFF1E6FE6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      for (final line in host._linesOf(page)) {
        final r = Rect.fromLTRB(line.rect.left * w, line.rect.top * w, line.rect.right * w, line.rect.bottom * w);
        canvas.drawRect(r, fill);
        _dashedRect(canvas, r, outline, 6, 4, 0);
      }
    }
    final items = host._items[page] ?? const <_Item>[];
    final lifted = host._lifted ? host._target : null;
    _drawItems(canvas, items, w, skip: lifted);
    if (host._gesturePage == page) {
      if (host._op == _Op.draw && host._drawing.isNotEmpty) {
        _drawItem(canvas, _InkItem(host._drawing, host._penColor, host._penWidth), w);
      }
      final mark = host._markRect;
      if (mark != null) _drawItem(canvas, _MarkItem(host._markKind, mark, host._markColor), w);
    }
    final sel = host._selected;
    if (sel != null && !identical(sel, lifted) && items.any((item) => identical(item, sel))) _drawSelection(canvas, sel, w);
  }

  @override
  bool shouldRepaint(covariant _LayerPainter oldDelegate) => true;
}

/// The text / picture being dragged, drawn above all pages.
class _LiftPainter extends CustomPainter {
  _LiftPainter(this.host, Listenable repaint) : super(repaint: repaint);

  final _MarkupPageState host;

  @override
  void paint(Canvas canvas, Size size) {
    final target = host._target;
    if (!host._lifted || target == null) return;
    canvas.save();
    canvas.translate(host._liftOrigin.dx, host._liftOrigin.dy);
    _drawItem(canvas, target, host._liftWidth);
    if (identical(target, host._selected)) _drawSelection(canvas, target, host._liftWidth);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LiftPainter oldDelegate) => true;
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.sign);

  final Signature sign;

  @override
  void paint(Canvas canvas, Size size) {
    var w = size.width;
    var h = w / sign.aspect;
    if (h > size.height) {
      h = size.height;
      w = h * sign.aspect;
    }
    canvas.translate((size.width - w) / 2, (size.height - h) / 2);
    drawStrokes(
      canvas,
      [
        for (final stroke in sign.strokes) [for (final p in stroke) Offset(p.dx * w, p.dy * h)],
      ],
      Color(sign.color),
      sign.width * w,
      widths: [for (final value in sign.widths) math.max(0.6, value * w)],
    );
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => oldDelegate.sign != sign;
}
