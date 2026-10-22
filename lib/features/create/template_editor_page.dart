import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/image_ops.dart';
import '../../widgets/chrome.dart';
import '../files/file_actions.dart';
import 'blank_pages_page.dart';
import 'template_model.dart';
import 'template_painter.dart';
import 'tool_widgets.dart';

const _tplColors = <int>[
  0xFF000000, 0xFFFFFFFF, 0xFF8A8F98, 0xFFFF1A1A, 0xFF1ED41E, 0xFF1A1AFF, //
  0xFFFF1AC6, 0xFF1AE5F0, 0xFFFF8A1A, 0xFFFFD21A, 0xFF8E3CE8, 0xFF8A5A2B,
  0xFF24407A, 0xFF1E6FE6, 0xFF1F7A45, 0xFFB3262B, 0xFF6B7380, 0xFF1B1F2A,
];

enum _Gesture { none, move, rotate, pan, zoom }

enum _Panel { none, fonts, size, format }

enum _Format { png, jpg, pdf }

Offset _rotate(Offset v, double degrees) {
  final a = degrees * math.pi / 180;
  return Offset(v.dx * math.cos(a) - v.dy * math.sin(a), v.dx * math.sin(a) + v.dy * math.cos(a));
}

/// Template editor: pinch to zoom, drag the page to move around; tap a text or picture to select
/// it (blue box, duplicate + delete above it, turn-and-resize handle below it), drag to move (a
/// red guide shows when it is centred). Text: Fonts, Size & Color, Format; picture: Replace,
/// Crop, H Flip, V Flip. Undo / redo, Download as PNG / JPG / PDF, Share, "Quit now?" on back.
class TemplateEditorPage extends StatefulWidget {
  const TemplateEditorPage({super.key, required this.template});

  final Template template;

  @override
  State<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<TemplateEditorPage> {
  late TPage _page = widget.template.build();
  late final List<TPage> _history = [_page.copyPage()];
  int _index = 0;
  int _savedIndex = 0;
  TEl? _selected;
  _Panel _panel = _Panel.none;
  bool _busy = false;

  // view
  double _zoom = 1;
  Offset _pan = Offset.zero;
  double _scale = 1;
  Offset _viewCenter = Offset.zero;

  // gesture
  _Gesture _gesture = _Gesture.none;
  Offset _lastFocal = Offset.zero;
  double _startZoom = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  double _startScale = 1;
  TEl? _startCopy;
  Offset _startCenter = Offset.zero;
  double _startDistance = 1;
  double _startAngle = 0;
  bool _changed = false;
  bool _centred = false;

  bool get _dirty => _index != _savedIndex;

  // ------------------------------------------------------------------ coordinates

  Offset _toScreen(Offset page) => _viewCenter + _pan + (page - const Offset(tplPageW / 2, tplPageH / 2)) * _scale;

  Offset _toPage(Offset screen) => const Offset(tplPageW / 2, tplPageH / 2) + (screen - _viewCenter - _pan) / _scale;

  bool _selectable(TEl el) => el is TText || el is TImage;

  TEl? _hit(Offset screen) {
    final point = _toPage(screen);
    for (final el in _page.elements.reversed) {
      if (!_selectable(el)) continue;
      final size = TplRenderer.size(el);
      final center = TplRenderer.center(el);
      final local = _rotate(point - center, -el.rotation);
      final pad = 6 / _scale;
      if (local.dx.abs() <= size.width / 2 + pad && local.dy.abs() <= size.height / 2 + pad) return el;
    }
    return null;
  }

  /// Screen positions of the selected element's controls, like TemplateCanvasView: the
  /// duplicate | delete bubble (72 x 34dp) 10dp above the box, the turn handle 6dp below it; the
  /// controls stay upright.
  Map<String, Offset> _handles(TEl el) {
    final size = TplRenderer.size(el);
    final center = TplRenderer.center(el);
    Offset at(Offset local) => _toScreen(center + _rotate(local, el.rotation));
    final top = at(Offset(0, -size.height / 2 - 4 / _scale));
    final bottom = at(Offset(0, size.height / 2 + 4 / _scale));
    final bubble = top - const Offset(0, 27);
    return {
      'bubble': bubble,
      'duplicate': bubble - const Offset(18, 0),
      'delete': bubble + const Offset(18, 0),
      'rotate': bottom + const Offset(0, 20),
    };
  }

  String? _hitHandle(Offset screen) {
    final el = _selected;
    if (el == null) return null;
    for (final entry in _handles(el).entries) {
      if (entry.key == 'bubble') continue;
      if ((entry.value - screen).distance <= 20) return entry.key;
    }
    return null;
  }

  // ------------------------------------------------------------------ history

  void _commit() {
    if (_index < _history.length - 1) _history.removeRange(_index + 1, _history.length);
    _history.add(_page.copyPage());
    if (_history.length > 60) {
      _history.removeAt(0);
      _savedIndex--;
    }
    _index = _history.length - 1;
  }

  void _restore(int index) {
    setState(() {
      _index = index;
      _page = _history[index].copyPage();
      _selected = null;
      _panel = _Panel.none;
    });
  }

  // ------------------------------------------------------------------ gestures

  void _onTap(Offset local) {
    final handle = _hitHandle(local);
    final selected = _selected;
    if (handle != null && selected != null) {
      if (handle == 'delete') {
        _delete();
      } else if (handle == 'duplicate') {
        setState(() {
          final copy = selected.copyEl()
            ..x = selected.x + 12
            ..y = selected.y + 12;
          _page.elements.add(copy);
          _selected = copy;
          _commit();
        });
      }
      return;
    }
    final hit = _hit(local);
    if (hit != null && hit == selected && hit is TText) {
      _editText(hit);
      return;
    }
    setState(() {
      _selected = hit;
      _panel = _Panel.none;
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _changed = false;
    _lastFocal = details.localFocalPoint;
    if (details.pointerCount >= 2) {
      _startZoomGesture(details.localFocalPoint);
      return;
    }
    final selected = _selected;
    if (selected != null && _hitHandle(details.localFocalPoint) == 'rotate') {
      _gesture = _Gesture.rotate;
      _startCopy = selected.copyEl();
      _startCenter = _toScreen(TplRenderer.center(selected));
      final v = details.localFocalPoint - _startCenter;
      _startDistance = math.max(1.0, v.distance);
      _startAngle = math.atan2(v.dy, v.dx);
      return;
    }
    final hit = _hit(details.localFocalPoint);
    if (hit != null) {
      _gesture = _Gesture.move;
      setState(() {
        _selected = hit;
        _panel = _Panel.none;
      });
      return;
    }
    _gesture = _Gesture.pan;
  }

  void _startZoomGesture(Offset focal) {
    _gesture = _Gesture.zoom;
    _startZoom = _zoom;
    _startPan = _pan;
    _startFocal = focal;
    _startScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2 && _gesture != _Gesture.zoom) {
      _startZoomGesture(details.localFocalPoint);
    }
    switch (_gesture) {
      case _Gesture.zoom:
        final zoom = (_startZoom * details.scale).clamp(0.6, 5.0);
        final scale = _startScale / _startZoom * zoom;
        final pagePoint = const Offset(tplPageW / 2, tplPageH / 2) + (_startFocal - _viewCenter - _startPan) / _startScale;
        setState(() {
          _zoom = zoom;
          _pan = details.localFocalPoint - _viewCenter - (pagePoint - const Offset(tplPageW / 2, tplPageH / 2)) * scale;
        });
      case _Gesture.pan:
        setState(() => _pan += details.localFocalPoint - _lastFocal);
      case _Gesture.move:
        final moving = _selected;
        if (moving == null) return;
        final delta = (details.localFocalPoint - _lastFocal) / _scale;
        setState(() {
          moving.x += delta.dx;
          moving.y += delta.dy;
          final center = TplRenderer.center(moving);
          _centred = (center.dx - tplPageW / 2).abs() < 2.5;
          if (_centred) moving.x += tplPageW / 2 - center.dx;
          _changed = true;
        });
      case _Gesture.rotate:
        final el = _selected;
        final start = _startCopy;
        if (el == null || start == null) return;
        final v = details.localFocalPoint - _startCenter;
        final factor = (v.distance / _startDistance).clamp(0.2, 8.0);
        final angle = (math.atan2(v.dy, v.dx) - _startAngle) * 180 / math.pi;
        final centerPage = _toPage(_startCenter);
        setState(() {
          if (el is TText && start is TText) {
            el.w = math.max(20.0, start.w * factor);
            el.size = (start.size * factor).clamp(4.0, 200.0);
          } else if (el is TImage && start is TImage) {
            el.w = math.max(8.0, start.w * factor);
            el.h = math.max(8.0, start.h * factor);
          }
          final size = TplRenderer.size(el);
          el.x = centerPage.dx - size.width / 2;
          el.y = centerPage.dy - size.height / 2;
          var rotation = start.rotation + angle;
          for (final snap in const [0.0, 90.0, 180.0, 270.0, 360.0, -90.0, -180.0, -270.0, -360.0]) {
            if ((rotation - snap).abs() < 3) rotation = snap;
          }
          el.rotation = rotation % 360;
          _changed = true;
        });
      case _Gesture.none:
        break;
    }
    _lastFocal = details.localFocalPoint;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_changed) {
      setState(_commit);
    }
    setState(() {
      _gesture = _Gesture.none;
      _centred = false;
      _startCopy = null;
      _changed = false;
    });
  }

  // ------------------------------------------------------------------ actions

  void _delete() {
    final el = _selected;
    if (el == null) return;
    setState(() {
      _page.elements.remove(el);
      _selected = null;
      _panel = _Panel.none;
      _commit();
    });
  }

  void _editSelected(void Function(TEl el) change) {
    final el = _selected;
    if (el == null) return;
    setState(() {
      change(el);
      _commit();
    });
  }

  Future<void> _editText(TText el) async {
    final value = await enterText(context, initial: el.text);
    if (value == null || !mounted) return;
    setState(() {
      if (value.trim().isEmpty) {
        _page.elements.remove(el);
        _selected = null;
      } else {
        el.text = value;
      }
      _commit();
    });
  }

  Future<void> _addText() async {
    final value = await enterText(context);
    if (value == null || value.trim().isEmpty || !mounted) return;
    const size = 18.0;
    final probe = TextPainter(
      text: TextSpan(text: value, style: tplTextStyle(tplDefaultFont, size: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = math.min(tplPageW - 40, math.max(40.0, probe.width + 6));
    probe.dispose();
    final center = _toPage(_viewCenter);
    final el = TText(value, x: center.dx - width / 2, y: center.dy - size, w: width, size: size);
    setState(() {
      _page.elements.add(el);
      _selected = el;
      _commit();
    });
  }

  /// Copies the picked picture into the app (so the template keeps working) → path.
  Future<String?> _pickPhoto() async {
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    try {
      final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'tpl_images'));
      await dir.create(recursive: true);
      final buf = await loadPixels(file.path, 1600);
      if (buf == null) return null;
      final target = p.join(dir.path, 'img_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(target).writeAsBytes(await jpegOf(buf, quality: 92), flush: true);
      await TplRenderer.loadPhoto(target);
      return target;
    } catch (_) {
      return null;
    }
  }

  double _photoAspect(String path) {
    final photo = TplRenderer.photos[path];
    if (photo == null || photo.height == 0) return 1;
    return photo.width / photo.height;
  }

  Future<void> _addImage() async {
    final path = await _pickPhoto();
    if (!mounted) return;
    if (path == null) {
      showToast(context, S.of(context).t('imageFailed'), warning: true);
      return;
    }
    final aspect = _photoAspect(path);
    const width = 240.0;
    final height = width / aspect;
    final center = _toPage(_viewCenter);
    final el = TImage(path: path, x: center.dx - width / 2, y: center.dy - height / 2, w: width, h: height);
    setState(() {
      _page.elements.add(el);
      _selected = el;
      _commit();
    });
  }

  Future<void> _replaceImage(TImage el) async {
    final path = await _pickPhoto();
    if (!mounted) return;
    if (path == null) {
      showToast(context, S.of(context).t('imageFailed'), warning: true);
      return;
    }
    final center = TplRenderer.center(el);
    setState(() {
      el.path = path;
      el.res = null;
      el.crop = const Rect.fromLTRB(0, 0, 1, 1);
      if (!el.circle) el.h = el.w / _photoAspect(path);
      el.x = center.dx - el.w / 2;
      el.y = center.dy - el.h / 2;
      _commit();
    });
  }

  Future<void> _crop(TImage el) async {
    // aspect of the whole source picture
    final path = el.path;
    final sourceAspect = path != null ? _photoAspect(path) : (el.w / math.max(0.01, el.crop.width)) / (el.h / math.max(0.01, el.crop.height));
    final rect = await Navigator.of(context).push<Rect>(
      MaterialPageRoute(builder: (_) => _CropPage(image: el, sourceAspect: sourceAspect)),
    );
    if (rect == null || !mounted) return;
    final center = TplRenderer.center(el);
    setState(() {
      el.crop = rect;
      if (!el.circle) el.h = el.w / (sourceAspect * rect.width / math.max(0.01, rect.height));
      el.x = center.dx - el.w / 2;
      el.y = center.dy - el.h / 2;
      _commit();
    });
  }

  // ------------------------------------------------------------------ saving

  Future<_Format?> _askFormat() async {
    final s = S.of(context);
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return null;
    var format = _Format.values[(prefs.getInt('tpl_last_format') ?? 1).clamp(0, 2)];
    // sheet_tpl_format.xml: SheetTitle, three 64dp bg_choice_row rows (title 16sp, primary when
    // chosen; description 13sp) with a primary radio, Save (52dp PillButton)
    final chosen = await showAppSheet<_Format>(
      context,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) {
          final nc = NC.of(sheet);
          Widget row(_Format value, String title, String subtitle) {
            final on = value == format;
            return Material(
              color: on ? nc.choiceSelectedBg : Colors.transparent,
              child: InkWell(
                onTap: () => setSheet(() => format = value),
                child: Container(
                  height: 64,
                  padding: const EdgeInsetsDirectional.only(start: 20, end: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: TextStyle(fontSize: 16, color: on ? nc.primary : nc.textPrimary)),
                            const SizedBox(height: 2),
                            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: nc.textSecondary)),
                          ],
                        ),
                      ),
                      NativeRadio(checked: on),
                    ],
                  ),
                ),
              ),
            );
          }

          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 20, bottom: 8),
                    child: Text(s.t('tplSelectFormat'), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: nc.textPrimary)),
                  ),
                  row(_Format.png, 'PNG', s.t('tplPngDesc')),
                  row(_Format.jpg, 'JPG', s.t('tplJpgDesc')),
                  row(_Format.pdf, 'PDF', s.t('tplPdfDesc')),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: SizedBox(
                      width: double.infinity,
                      child: NativePillButton(height: 52, label: s.t('tplSave'), onPressed: () => Navigator.pop(sheet, format)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (chosen != null) await prefs.setInt('tpl_last_format', chosen.index);
    return chosen;
  }

  Future<Uint8List> _export(_Format format) async {
    await TplRenderer.loadPhotos(_page);
    final page = _page.copyPage();
    if (format == _Format.pdf) {
      final image = await TplRenderer.render(page, tplPageW * 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = image.width;
      final height = image.height;
      image.dispose();
      if (data == null) throw StateError('render');
      final jpeg = await rgbaToJpeg(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), width, height, quality: 92);
      final doc = pw.Document();
      final memory = pw.MemoryImage(jpeg);
      doc.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(tplPageW, tplPageH),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.FullPage(ignoreMargins: true, child: pw.Image(memory, fit: pw.BoxFit.fill)),
        ),
      );
      return doc.save();
    }
    final image = await TplRenderer.render(page, tplPageW * 2);
    try {
      if (format == _Format.png) {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('render');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('render');
      return await rgbaToJpeg(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), image.width, image.height, quality: 92);
    } finally {
      image.dispose();
    }
  }

  /// Download: format → "Saving…" → saved to the app's files; returns true when saved.
  Future<bool> _download({bool leaving = false}) async {
    final format = await _askFormat();
    if (format == null || !mounted) return false;
    final s = S.of(context);
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _selected = null;
    });
    final pill = ProgressPill(context)..show(s.t('saving'));
    try {
      final bytes = await _export(format);
      final ext = switch (format) {
        _Format.png => 'png',
        _Format.jpg => 'jpg',
        _Format.pdf => 'pdf',
      };
      final entry = await scope.library.importBytes(bytes, name: '${defaultDocName()}.$ext', folder: 'create');
      pill.dismiss();
      if (!mounted) return false;
      setState(() => _busy = false);
      if (entry == null) throw StateError('save');
      _savedIndex = _index;
      await scope.ads.showInterstitial(unit: 2);
      if (!mounted) return true;
      if (!leaving) _showBanner(entry);
      return true;
    } catch (_) {
      pill.dismiss();
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, s.t('tplSaveFailed'), warning: true);
      }
      return false;
    }
  }

  Future<void> _share() async {
    final s = S.of(context);
    final scope = AppScope.of(context);
    setState(() => _selected = null);
    final pill = ProgressPill(context)..show(s.t('saving'));
    try {
      final bytes = await _export(_Format.pdf);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, '${defaultDocName()}.pdf'));
      await file.writeAsBytes(bytes, flush: true);
      pill.dismiss();
      scope.guard.arm(scope.settings);
      await Share.shareXFiles([XFile(file.path)]);
    } catch (_) {
      pill.dismiss();
      if (mounted) showToast(context, s.t('tplSaveFailed'), warning: true);
    }
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_panel != _Panel.none) {
      setState(() => _panel = _Panel.none);
      return;
    }
    if (_selected != null) {
      setState(() {
        _selected = null;
        _panel = _Panel.none;
      });
      return;
    }
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final s = S.of(context);
    // sheet_confirm.xml: "Quit now?" with Discard (gray) | Save
    final choice = await showAppSheet<String>(
      context,
      builder: (sheet) {
        final nc = NC.of(sheet);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.t('tplQuitTitle'), textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary)),
                const SizedBox(height: 10),
                Text(s.t('tplQuitMessage'), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(child: NativePillButton(gray: true, label: s.t('discard'), onPressed: () => Navigator.pop(sheet, 'discard'))),
                    const SizedBox(width: 16),
                    Expanded(child: NativePillButton(label: s.t('tplSave'), onPressed: () => Navigator.pop(sheet, 'save'))),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'discard') {
      Navigator.of(context).pop(false);
      return;
    }
    final saved = await _download(leaving: true);
    if (saved && mounted) Navigator.of(context).pop(true);
  }

  // ------------------------------------------------------------------ saved banner

  DocEntry? _bannerEntry;
  Timer? _bannerTimer;

  /// bannerSaved: "Saved successfully" with Open and ×, hidden after 5 s.
  void _showBanner(DocEntry entry) {
    _bannerTimer?.cancel();
    setState(() => _bannerEntry = entry);
    _bannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _bannerEntry = null);
    });
  }

  void _hideBanner() {
    _bannerTimer?.cancel();
    setState(() => _bannerEntry = null);
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _fontScroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final banner = _bannerEntry;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        // ← … undo redo · download share (44dp, 11dp padding)
        appBar: NativeTopBar(
          onBack: _back,
          titleWidget: const SizedBox.shrink(),
          actions: [
            NativeIconButton(
              ND.icUndo,
              padding: 11,
              tint: nc.textPrimary,
              tooltip: s.t('undo'),
              onPressed: _index > 0 && !_busy ? () => _restore(_index - 1) : null,
            ),
            NativeIconButton(
              ND.icRedo,
              padding: 11,
              tint: nc.textPrimary,
              tooltip: s.t('redo'),
              onPressed: _index < _history.length - 1 && !_busy ? () => _restore(_index + 1) : null,
            ),
            const SizedBox(width: 28),
            NativeIconButton(ND.icDownload, padding: 11, tint: nc.textPrimary, tooltip: s.t('tplDownload'), onPressed: _busy ? null : _download),
            NativeIconButton(ND.icShare, padding: 11, tint: nc.textPrimary, tooltip: s.t('share'), onPressed: _busy ? null : _share),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: nc.surfaceVariant,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final base = math.min(constraints.maxWidth / tplPageW, constraints.maxHeight / tplPageH) * 0.92;
                          _scale = base * _zoom;
                          _viewCenter = Offset(constraints.maxWidth / 2, constraints.maxHeight / 2);
                          final selected = _selected;
                          final handles = selected == null ? const <String, Offset>{} : _handles(selected);
                          final bubble = handles['bubble'];
                          final turn = handles['rotate'];
                          return ClipRect(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) => _onTap(details.localPosition),
                              onScaleStart: _onScaleStart,
                              onScaleUpdate: _onScaleUpdate,
                              onScaleEnd: _onScaleEnd,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: _EditorPainter(
                                        page: _page,
                                        scale: _scale,
                                        origin: _toScreen(Offset.zero),
                                        selected: _selected,
                                        centred: _centred,
                                      ),
                                    ),
                                  ),
                                  // duplicate + delete bubble (72 x 34dp, white, 8dp) and the turn handle
                                  if (bubble != null)
                                    Positioned(
                                      left: bubble.dx - 36,
                                      top: bubble.dy - 17,
                                      child: IgnorePointer(
                                        child: Container(
                                          width: 72,
                                          height: 34,
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(8),
                                            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
                                          ),
                                          child: const Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                            children: [
                                              NativeIcon(ND.icQCopy, size: 20, tint: Color(0xFF1B1F2A)),
                                              NativeIcon(ND.icDelete, size: 20, tint: Color(0xFF1B1F2A)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (turn != null)
                                    Positioned(
                                      left: turn.dx - 14,
                                      top: turn.dy - 14,
                                      child: const IgnorePointer(child: NativeIcon(ND.tplHandleRotate, size: 28)),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (banner != null)
                      Positioned(
                        left: 12,
                        right: 12,
                        top: 12,
                        child: Material(
                          color: nc.surface,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            height: 56,
                            padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
                            child: Row(
                              children: [
                                const NativeIcon(ND.icCheckCircle, size: 22),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    s.t('savedSuccessfully'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary),
                                  ),
                                ),
                                InkWell(
                                  onTap: () {
                                    _hideBanner();
                                    openEntry(context, banner);
                                  },
                                  child: Container(
                                    height: 40,
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    alignment: Alignment.center,
                                    child: Text(s.t('open'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.primary)),
                                  ),
                                ),
                                NativeIconButton(ND.icClose, size: 40, padding: 11, tint: nc.textSecondary, tooltip: s.t('tplClose'), onPressed: _hideBanner),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Material(
              color: nc.surface,
              elevation: 4,
              child: SafeArea(
                top: false,
                child: _panel != _Panel.none && _selected is TText ? _panelView(s, nc) : _toolbar(s, nc),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// barMain / barText / barImage: 64dp, 22dp icon + 11sp label (text_primary), × with 20dp padding.
  Widget _toolbar(S s, NC nc) {
    Widget tool(NDrawable icon, String label, VoidCallback onTap) => Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkResponse(
              onTap: _busy ? null : onTap,
              radius: 36,
              child: SizedBox(
                height: 64,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    NativeIcon(icon, size: 22, tint: nc.textPrimary),
                    const SizedBox(height: 3),
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: nc.textPrimary)),
                  ],
                ),
              ),
            ),
          ),
        );
    Widget close(VoidCallback onTap) => Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkResponse(
              onTap: onTap,
              radius: 32,
              child: SizedBox(
                height: 64,
                child: Center(child: NativeIcon(ND.icClose, size: 24, tint: nc.textPrimary)),
              ),
            ),
          ),
        );
    void openPanel(_Panel panel) => setState(() => _panel = panel);
    final selected = _selected;
    List<Widget> tools;
    if (selected is TText) {
      tools = [
        tool(ND.icTplFonts, s.t('tplFonts'), () => openPanel(_Panel.fonts)),
        tool(ND.icTplSize, s.t('sizeLabel'), () => openPanel(_Panel.size)),
        tool(ND.icTplColor, s.t('color'), () => openPanel(_Panel.size)),
        tool(ND.icTplFormat, s.t('tplFormat'), () => openPanel(_Panel.format)),
        tool(ND.icDelete, s.t('delete'), _delete),
        close(() => setState(() {
              _selected = null;
              _panel = _Panel.none;
            })),
      ];
    } else if (selected is TImage) {
      tools = [
        tool(ND.icTplReplace, s.t('tplReplace'), () => _replaceImage(selected)),
        tool(ND.icCrop, s.t('crop'), () => _crop(selected)),
        tool(ND.icTplFlipH, s.t('tplFlipH'), () => _editSelected((el) {
              final image = el as TImage;
              image.flipH = !image.flipH;
            })),
        tool(ND.icTplFlipV, s.t('tplFlipV'), () => _editSelected((el) {
              final image = el as TImage;
              image.flipV = !image.flipV;
            })),
        tool(ND.icDelete, s.t('delete'), _delete),
        close(() => setState(() => _selected = null)),
      ];
    } else {
      tools = [
        tool(ND.icEtAddText, s.t('addText'), _addText),
        tool(ND.icTplAddImage, s.t('addImage'), _addImage),
      ];
    }
    return Row(children: tools);
  }

  /// Panel header: 52dp, title 18sp bold, × (44dp, 13dp padding, text_secondary).
  Widget _panelHeader(String title, NC nc) {
    return Container(
      height: 52,
      padding: const EdgeInsetsDirectional.only(start: 20, end: 6),
      child: Row(
        children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary))),
          NativeIconButton(
            ND.icClose,
            padding: 13,
            tint: nc.textSecondary,
            tooltip: S.of(context).t('tplClose'),
            onPressed: () => setState(() => _panel = _Panel.none),
          ),
        ],
      ),
    );
  }

  Widget _panelView(S s, NC nc) {
    final el = _selected;
    if (el is! TText || _panel == _Panel.none) return const SizedBox();
    switch (_panel) {
      case _Panel.fonts:
        // panelFonts: 320dp, "Current font" + the current one, "Fonts" + every font (44dp, 16sp,
        // primary when chosen), A–Z index on the right
        Widget label(String text) => Padding(
              padding: const EdgeInsetsDirectional.only(start: 20, top: 10, bottom: 4),
              child: Text(text, style: TextStyle(fontSize: 13, color: nc.textSecondary)),
            );
        Widget fontRow(String name) {
          final on = el.font == name;
          return InkWell(
            onTap: () => _editSelected((target) => (target as TText).font = name),
            child: Container(
              height: 44,
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsetsDirectional.only(start: 20, end: 12),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tplTextStyle(name, size: 16, color: (on ? nc.primary : nc.textPrimary).toARGB32()),
              ),
            ),
          );
        }

        return SizedBox(
          height: 320,
          child: Column(
            children: [
              _panelHeader(s.t('tplFonts'), nc),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: ListView(
                        controller: _fontScroll,
                        children: [
                          label(s.t('tplCurrentFont')),
                          fontRow(el.font),
                          label(s.t('tplFonts')),
                          for (final font in tplFonts) fontRow(font.name),
                        ],
                      ),
                    ),
                    Container(
                      width: 24,
                      margin: const EdgeInsetsDirectional.only(end: 6),
                      child: Column(
                        children: [
                          for (var c = 65; c <= 90; c++)
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _jumpToLetter(String.fromCharCode(c)),
                                child: Center(
                                  child: Text(String.fromCharCode(c), style: TextStyle(fontSize: 9, color: nc.textSecondary)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      case _Panel.size:
        // panelSize: SeekBar (6–128, primary) with the value pill, then the colour dots
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _panelHeader(s.t('tplSizeColor'), nc),
              Container(
                height: 48,
                padding: const EdgeInsetsDirectional.only(start: 6, end: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: nc.primary,
                          thumbColor: nc.primary,
                          inactiveTrackColor: nc.primary.withValues(alpha: 0.24),
                          overlayColor: nc.primary.withValues(alpha: 0.12),
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                        ),
                        child: Slider(
                          value: el.size.clamp(6.0, 128.0),
                          min: 6,
                          max: 128,
                          onChanged: (value) => setState(() {
                            final center = TplRenderer.center(el);
                            el.size = value.roundToDouble();
                            el.x = center.dx - el.w / 2;
                          }),
                          onChangeEnd: (_) => setState(_commit),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 30,
                      constraints: const BoxConstraints(minWidth: 48),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: nc.surfaceVariant, borderRadius: BorderRadius.circular(6)),
                      child: Text('${el.size.round()}', style: TextStyle(fontSize: 14, color: nc.textPrimary)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final color in _tplColors)
                      GestureDetector(
                        onTap: () => _editSelected((target) => (target as TText).color = color),
                        child: Container(
                          width: 44,
                          height: 44,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          alignment: Alignment.center,
                          decoration: el.color == color
                              ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: nc.primary, width: 2))
                              : null,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Color(color),
                              shape: BoxShape.circle,
                              border: color == 0xFFFFFFFF ? Border.all(color: const Color(0xFFD5DAE2)) : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      case _Panel.format:
        // panelFormat: 44dp bg_tpl_toggle buttons (choice_selected_bg when on, else surface_variant)
        Widget toggle(NDrawable? icon, IconData fallback, String tip, bool on, void Function(TText t) change) => Expanded(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: Tooltip(
                  message: tip,
                  child: Material(
                    color: on ? nc.choiceSelectedBg : nc.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _editSelected((target) => change(target as TText)),
                      child: SizedBox(
                        height: 44,
                        child: Center(
                          child: icon == null
                              ? Icon(fallback, size: 22, color: on ? nc.primary : nc.textPrimary)
                              : NativeIcon(icon, size: 22, tint: on ? nc.primary : nc.textPrimary),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _panelHeader(s.t('tplFormat'), nc),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                child: Row(
                  children: [
                    toggle(ND.icTplBold, Icons.format_bold_rounded, s.t('tplBold'), el.bold, (t) => t.bold = !t.bold),
                    toggle(ND.icTplItalic, Icons.format_italic_rounded, s.t('tplItalic'), el.italic, (t) => t.italic = !t.italic),
                    toggle(ND.icTplUnderline, Icons.format_underlined_rounded, s.t('underline'), el.underline, (t) => t.underline = !t.underline),
                    toggle(ND.icTplStrike, Icons.format_strikethrough_rounded, s.t('strike'), el.strike, (t) => t.strike = !t.strike),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                child: Row(
                  children: [
                    toggle(ND.icTplBullets, Icons.format_list_bulleted_rounded, s.t('tplBullets'), el.list == 1, (t) => t.list = t.list == 1 ? 0 : 1),
                    toggle(ND.icTplNumbers, Icons.format_list_numbered_rounded, s.t('tplNumbers'), el.list == 2, (t) => t.list = t.list == 2 ? 0 : 2),
                    const Spacer(flex: 2),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // alignment (kept from the Flutter app)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                child: Row(
                  children: [
                    toggle(null, Icons.format_align_left_rounded, s.t('tplAlignLeft'), el.align == 0, (t) => t.align = 0),
                    toggle(null, Icons.format_align_center_rounded, s.t('tplAlignCenter'), el.align == 1, (t) => t.align = 1),
                    toggle(null, Icons.format_align_right_rounded, s.t('tplAlignRight'), el.align == 2, (t) => t.align = 2),
                    const Spacer(),
                  ],
                ),
              ),
            ],
          ),
        );
      case _Panel.none:
        return const SizedBox();
    }
  }

  final ScrollController _fontScroll = ScrollController();

  /// A–Z index: the first font starting with [letter] or later (row 44dp; two labels and the
  /// current font come first).
  void _jumpToLetter(String letter) {
    if (!_fontScroll.hasClients) return;
    var index = tplFonts.indexWhere((font) => font.name.toUpperCase().compareTo(letter) >= 0);
    if (index < 0) index = tplFonts.length - 1;
    const labelHeight = 10 + 4 + 18.0;
    final offset = labelHeight * 2 + 44 + index * 44.0;
    _fontScroll.jumpTo(offset.clamp(0.0, _fontScroll.position.maxScrollExtent));
  }
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.page,
    required this.scale,
    required this.origin,
    required this.selected,
    required this.centred,
  });

  final TPage page;
  final double scale;
  final Offset origin;
  final TEl? selected;
  final bool centred;

  /// TemplateCanvasView: selection box #1E6FE6 1.4dp with 4dp padding, red #FF2D2D centre guide.
  static const _blue = Color(0xFF1E6FE6);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, tplPageW, tplPageH).shift(Offset(2 / scale, 3 / scale)),
      Paint()..color = const Color(0x22000000),
    );
    canvas.save();
    canvas.clipRect(const Rect.fromLTWH(0, 0, tplPageW, tplPageH));
    TplRenderer.paint(canvas, page);
    canvas.restore();
    final el = selected;
    if (centred && el != null) {
      canvas.drawLine(
        const Offset(tplPageW / 2, 0),
        const Offset(tplPageW / 2, tplPageH),
        Paint()
          ..color = const Color(0xFFFF2D2D)
          ..strokeWidth = 1.2 / scale,
      );
    }
    if (el != null) {
      final box = TplRenderer.size(el);
      final center = TplRenderer.center(el);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(el.rotation * math.pi / 180);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: box.width, height: box.height).inflate(4 / scale),
        Paint()
          ..color = _blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 / scale,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EditorPainter oldDelegate) => true;
}

/// Crop for a template picture: drag the four corners of the frame; ✓ returns the visible part
/// as fractions of the whole picture.
class _CropPage extends StatefulWidget {
  const _CropPage({required this.image, required this.sourceAspect});

  final TImage image;
  final double sourceAspect;

  @override
  State<_CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<_CropPage> {
  late Rect _crop = widget.image.crop;
  int _corner = -1;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // dialog_tpl_crop.xml: #F2000000, × | "Crop" | ✓ (48dp, white), the frame, "Reset" pill
    return Scaffold(
      backgroundColor: const Color(0xF2000000),
      appBar: AppBar(
        toolbarHeight: 56,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 4),
            NativeIconButton(ND.icClose, size: 48, padding: 12, tint: Colors.white, tooltip: s.t('cancel'), onPressed: () => Navigator.pop(context)),
            Expanded(
              child: Text(
                s.t('crop'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            NativeIconButton(ND.icCheck, size: 48, padding: 12, tint: Colors.white, tooltip: s.t('ok'), onPressed: () => Navigator.pop(context, _crop)),
            const SizedBox(width: 4),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 20),
          child: Center(
            heightFactor: 1,
            child: Material(
              color: const Color(0xFF3A3D44),
              borderRadius: BorderRadius.circular(15),
              child: InkWell(
                borderRadius: BorderRadius.circular(15),
                onTap: () => setState(() => _crop = const Rect.fromLTRB(0, 0, 1, 1)),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  child: Text(s.t('tplReset'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ),
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final area = Rect.fromLTWH(24, 24, constraints.maxWidth - 48, constraints.maxHeight - 48);
          var w = area.width;
          var h = w / widget.sourceAspect;
          if (h > area.height) {
            h = area.height;
            w = h * widget.sourceAspect;
          }
          final rect = Rect.fromCenter(center: area.center, width: w, height: h);
          final frame = Rect.fromLTRB(
            rect.left + _crop.left * rect.width,
            rect.top + _crop.top * rect.height,
            rect.left + _crop.right * rect.width,
            rect.top + _crop.bottom * rect.height,
          );
          final corners = [frame.topLeft, frame.topRight, frame.bottomRight, frame.bottomLeft];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              _corner = -1;
              var best = 40.0;
              for (var i = 0; i < 4; i++) {
                final d = (corners[i] - details.localPosition).distance;
                if (d < best) {
                  best = d;
                  _corner = i;
                }
              }
              if (_corner < 0 && frame.contains(details.localPosition)) _corner = 4;
            },
            onPanUpdate: (details) {
              if (_corner < 0) return;
              final dx = details.delta.dx / rect.width;
              final dy = details.delta.dy / rect.height;
              var l = _crop.left;
              var t = _crop.top;
              var r = _crop.right;
              var b = _crop.bottom;
              const minimum = 0.08;
              switch (_corner) {
                case 0:
                  l = (l + dx).clamp(0.0, r - minimum);
                  t = (t + dy).clamp(0.0, b - minimum);
                case 1:
                  r = (r + dx).clamp(l + minimum, 1.0);
                  t = (t + dy).clamp(0.0, b - minimum);
                case 2:
                  r = (r + dx).clamp(l + minimum, 1.0);
                  b = (b + dy).clamp(t + minimum, 1.0);
                case 3:
                  l = (l + dx).clamp(0.0, r - minimum);
                  b = (b + dy).clamp(t + minimum, 1.0);
                default:
                  final cw = r - l;
                  final ch = b - t;
                  l = (l + dx).clamp(0.0, 1.0 - cw);
                  t = (t + dy).clamp(0.0, 1.0 - ch);
                  r = l + cw;
                  b = t + ch;
              }
              setState(() => _crop = Rect.fromLTRB(l, t, r, b));
            },
            child: CustomPaint(
              size: Size.infinite,
              painter: _CropFramePainter(image: widget.image, rect: rect, frame: frame),
            ),
          );
        },
      ),
    );
  }
}

class _CropFramePainter extends CustomPainter {
  _CropFramePainter({required this.image, required this.rect, required this.frame});

  final TImage image;
  final Rect rect;
  final Rect frame;

  /// TplCropDialog: #99000000 outside, white 2dp frame, thirds grid #66FFFFFF, 18dp white corner
  /// brackets (4dp, round caps).
  @override
  void paint(Canvas canvas, Size size) {
    final path = image.path;
    final photo = path == null ? null : TplRenderer.photos[path];
    if (photo != null) {
      canvas.drawImageRect(photo, Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble()), rect, Paint()..filterQuality = FilterQuality.medium);
    } else {
      canvas.drawRect(rect, Paint()..color = Colors.white);
      canvas.save();
      canvas.clipRect(rect);
      paintArt(canvas, image.res ?? '', rect);
      canvas.restore();
    }
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect)
        ..addRect(frame),
      Paint()..color = const Color(0x99000000),
    );
    final grid = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), grid);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), grid);
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final corner = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 18.0;
    final r = frame;
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(l, 0), corner);
    canvas.drawLine(r.topLeft, r.topLeft + const Offset(0, l), corner);
    canvas.drawLine(r.topRight, r.topRight + const Offset(-l, 0), corner);
    canvas.drawLine(r.topRight, r.topRight + const Offset(0, l), corner);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(l, 0), corner);
    canvas.drawLine(r.bottomLeft, r.bottomLeft + const Offset(0, -l), corner);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(-l, 0), corner);
    canvas.drawLine(r.bottomRight, r.bottomRight + const Offset(0, -l), corner);
  }

  @override
  bool shouldRepaint(covariant _CropFramePainter oldDelegate) => true;
}
