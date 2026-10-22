import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
import '../../services/image_ops.dart';
import '../../services/pdf_rewrite.dart';
import '../../services/pdf_tools.dart';
import '../../services/signature_store.dart';
import '../../widgets/chrome.dart';
import '../create/tool_widgets.dart';
import 'editor_flow.dart';
import 'signature_pad.dart';

/// The 15 colours of Add text / Annotate (like the Android app).
const editColors = <int>[
  0xFF000000, 0xFFFFFFFF, 0xFF8A8F98, 0xFFE53935, 0xFF22C55E, //
  0xFF1E3FE6, 0xFFE91E8C, 0xFF22D3EE, 0xFFFF6A13, 0xFFFBBF24,
  0xFFA3E635, 0xFF2DD4BF, 0xFF38BDF8, 0xFF8B3CF6, 0xFFF87171,
];

enum _Mode { none, editText, addText, addImage, annotate, sign }

enum _Drag { none, move, resize, ink, erase }

enum _Handle { none, delete, resize, duplicate, edit }

const double _textPad = 3;

class _Shot {
  _Shot(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final double width;
  final double height;
}

/// Something placed on a page: text, a picture or a signature. Positions are in page points
/// (top-left origin); [rotation] is in radians, clockwise.
abstract class _Obj {
  _Obj({required this.page, required this.center, this.rotation = 0});

  int page;
  Offset center;
  double rotation;

  Size get box;
  void scaleBy(double factor);
  _Obj clone();
}

TextPainter _layoutText(String text, double size, int color) {
  return TextPainter(
    text: TextSpan(text: text.isEmpty ? ' ' : text, style: TextStyle(fontSize: size, color: Color(color), height: 1.2)),
    textDirection: TextDirection.ltr,
  )..layout();
}

class _TextObj extends _Obj {
  _TextObj({required super.page, required super.center, required this.text, required this.size, required this.color, this.cover, super.rotation});

  String text;
  double size;
  int color;

  /// White-out behind the text (Edit text: the old line), page points.
  final Rect? cover;

  @override
  Size get box {
    final painter = _layoutText(text, size, color);
    final result = Size(painter.width + 2 * _textPad, painter.height + 2 * _textPad);
    painter.dispose();
    return result;
  }

  @override
  void scaleBy(double factor) => size = (size * factor).clamp(4.0, 200.0);

  @override
  _Obj clone() => _TextObj(page: page, center: center, text: text, size: size, color: color, cover: cover, rotation: rotation);
}

class _ImageObj extends _Obj {
  _ImageObj({required super.page, required super.center, required this.bytes, required this.image, required this.width, super.rotation});

  final Uint8List bytes;
  final ui.Image image;
  double width;

  @override
  Size get box => Size(width, width * image.height / math.max(1, image.width));

  @override
  void scaleBy(double factor) => width = (width * factor).clamp(12.0, 3000.0);

  @override
  _Obj clone() => _ImageObj(page: page, center: center, bytes: bytes, image: image, width: width, rotation: rotation);
}

class _SignObj extends _Obj {
  _SignObj({required super.page, required super.center, required this.sign, required this.width, super.rotation});

  final Signature sign;
  double width;

  @override
  Size get box => Size(width, width / math.max(0.05, sign.aspect));

  @override
  void scaleBy(double factor) => width = (width * factor).clamp(12.0, 3000.0);

  @override
  _Obj clone() => _SignObj(page: page, center: center, sign: sign, width: width, rotation: rotation);
}

class _Ink {
  _Ink(this.page, this.tool, this.points, this.color, this.width);

  final int page;
  final MarkTool tool;
  final List<Offset> points;
  final int color;
  final double width;

  _Ink copy() => _Ink(page, tool, List<Offset>.of(points), color, width);
}

Offset _rot(Offset v, double a) => Offset(v.dx * math.cos(a) - v.dy * math.sin(a), v.dx * math.sin(a) + v.dy * math.cos(a));

/// PDF editor: Edit text (tap a line to retype it), Add text, Add image, Annotate and Sign.
/// Texts, pictures and signatures can be moved, resized and turned (bottom-right handle),
/// duplicated (bottom-left), edited (top-right) and deleted (top-left). Done writes everything
/// into the PDF, shows "Saved successfully" and stays here.
class MarkupPage extends StatefulWidget {
  const MarkupPage({super.key, required this.entry, required this.tool});

  final DocEntry entry;
  final MarkTool tool;

  @override
  State<MarkupPage> createState() => _MarkupPageState();
}

class _MarkupPageState extends State<MarkupPage> {
  final Map<int, _Shot> _shots = {};
  PdfDocument? _document;
  String _path = '';
  int _page = 1;
  int _pages = 1;
  bool _loading = true;
  bool _saving = false;
  bool _changed = false;

  List<_Obj> _objects = [];
  List<_Ink> _inks = [];
  _Obj? _selected;
  final List<(List<_Obj>, List<_Ink>)> _undo = [];
  final List<(List<_Obj>, List<_Ink>)> _redo = [];

  _Mode _mode = _Mode.none;
  MarkTool _annTool = MarkTool.pen;
  int _annTab = 0;
  int _textColor = 0xFFE91E8C;
  double _textSize = 18;
  int _inkColor = 0xFFE53935;
  double _inkSize = 4;

  List<List<PdfTextLine>>? _lines;
  final Set<String> _editedLines = {};
  List<Signature> _signatures = [];

  // gesture state
  _Drag _drag = _Drag.none;
  Offset _dragStartPage = Offset.zero;
  Offset _startCenter = Offset.zero;
  double _startRotation = 0;
  double _startDistance = 1;
  double _startAngle = 0;
  _Obj? _startClone;
  Rect _pageRect = Rect.zero;
  double _k = 1;

  bool get _hasLines => _lines?.any((page) => page.isNotEmpty) ?? false;

  @override
  void initState() {
    super.initState();
    _annTool = switch (widget.tool) {
      MarkTool.highlight => MarkTool.highlight,
      MarkTool.underline => MarkTool.underline,
      MarkTool.strike => MarkTool.strike,
      MarkTool.eraser => MarkTool.eraser,
      _ => MarkTool.pen,
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_path.isNotEmpty) return;
    _path = AppScope.of(context).library.fileOf(widget.entry).path;
    _open();
  }

  @override
  void dispose() {
    _document?.close();
    super.dispose();
  }

  Future<void> _open({bool first = true}) async {
    try {
      final document = await PdfDocument.openFile(_path);
      _document = document;
      _pages = document.pagesCount;
      _page = _page.clamp(1, math.max(1, _pages));
      await _ensureShot(_page);
    } catch (_) {
      if (!mounted) return;
      showToast(context, S.of(context).t('pdfProtected'), warning: true);
      Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    _loadLines();
    final signatures = await SignatureStore.list();
    if (!mounted) return;
    setState(() => _signatures = signatures);
    if (!first) return;
    final settings = AppScope.of(context).settings;
    if (!settings.markupTipSeen) {
      await settings.setFlag('markupTipSeen', true);
      if (!mounted) return;
      final choice = await showEditTutorial(context);
      if (!mounted) return;
      if (choice == 'sign') {
        await _selectMode(_Mode.sign);
        return;
      }
      if (choice == 'edit') {
        await _selectMode(_Mode.editText);
        return;
      }
    }
    final start = switch (widget.tool) {
      MarkTool.text => _Mode.addText,
      MarkTool.editText => _Mode.editText,
      MarkTool.image => _Mode.addImage,
      MarkTool.sign => _Mode.sign,
      _ => _Mode.annotate,
    };
    await _selectMode(start, quiet: true);
  }

  Future<void> _loadLines() async {
    try {
      final bytes = await File(_path).readAsBytes();
      final lines = await _readLinesIsolated(bytes);
      if (!mounted) return;
      setState(() => _lines = lines ?? const []);
    } catch (_) {
      if (mounted) setState(() => _lines = const []);
    }
  }

  Future<_Shot?> _ensureShot(int page) async {
    final cached = _shots[page];
    if (cached != null) return cached;
    final document = _document;
    if (document == null) return null;
    final pdfPage = await document.getPage(page);
    final rendered = await pdfPage.render(
      width: pdfPage.width * 1.6,
      height: pdfPage.height * 1.6,
      format: PdfPageImageFormat.jpeg,
      backgroundColor: '#FFFFFF',
      quality: 88,
    );
    final shot = rendered == null ? null : _Shot(rendered.bytes, pdfPage.width, pdfPage.height);
    await pdfPage.close();
    if (shot != null) _shots[page] = shot;
    return shot;
  }

  // ------------------------------------------------------------------ history

  void _checkpoint() {
    _undo.add(([for (final obj in _objects) obj.clone()], [for (final ink in _inks) ink.copy()]));
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
    _changed = true;
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(([for (final obj in _objects) obj.clone()], [for (final ink in _inks) ink.copy()]));
      final previous = _undo.removeLast();
      _objects = previous.$1;
      _inks = previous.$2;
      _selected = null;
      _changed = true;
    });
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(([for (final obj in _objects) obj.clone()], [for (final ink in _inks) ink.copy()]));
      final next = _redo.removeLast();
      _objects = next.$1;
      _inks = next.$2;
      _selected = null;
      _changed = true;
    });
  }

  // ------------------------------------------------------------------ modes

  Future<void> _selectMode(_Mode mode, {bool quiet = false}) async {
    if (mode == _Mode.editText && !_hasLines) {
      if (_lines == null) {
        // still reading the text; try again when it is there
        await _loadLines();
        if (!mounted) return;
      }
      if (!_hasLines) {
        if (!quiet) showToast(context, S.of(context).t('noEditableText'));
        mode = _Mode.addText;
      }
    }
    setState(() {
      _mode = mode;
      _selected = null;
      if (mode == _Mode.editText) _textColor = 0xFF000000;
    });
    if (mode == _Mode.addImage) await _addImage();
    if (mode == _Mode.sign && _signatures.isEmpty && !quiet) await _newSignature();
  }

  Future<void> _addImage() async {
    final shot = _shots[_page];
    if (shot == null) return;
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    try {
      var bytes = await File(file.path).readAsBytes();
      final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
      if (!png || bytes.length > 1500000) {
        final buf = await loadPixels(file.path, 1800);
        if (buf != null) bytes = await jpegOf(buf, quality: 88);
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _checkpoint();
        final obj = _ImageObj(
          page: _page,
          center: Offset(shot.width / 2, shot.height / 2),
          bytes: bytes,
          image: frame.image,
          width: shot.width * 0.45,
        );
        _objects.add(obj);
        _selected = obj;
      });
    } catch (_) {
      if (mounted) showToast(context, S.of(context).t('imageFailed'), warning: true);
    }
  }

  Future<void> _newSignature() async {
    final sign = await Navigator.of(context).push<Signature>(MaterialPageRoute(builder: (_) => const SignaturePadPage()));
    if (sign == null || !mounted) return;
    final saved = await SignatureStore.save(sign);
    if (!mounted) return;
    setState(() => _signatures = [saved, ..._signatures]);
    _placeSignature(saved);
  }

  void _placeSignature(Signature sign) {
    final shot = _shots[_page];
    if (shot == null) return;
    setState(() {
      _checkpoint();
      final obj = _SignObj(page: _page, center: Offset(shot.width / 2, shot.height * 0.72), sign: sign, width: shot.width * 0.36);
      _objects.add(obj);
      _selected = obj;
    });
  }

  Future<void> _deleteSignature(Signature sign) async {
    final s = S.of(context);
    final ok = await confirmSheet(context, title: s.t('deleteSignature'), message: s.t('deleteSignatureMessage'), ok: s.t('delete'));
    if (!ok) return;
    await SignatureStore.delete(sign);
    if (!mounted) return;
    setState(() => _signatures = _signatures.where((item) => item.file != sign.file).toList());
  }

  Future<void> _addTextAt(Offset point) async {
    final value = await enterText(context);
    if (value == null || value.trim().isEmpty || !mounted) return;
    setState(() {
      _checkpoint();
      final obj = _TextObj(page: _page, center: point, text: value.trimRight(), size: _textSize, color: _textColor);
      _objects.add(obj);
      _selected = obj;
    });
  }

  Future<void> _editTextObj(_TextObj obj) async {
    final value = await enterText(context, initial: obj.text);
    if (value == null || !mounted) return;
    setState(() {
      _checkpoint();
      if (value.trim().isEmpty && obj.cover == null) {
        _objects.remove(obj);
        _selected = null;
      } else {
        obj.text = value.trimRight();
      }
    });
  }

  Future<void> _editLine(int index, PdfTextLine line, _Shot shot) async {
    final value = await enterText(context, initial: line.readable ? line.text : '');
    if (value == null || !mounted) return;
    final w = shot.width;
    final h = shot.height;
    final size = (line.size * h).clamp(4.0, 120.0);
    final cover = Rect.fromLTRB(line.left * w - 1, line.top * h - 1, line.right * w + 2, line.bottom * h + 1);
    final text = value.trimRight();
    final probe = _TextObj(page: _page, center: Offset.zero, text: text, size: size, color: _textColor);
    final box = probe.box;
    final topLeft = Offset(line.left * w - _textPad, line.top * h - _textPad);
    setState(() {
      _checkpoint();
      _editedLines.add('$_page:$index');
      final obj = _TextObj(
        page: _page,
        center: topLeft + Offset(box.width / 2, box.height / 2),
        text: text,
        size: size,
        color: _textColor,
        cover: cover,
      );
      _objects.add(obj);
      _selected = obj;
    });
  }

  // ------------------------------------------------------------------ gestures

  Offset _toPage(Offset local) => (local - _pageRect.topLeft) / _k;

  Offset _toScreen(Offset page) => _pageRect.topLeft + page * _k;

  Map<_Handle, Offset> _handles(_Obj obj) {
    final box = obj.box;
    Offset corner(double x, double y) => _toScreen(obj.center + _rot(Offset(x * box.width / 2, y * box.height / 2), obj.rotation));
    return {
      _Handle.delete: corner(-1, -1),
      _Handle.resize: corner(1, 1),
      _Handle.duplicate: corner(-1, 1),
      if (obj is _TextObj) _Handle.edit: corner(1, -1),
    };
  }

  _Handle _hitHandle(Offset local) {
    final obj = _selected;
    if (obj == null || obj.page != _page) return _Handle.none;
    for (final entry in _handles(obj).entries) {
      if ((entry.value - local).distance <= 22) return entry.key;
    }
    return _Handle.none;
  }

  _Obj? _hitObject(Offset local) {
    final point = _toPage(local);
    for (final obj in _objects.reversed) {
      if (obj.page != _page) continue;
      final box = obj.box;
      final p = _rot(point - obj.center, -obj.rotation);
      final pad = 8 / _k;
      if (p.dx.abs() <= box.width / 2 + pad && p.dy.abs() <= box.height / 2 + pad) return obj;
    }
    return null;
  }

  Future<void> _onTap(Offset local, _Shot shot) async {
    final handle = _hitHandle(local);
    final selected = _selected;
    if (handle != _Handle.none && selected != null) {
      switch (handle) {
        case _Handle.delete:
          setState(() {
            _checkpoint();
            _objects.remove(selected);
            _selected = null;
          });
        case _Handle.duplicate:
          setState(() {
            _checkpoint();
            final copy = selected.clone()..center = selected.center + Offset(16 / _k + 12, 16 / _k + 12);
            _objects.add(copy);
            _selected = copy;
          });
        case _Handle.edit:
          if (selected is _TextObj) await _editTextObj(selected);
        case _Handle.resize:
        case _Handle.none:
          break;
      }
      return;
    }
    final hit = _hitObject(local);
    if (hit != null) {
      if (hit == selected && hit is _TextObj) {
        await _editTextObj(hit);
      } else {
        setState(() => _selected = hit);
      }
      return;
    }
    if (selected != null) {
      setState(() => _selected = null);
      return;
    }
    final point = _toPage(local);
    if (point.dx < 0 || point.dy < 0 || point.dx > shot.width || point.dy > shot.height) return;
    if (_mode == _Mode.editText) {
      final lines = _lines;
      if (lines == null || _page - 1 >= lines.length) return;
      final pageLines = lines[_page - 1];
      for (var i = 0; i < pageLines.length; i++) {
        final line = pageLines[i];
        if (_editedLines.contains('$_page:$i')) continue;
        final rect = Rect.fromLTRB(line.left * shot.width, line.top * shot.height, line.right * shot.width, line.bottom * shot.height).inflate(3);
        if (rect.contains(point)) {
          await _editLine(i, line, shot);
          return;
        }
      }
      return;
    }
    if (_mode == _Mode.addText) await _addTextAt(point);
  }

  void _onPanStart(Offset local) {
    final handle = _hitHandle(local);
    final selected = _selected;
    if (handle == _Handle.resize && selected != null) {
      _drag = _Drag.resize;
      _startClone = selected.clone();
      _startCenter = selected.center;
      final finger = _toPage(local) - selected.center;
      _startDistance = math.max(1.0, finger.distance);
      _startAngle = math.atan2(finger.dy, finger.dx);
      _startRotation = selected.rotation;
      _checkpoint();
      return;
    }
    final hit = _hitObject(local);
    if (hit != null) {
      _drag = _Drag.move;
      _dragStartPage = _toPage(local);
      _startCenter = hit.center;
      _checkpoint();
      setState(() => _selected = hit);
      return;
    }
    if (_mode == _Mode.annotate) {
      final point = _toPage(local);
      if (_annTool == MarkTool.eraser) {
        _drag = _Drag.erase;
        _checkpoint();
        _erase(point);
        return;
      }
      _drag = _Drag.ink;
      _checkpoint();
      final width = switch (_annTool) {
        MarkTool.highlight => _inkSize * 3,
        _ => _inkSize,
      };
      final color = _annTool == MarkTool.highlight && _inkColor == 0xFFE53935 ? 0xFFFBBF24 : _inkColor;
      setState(() {
        _selected = null;
        _inks.add(_Ink(_page, _annTool, [point], color, width));
      });
      return;
    }
    _drag = _Drag.none;
  }

  void _onPanUpdate(Offset local) {
    final point = _toPage(local);
    switch (_drag) {
      case _Drag.move:
        final moving = _selected;
        if (moving == null) return;
        setState(() => moving.center = _startCenter + (point - _dragStartPage));
      case _Drag.resize:
        final resizing = _selected;
        final start = _startClone;
        if (resizing == null || start == null) return;
        final finger = point - _startCenter;
        final factor = (finger.distance / _startDistance).clamp(0.1, 10.0);
        final angle = math.atan2(finger.dy, finger.dx) - _startAngle;
        setState(() {
          if (resizing is _TextObj && start is _TextObj) resizing.size = (start.size * factor).clamp(4.0, 200.0);
          if (resizing is _ImageObj && start is _ImageObj) resizing.width = (start.width * factor).clamp(12.0, 3000.0);
          if (resizing is _SignObj && start is _SignObj) resizing.width = (start.width * factor).clamp(12.0, 3000.0);
          resizing.rotation = _startRotation + angle;
        });
      case _Drag.ink:
        if (_inks.isEmpty) return;
        setState(() => _inks.last.points.add(point));
      case _Drag.erase:
        _erase(point);
      case _Drag.none:
        break;
    }
  }

  void _onPanEnd() {
    if (_drag == _Drag.ink && _inks.isNotEmpty && _inks.last.points.length < 2) {
      final last = _inks.last;
      last.points.add(last.points.first + const Offset(0.5, 0.5));
    }
    _drag = _Drag.none;
    _startClone = null;
    setState(() {});
  }

  void _erase(Offset point) {
    final radius = 14 / _k;
    final before = _inks.length;
    _inks.removeWhere((ink) => ink.page == _page && ink.points.any((p) => (p - point).distance < radius + ink.width));
    if (_inks.length != before) setState(() {});
  }

  void _applyTextStyle({int? color, double? size}) {
    final obj = _selected;
    if (obj is! _TextObj) return;
    setState(() {
      if (color != null) obj.color = color;
      if (size != null) obj.size = size;
    });
  }

  Future<void> _movePage(int delta) async {
    final next = (_page + delta).clamp(1, _pages);
    if (next == _page) return;
    setState(() {
      _loading = true;
      _selected = null;
    });
    await _ensureShot(next);
    if (!mounted) return;
    setState(() {
      _page = next;
      _loading = false;
    });
  }

  // ------------------------------------------------------------------ save

  Future<void> _done() async {
    if (_saving || !_changed) return;
    final s = S.of(context);
    final scope = AppScope.of(context);
    setState(() {
      _saving = true;
      _selected = null;
    });
    final pill = ProgressPill(context)..show(s.t('saving'));
    try {
      final original = await File(_path).readAsBytes();
      final marks = <PdfVectorMark>[];
      final sizes = <int, Size>{};
      for (var page = 1; page <= _pages; page++) {
        final shot = await _ensureShot(page);
        if (shot != null) sizes[page] = Size(shot.width, shot.height);
      }
      for (final ink in _inks) {
        final size = sizes[ink.page];
        if (size == null || ink.points.isEmpty) continue;
        final underline = ink.tool == MarkTool.underline || ink.tool == MarkTool.strike;
        marks.add(
          PdfVectorMark(
            page: ink.page,
            tool: ink.tool.name,
            points: [for (final p in ink.points) (p.dx / size.width, p.dy / size.height)],
            color: ink.color,
            stroke: underline ? math.max(1.2, ink.width * 0.5) : ink.width,
          ),
        );
      }
      for (final obj in _objects) {
        final size = sizes[obj.page];
        if (size == null) continue;
        marks.addAll(await _marksOf(obj, size));
      }
      var bytes = rewritePdf(original, marks: marks);
      bytes ??= await _bake(sizes);
      await File(_path).writeAsBytes(bytes, flush: true);
      await scope.library.scan();
      // start again from the saved file
      await _document?.close();
      _document = null;
      _shots.clear();
      _objects = [];
      _inks = [];
      _undo.clear();
      _redo.clear();
      _editedLines.clear();
      _changed = false;
      await _open(first: false);
      pill.dismiss();
      if (!mounted) return;
      setState(() => _saving = false);
      await scope.ads.showInterstitial(unit: 2);
      if (!mounted) return;
      showToast(context, s.t('savedSuccessfully'));
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, s.t('saveFailed'), warning: true);
    }
  }

  Future<List<PdfVectorMark>> _marksOf(_Obj obj, Size page) async {
    final out = <PdfVectorMark>[];
    final box = obj.box;
    (double, double) frac(Offset local) {
      final p = obj.center + _rot(local, obj.rotation);
      return (p.dx / page.width, p.dy / page.height);
    }

    final degrees = obj.rotation * 180 / math.pi;
    if (obj is _TextObj) {
      final cover = obj.cover;
      if (cover != null) {
        out.add(PdfVectorMark(page: obj.page, tool: 'whiteout', points: [(cover.left / page.width, cover.top / page.height), (cover.right / page.width, cover.bottom / page.height)], color: 0xFFFFFFFF));
      }
      if (obj.text.trim().isEmpty) return out;
      if (_plainLatin(obj.text)) {
        final painter = _layoutText(obj.text, obj.size, obj.color);
        final baseline = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
        painter.dispose();
        out.add(
          PdfVectorMark(
            page: obj.page,
            tool: 'text',
            points: [frac(Offset(-box.width / 2 + _textPad, -box.height / 2 + _textPad + baseline))],
            text: obj.text,
            color: obj.color,
            size: obj.size,
            rotation: degrees,
          ),
        );
        return out;
      }
      // other scripts: the text as a transparent picture
      final png = await _textPng(obj);
      if (png != null) {
        out.add(_stamp(obj, page, png, box, degrees));
      }
      return out;
    }
    if (obj is _ImageObj) {
      out.add(_stamp(obj, page, obj.bytes, box, degrees));
      return out;
    }
    if (obj is _SignObj) {
      final sign = obj.sign;
      for (final stroke in sign.strokes) {
        if (stroke.isEmpty) continue;
        final points = [for (final p in stroke) frac(Offset((p.dx - 0.5) * box.width, (p.dy - 0.5) * box.height))];
        if (points.length == 1) points.add((points.first.$1 + 0.0005, points.first.$2));
        out.add(PdfVectorMark(page: obj.page, tool: 'pen', points: points, color: sign.color, stroke: math.max(0.4, sign.width * box.width)));
      }
    }
    return out;
  }

  PdfVectorMark _stamp(_Obj obj, Size page, Uint8List bytes, Size box, double degrees) {
    return PdfVectorMark(
      page: obj.page,
      tool: 'stamp',
      points: [(obj.center.dx / page.width, obj.center.dy / page.height)],
      image: bytes,
      width: box.width / page.width,
      height: box.height / page.height,
      rotation: degrees,
    );
  }

  bool _plainLatin(String text) {
    for (final rune in text.runes) {
      if (rune == 10) continue;
      if (rune >= 0x20 && rune <= 0x7E) continue;
      if (rune >= 0xA0 && rune <= 0xFF) continue;
      return false;
    }
    return true;
  }

  Future<Uint8List?> _textPng(_TextObj obj) async {
    const scale = 3.0;
    final box = obj.box;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    final painter = _layoutText(obj.text, obj.size, obj.color);
    painter.paint(canvas, const Offset(_textPad, _textPad));
    painter.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage((box.width * scale).ceil(), (box.height * scale).ceil());
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// When the PDF can't be edited in place: every page as a picture with the edits drawn on it.
  Future<Uint8List> _bake(Map<int, Size> sizes) async {
    final document = _document;
    if (document == null) throw StateError('closed');
    final pieces = <PdfPiece>[];
    for (var index = 1; index <= _pages; index++) {
      final size = sizes[index];
      if (size == null) continue;
      final page = await document.getPage(index);
      const scale = 2.0;
      final rendered = await page.render(width: size.width * scale, height: size.height * scale, format: PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
      await page.close();
      if (rendered == null) continue;
      final codec = await ui.instantiateImageCodec(rendered.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final w = (size.width * scale).round();
      final h = (size.height * scale).round();
      canvas.drawImageRect(
        frame.image,
        Rect.fromLTWH(0, 0, frame.image.width.toDouble(), frame.image.height.toDouble()),
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.scale(scale);
      _paintScene(canvas, _objects.where((obj) => obj.page == index).toList(), _inks.where((ink) => ink.page == index).toList(), k: 1);
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      picture.dispose();
      frame.image.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) continue;
      final jpeg = await rgbaToJpeg(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), w, h, quality: 88);
      pieces.add(PdfPiece(image: jpeg, pageFormat: PdfPageFormat(size.width, size.height)));
    }
    return rebuildPdf(pieces);
  }

  Future<void> _close() async {
    if (_saving) return;
    if (!_changed) {
      Navigator.of(context).pop();
      return;
    }
    final s = S.of(context);
    final discard = await confirmSheet(context, title: s.t('discardTitle'), message: s.t('discardMessage'), ok: s.t('discard'));
    if (discard && mounted) Navigator.of(context).pop();
  }

  Future<void> _tutorial() async {
    final choice = await showEditTutorial(context);
    if (!mounted) return;
    if (choice == 'sign') await _selectMode(_Mode.sign);
    if (choice == 'edit') await _selectMode(_Mode.editText);
  }

  // ------------------------------------------------------------------ build

  /// Native updateBars(): undo / redo / Done show while editing; ⓘ when not (and in Sign).
  bool get _editing => _mode != _Mode.none || _changed || _undo.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final shot = _shots[_page];
    final editing = _editing;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        // × ⓘ … undo redo [Done]
        appBar: AppBar(
          toolbarHeight: 56,
          backgroundColor: nc.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          title: Row(
            children: [
              const SizedBox(width: 4),
              NativeIconButton(ND.icClose, padding: 11, tint: nc.textPrimary, tooltip: s.t('cancel'), onPressed: _close),
              if (!editing || _mode == _Mode.sign)
                NativeIconButton(ND.icInfo, size: 40, padding: 9, tint: nc.textPrimary, tooltip: s.t('howToEdit'), onPressed: _tutorial),
              const Spacer(),
              if (editing) ...[
                NativeIconButton(
                  ND.icUndo,
                  tint: _undo.isEmpty || _saving ? const Color(0xFFC3C8D0) : nc.textPrimary,
                  tooltip: s.t('undo'),
                  onPressed: _undo.isEmpty || _saving ? null : _undoStep,
                ),
                NativeIconButton(
                  ND.icRedo,
                  tint: _redo.isEmpty || _saving ? const Color(0xFFC3C8D0) : nc.textPrimary,
                  tooltip: s.t('redo'),
                  onPressed: _redo.isEmpty || _saving ? null : _redoStep,
                ),
                const SizedBox(width: 40),
                _doneButton(s),
              ],
              const SizedBox(width: 12),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: shot == null || _loading
                    ? Center(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: nc.primary)))
                    : Stack(
                        children: [
                          Positioned.fill(child: _pageArea(shot)),
                          if (_pages > 1) Positioned(left: 0, right: 0, bottom: 10, child: Center(child: _pageNav(s))),
                        ],
                      ),
              ),
            ),
            Material(
              color: nc.surface,
              child: SafeArea(
                top: false,
                child: _mode == _Mode.none ? _modeBar(s, nc) : _panel(s, nc),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// btnDone: 34dp bg_done_btn (#111317; #D9DCE1 when off), min 64dp, a white spinner while saving.
  Widget _doneButton(S s) {
    final enabled = !_saving && _changed;
    return Material(
      color: enabled || _saving ? const Color(0xFF111317) : const Color(0xFFD9DCE1),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? _done : null,
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

  /// "‹ 1 / 3 ›" over the black page area (the Flutter editor shows one page at a time).
  Widget _pageNav(S s) {
    Widget arrow(bool enabled, VoidCallback onTap) => NativeIconButton(
          ND.icChevronRight,
          size: 36,
          padding: 8,
          tint: enabled ? Colors.white : const Color(0x66FFFFFF),
          onPressed: enabled ? onTap : null,
        );
    return Container(
      height: 36,
      decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(18)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(angle: math.pi, child: arrow(_page > 1 && !_loading, () => _movePage(-1))),
          Text(s.t('ofPages', {'current': '$_page', 'total': '$_pages'}), style: const TextStyle(fontSize: 13, color: Colors.white)),
          arrow(_page < _pages && !_loading, () => _movePage(1)),
        ],
      ),
    );
  }

  Widget _pageArea(_Shot shot) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Rect.fromLTWH(12, 12, constraints.maxWidth - 24, constraints.maxHeight - 24);
        final aspect = shot.width / shot.height;
        Rect rect;
        if (area.width / area.height > aspect) {
          final w = area.height * aspect;
          rect = Rect.fromLTWH(area.left + (area.width - w) / 2, area.top, w, area.height);
        } else {
          final h = area.width / aspect;
          rect = Rect.fromLTWH(area.left, area.top + (area.height - h) / 2, area.width, h);
        }
        _pageRect = rect;
        _k = rect.width / shot.width;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _onTap(details.localPosition, shot),
          onPanStart: (details) => _onPanStart(details.localPosition),
          onPanUpdate: (details) => _onPanUpdate(details.localPosition),
          onPanEnd: (_) => _onPanEnd(),
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: ColoredBox(color: Colors.white, child: Image.memory(shot.bytes, fit: BoxFit.fill, gaplessPlayback: true)),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _ScenePainter(
                    rect: rect,
                    k: _k,
                    objects: _objects.where((obj) => obj.page == _page).toList(),
                    inks: _inks.where((ink) => ink.page == _page).toList(),
                    selected: _selected?.page == _page ? _selected : null,
                    lines: _mode == _Mode.editText && _lines != null && _page - 1 < _lines!.length
                        ? [
                            for (var i = 0; i < _lines![_page - 1].length; i++)
                              if (!_editedLines.contains('$_page:$i'))
                                Rect.fromLTRB(
                                  _lines![_page - 1][i].left * shot.width,
                                  _lines![_page - 1][i].top * shot.height,
                                  _lines![_page - 1][i].right * shot.width,
                                  _lines![_page - 1][i].bottom * shot.height,
                                ),
                          ]
                        : const [],
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
                          tint: color == 0xFFFFFFFF || color == 0xFFFBBF24 || color == 0xFFA3E635 ? Colors.black : Colors.white,
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
  Widget _seek({required double value, required double min, required double max, int? divisions, ValueChanged<double>? onStart, required ValueChanged<double> onChanged}) {
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
      child: Slider(value: value, min: min, max: max, divisions: divisions, onChangeStart: onStart, onChanged: onChanged),
    );
  }

  Widget _backChevron({double size = 40, double padding = 11}) {
    final nc = NC.of(context);
    return Transform.rotate(
      angle: math.pi,
      child: NativeIconButton(ND.icChevronRight, size: size, padding: padding, tint: nc.textPrimary, onPressed: () => _selectMode(_Mode.none)),
    );
  }

  static const _textSizes = <int>[6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 36, 48, 56, 72];

  Widget _panel(S s, NC nc) {
    switch (_mode) {
      case _Mode.addText:
      case _Mode.editText:
        // textPanel: ‹ + hint field, colours, size SeekBar + "18 ▾"
        final selected = _selected;
        final color = selected is _TextObj ? selected.color : _textColor;
        final size = selected is _TextObj ? selected.size.clamp(6.0, 72.0) : _textSize;
        final shot = _shots[_page];
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
                    _backChevron(),
                    Expanded(
                      child: Material(
                        color: nc.surfaceVariant,
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: _mode == _Mode.addText && shot != null ? () => _addTextAt(Offset(shot.width / 2, shot.height / 2)) : null,
                          child: Container(
                            height: 32,
                            alignment: AlignmentDirectional.centerStart,
                            padding: const EdgeInsetsDirectional.only(start: 14),
                            child: Text(
                              _mode == _Mode.editText ? s.t('tapTextToEdit') : s.t('tapAnywhereAddText'),
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
              _colorRow(color, (value) {
                setState(() => _textColor = value);
                if (selected is _TextObj) {
                  _checkpoint();
                  _applyTextStyle(color: value);
                }
              }),
              Container(
                height: 36,
                padding: const EdgeInsetsDirectional.only(start: 4, end: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _seek(
                        value: size.toDouble(),
                        min: 6,
                        max: 72,
                        divisions: 66,
                        onStart: (_) {
                          if (_selected is _TextObj) _checkpoint();
                        },
                        onChanged: (value) {
                          setState(() => _textSize = value);
                          _applyTextStyle(size: value);
                        },
                      ),
                    ),
                    // tvTextSize: 52 x 30 bg_search_field with ▾ → list of sizes (bg_size_popup)
                    PopupMenuButton<int>(
                      tooltip: '',
                      padding: EdgeInsets.zero,
                      color: nc.surface,
                      elevation: 4,
                      constraints: const BoxConstraints(minWidth: 56, maxWidth: 56, maxHeight: 200),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: nc.divider)),
                      position: PopupMenuPosition.over,
                      onSelected: (value) {
                        if (_selected is _TextObj) _checkpoint();
                        setState(() => _textSize = value.toDouble());
                        _applyTextStyle(size: value.toDouble());
                      },
                      itemBuilder: (context) => [
                        for (final option in _textSizes)
                          PopupMenuItem<int>(
                            value: option,
                            height: 34,
                            padding: const EdgeInsets.only(left: 14, right: 8),
                            child: Text(
                              '$option',
                              style: TextStyle(fontSize: 13, color: option == size.round() ? nc.primary : nc.textPrimary),
                            ),
                          ),
                      ],
                      child: Container(
                        width: 52,
                        height: 30,
                        padding: const EdgeInsetsDirectional.only(start: 8, end: 6),
                        decoration: BoxDecoration(color: nc.surfaceVariant, borderRadius: BorderRadius.circular(22)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text('${size.round()}', maxLines: 1, style: TextStyle(fontSize: 13, color: nc.textPrimary)),
                            ),
                            const SizedBox(width: 2),
                            NativeIcon(ND.icCaretDown, size: 12, tint: nc.textPrimary),
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
      case _Mode.annotate:
        // annotatePanel: Color / Size tabs + colours or SeekBar; ‹ eraser highlight underline strike pen
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
        Widget tool(MarkTool value, NDrawable icon, String tip) {
          final on = _annTool == value;
          return Expanded(
            child: NativeIconButton(icon, padding: 11, tint: on ? nc.primary : nc.textPrimary, tooltip: tip, onPressed: () => setState(() => _annTool = value)),
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
                    _annTab == 0,
                    Container(width: 14, height: 14, decoration: BoxDecoration(color: Color(_inkColor), shape: BoxShape.circle)),
                    s.t('color'),
                    () => setState(() => _annTab = 0),
                  ),
                  tab(_annTab == 1, NativeIcon(ND.icPen, size: 16, tint: nc.textPrimary), s.t('sizeLabel'), () => setState(() => _annTab = 1)),
                  Expanded(
                    child: _annTab == 0
                        ? _colorRow(_inkColor, (value) => setState(() => _inkColor = value), padding: const EdgeInsetsDirectional.only(start: 8, end: 12))
                        : _seek(value: _inkSize, min: 1, max: 14, onChanged: (value) => setState(() => _inkSize = value)),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  Expanded(child: Center(child: _backChevron(size: 44, padding: 12))),
                  tool(MarkTool.eraser, ND.icEraser, s.t('eraser')),
                  tool(MarkTool.highlight, ND.icTextHighlight, s.t('highlight')),
                  tool(MarkTool.underline, ND.icUnderline, s.t('underline')),
                  tool(MarkTool.strike, ND.icStrike, s.t('strike')),
                  tool(MarkTool.pen, ND.icPen, s.t('pen')),
                ],
              ),
            ),
          ],
        );
      case _Mode.sign:
        // signPanel 72dp: ‹ and "+ Add signature", or "+ Add" and the saved signatures
        return Container(
          height: 72,
          padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
          child: Row(
            children: [
              _backChevron(),
              Expanded(
                child: _signatures.isEmpty
                    ? Material(
                        color: nc.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          splashColor: const Color(0x1F1E6FE6),
                          onTap: _newSignature,
                          child: SizedBox(
                            height: 44,
                            child: Center(
                              child: Text(s.t('addSignature'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.primary)),
                            ),
                          ),
                        ),
                      )
                    : SizedBox(
                        height: 56,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            Center(
                              child: Material(
                                color: nc.surfaceVariant,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  splashColor: const Color(0x1F1E6FE6),
                                  onTap: _newSignature,
                                  child: SizedBox(
                                    width: 52,
                                    height: 52,
                                    child: Center(
                                      child: Text(s.t('addShort'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: nc.primary)),
                                    ),
                                  ),
                                ),
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
                                        onTap: () => _placeSignature(sign),
                                        onLongPress: () => _deleteSignature(sign),
                                        child: Container(
                                          width: 90,
                                          height: 48,
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: nc.surfaceVariant,
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(color: const Color(0xFFE1E5EC)),
                                          ),
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
      case _Mode.addImage:
        return Container(
          height: 72,
          padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
          child: Row(
            children: [
              _backChevron(),
              Expanded(
                child: Material(
                  color: nc.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    splashColor: const Color(0x1F1E6FE6),
                    onTap: _addImage,
                    child: SizedBox(
                      height: 44,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          NativeIcon(ND.icEtAddImage, size: 22, tint: nc.primary),
                          const SizedBox(width: 8),
                          Text(s.t('addImage'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.primary)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case _Mode.none:
        return const SizedBox();
    }
  }

  /// mainTools: 62dp, item_bottom_tool × 5 (Edit text, Add text, Add image, Annotate, Sign).
  Widget _modeBar(S s, NC nc) {
    final modes = <(_Mode, NDrawable, String)>[
      (_Mode.editText, ND.icEtEditText, s.t('editText')),
      (_Mode.addText, ND.icEtAddText, s.t('addText')),
      (_Mode.addImage, ND.icEtAddImage, s.t('addImage')),
      (_Mode.annotate, ND.icEtAnnotate, s.t('annotate')),
      (_Mode.sign, ND.icEtSign, s.t('sign')),
    ];
    return SizedBox(
      height: 62,
      child: Row(
        children: [
          for (final mode in modes)
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: InkResponse(
                  radius: 36,
                  onTap: _saving ? null : () => _selectMode(mode.$1),
                  child: Builder(
                    builder: (context) {
                      final dim = mode.$1 == _Mode.editText && _lines != null && !_hasLines;
                      final color = dim ? const Color(0xFFC3C8D0) : nc.textPrimary;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          NativeIcon(mode.$2, size: 22, tint: color),
                          const SizedBox(height: 3),
                          Text(mode.$3, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color)),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<List<List<PdfTextLine>>?> _readLinesIsolated(Uint8List bytes) => Isolate.run(() => readPdfTextLines(bytes));

/// Draws the inks and placed things of one page in page points (times [k] for screen pixels is
/// applied by the caller's canvas transform).
void _paintScene(Canvas canvas, List<_Obj> objects, List<_Ink> inks, {required double k, _Obj? selected}) {
  for (final ink in inks) {
    if (ink.points.isEmpty) continue;
    final color = Color(ink.color);
    if (ink.tool == MarkTool.underline || ink.tool == MarkTool.strike) {
      final xs = ink.points.map((p) => p.dx);
      final ys = ink.points.map((p) => p.dy);
      final minX = xs.reduce(math.min);
      final maxX = xs.reduce(math.max);
      final minY = ys.reduce(math.min);
      final maxY = ys.reduce(math.max);
      final y = ink.tool == MarkTool.underline ? maxY : (minY + maxY) / 2;
      canvas.drawLine(
        Offset(minX, y),
        Offset(maxX, y),
        Paint()
          ..color = color
          ..strokeWidth = math.max(1.2, ink.width * 0.5),
      );
      continue;
    }
    if (ink.tool == MarkTool.highlight) {
      final paint = Paint()
        ..color = color.withValues(alpha: 0.4)
        ..strokeWidth = ink.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = BlendMode.multiply;
      final path = Path()..moveTo(ink.points.first.dx, ink.points.first.dy);
      for (final p in ink.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
      continue;
    }
    drawStrokes(canvas, [ink.points], color, ink.width);
  }
  for (final obj in objects) {
    final box = obj.box;
    if (obj is _TextObj && obj.cover != null) {
      canvas.drawRect(obj.cover!, Paint()..color = Colors.white);
    }
    canvas.save();
    canvas.translate(obj.center.dx, obj.center.dy);
    canvas.rotate(obj.rotation);
    final rect = Rect.fromCenter(center: Offset.zero, width: box.width, height: box.height);
    if (obj is _TextObj) {
      final painter = _layoutText(obj.text, obj.size, obj.color);
      painter.paint(canvas, rect.topLeft + const Offset(_textPad, _textPad));
      painter.dispose();
    } else if (obj is _ImageObj) {
      canvas.drawImageRect(
        obj.image,
        Rect.fromLTWH(0, 0, obj.image.width.toDouble(), obj.image.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else if (obj is _SignObj) {
      canvas.save();
      canvas.translate(rect.left, rect.top);
      drawStrokes(
        canvas,
        [
          for (final stroke in obj.sign.strokes) [for (final p in stroke) Offset(p.dx * box.width, p.dy * box.height)],
        ],
        Color(obj.sign.color),
        math.max(0.4, obj.sign.width * box.width),
      );
      canvas.restore();
    }
    if (obj == selected) _paintSelection(canvas, obj, rect, k);
    canvas.restore();
  }
}

/// EditRenderer.drawSelection: pictures get a solid #1E6FE6 box, text a white-over-dark dashed
/// box; white 9dp handles with a #33000000 ring and stroked icons (red ×, copy, pencil, resize).
void _paintSelection(Canvas canvas, _Obj obj, Rect rect, double k) {
  final d = 1 / k;
  if (obj is _TextObj) {
    _dashedRect(canvas, rect, Paint()
      ..color = const Color(0x99000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * d, 5 * d, 4 * d, 0);
    _dashedRect(canvas, rect, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * d, 5 * d, 4 * d, 5 * d);
  } else {
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF1E6FE6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 * d,
    );
  }
  final r = 9 * d;
  final kk = r * 0.45;
  final fill = Paint()..color = Colors.white;
  final ring = Paint()
    ..color = const Color(0x33000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = d;
  final icon = Paint()
    ..color = const Color(0xFF1B1F2A)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1.5 * d;
  void disc(Offset c) {
    canvas.drawCircle(c, r, fill);
    canvas.drawCircle(c, r, ring);
  }

  // delete (top-left): red ×
  final del = rect.topLeft;
  disc(del);
  final x = r * 0.38;
  final red = Paint()
    ..color = const Color(0xFFF0483E)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1.5 * d;
  canvas.drawLine(del + Offset(-x, -x), del + Offset(x, x), red);
  canvas.drawLine(del + Offset(x, -x), del + Offset(-x, x), red);
  // copy (bottom-left)
  final copy = rect.bottomLeft;
  disc(copy);
  final c = kk * 1.1;
  canvas.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTRB(copy.dx - c * 0.9, copy.dy - c * 0.4, copy.dx + c * 0.4, copy.dy + c * 0.9), Radius.circular(1.5 * d)),
    icon,
  );
  canvas.drawLine(copy + Offset(-c * 0.4, -c * 0.9), copy + Offset(c * 0.9, -c * 0.9), icon);
  canvas.drawLine(copy + Offset(c * 0.9, -c * 0.9), copy + Offset(c * 0.9, c * 0.4), icon);
  // resize (bottom-right)
  final scale = rect.bottomRight;
  disc(scale);
  canvas.drawLine(scale + Offset(-kk, -kk), scale + Offset(kk, kk), icon);
  canvas.drawLine(scale + Offset(kk, kk), scale + Offset(kk * 0.1, kk), icon);
  canvas.drawLine(scale + Offset(kk, kk), scale + Offset(kk, kk * 0.1), icon);
  canvas.drawLine(scale + Offset(-kk, -kk), scale + Offset(-kk * 0.1, -kk), icon);
  canvas.drawLine(scale + Offset(-kk, -kk), scale + Offset(-kk, -kk * 0.1), icon);
  // edit (top-right, text)
  if (obj is _TextObj) {
    final edit = rect.topRight;
    disc(edit);
    canvas.drawLine(edit + Offset(-kk, kk), edit + Offset(kk * 0.8, -kk * 0.8), icon);
    canvas.drawLine(edit + Offset(-kk, kk), edit + Offset(-kk * 0.55, kk * 0.1), icon);
    canvas.drawLine(edit + Offset(-kk, kk), edit + Offset(-kk * 0.1, kk * 0.55), icon);
  }
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

class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.rect, required this.k, required this.objects, required this.inks, required this.selected, required this.lines});

  final Rect rect;
  final double k;
  final List<_Obj> objects;
  final List<_Ink> inks;
  final _Obj? selected;
  final List<Rect> lines;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(rect.inflate(30));
    canvas.translate(rect.left, rect.top);
    canvas.scale(k);
    // EditLayerView: editable lines with a #141E6FE6 fill and a dashed 1.2dp #1E6FE6 outline
    final outline = Paint()
      ..color = const Color(0xFF1E6FE6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / k;
    final fill = Paint()..color = const Color(0x141E6FE6);
    for (final line in lines) {
      canvas.drawRect(line, fill);
      _dashedRect(canvas, line, outline, 6 / k, 4 / k, 0);
    }
    _paintScene(canvas, objects, inks, k: k, selected: selected);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => true;
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
      math.max(1.0, sign.width * w),
    );
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => oldDelegate.sign != sign;
}
