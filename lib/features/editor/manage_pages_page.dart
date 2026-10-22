import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/doc_scanner.dart';
import '../../services/image_ops.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/chrome.dart';
import '../create/blank_pages_page.dart';
import '../create/pdf_thumbs.dart';
import '../create/scan_flow.dart';
import '../create/tool_widgets.dart';
import '../files/file_actions.dart';
import '../reader/reader_page.dart';

/// One page of the result: page [index] (0-based) of the PDF at [src], turned by [rotate]
/// degrees. Saving copies these real pages, so text stays text.
class _Sheet {
  _Sheet({required this.src, required this.index, required this.width, required this.height, this.rotate = 0, this.selected = false});

  final String src;
  final int index;
  double width;
  double height;
  int rotate;
  bool selected;
  final int id = _nextId++;

  static int _nextId = 1;

  SourcePage get part => SourcePage(src, index, rotate: rotate);

  _Sheet copy() => _Sheet(src: src, index: index, width: width, height: height, rotate: rotate, selected: selected);
}

/// Manage pages: the pages in a 3-column grid (long press and drag to reorder, tap to preview),
/// select mode with Select all, Rotate, Duplicate, Move to start / end, Insert (blank pages with
/// page setup, or pictures from the camera / gallery), Extract, Delete, undo / redo; Done saves.
class ManagePagesPage extends StatefulWidget {
  const ManagePagesPage({super.key, required this.entry});

  final DocEntry entry;

  @override
  State<ManagePagesPage> createState() => _ManagePagesPageState();
}

class _ManagePagesPageState extends State<ManagePagesPage> {
  List<_Sheet> _pages = [];
  final List<List<_Sheet>> _undo = [];
  final List<List<_Sheet>> _redo = [];
  final Map<String, PdfThumbs> _thumbs = {};
  bool _loading = true;
  bool _selecting = false;
  bool _busy = false;
  bool _changed = false;
  int _version = 0;
  String _path = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_path.isNotEmpty) return;
    _path = AppScope.of(context).library.fileOf(widget.entry).path;
    _load();
  }

  @override
  void dispose() {
    for (final thumbs in _thumbs.values) {
      thumbs.close();
    }
    super.dispose();
  }

  PdfThumbs _thumbsFor(String src) => _thumbs.putIfAbsent(src, () => PdfThumbs(src, width: 200));

  Future<List<(double, double)>> _sizes(String path) async {
    final out = <(double, double)>[];
    final document = await PdfDocument.openFile(path);
    try {
      for (var i = 1; i <= document.pagesCount; i++) {
        final page = await document.getPage(i);
        out.add((page.width, page.height));
        await page.close();
      }
    } finally {
      await document.close();
    }
    return out;
  }

  Future<void> _load() async {
    try {
      final sizes = await _sizes(_path);
      if (!mounted) return;
      setState(() {
        _pages = [for (var i = 0; i < sizes.length; i++) _Sheet(src: _path, index: i, width: sizes[i].$1, height: sizes[i].$2)];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, S.of(context).t('pdfProtected'), warning: true);
    }
  }

  List<_Sheet> get _selected => _pages.where((sheet) => sheet.selected).toList();

  void _checkpoint() {
    _undo.add([for (final sheet in _pages) sheet.copy()]);
    if (_undo.length > 40) _undo.removeAt(0);
    _redo.clear();
    _changed = true;
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add([for (final sheet in _pages) sheet.copy()]);
      _pages = _undo.removeLast();
      _version++;
    });
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add([for (final sheet in _pages) sheet.copy()]);
      _pages = _redo.removeLast();
      _version++;
    });
  }

  bool _needSelection() {
    if (_selected.isNotEmpty) return true;
    setState(() => _selecting = true);
    showToast(context, S.of(context).t('selectPagesFirst'));
    return false;
  }

  void _rotate() {
    if (!_needSelection()) return;
    setState(() {
      _checkpoint();
      for (final sheet in _selected) {
        sheet.rotate = (sheet.rotate + 90) % 360;
        final w = sheet.width;
        sheet.width = sheet.height;
        sheet.height = w;
      }
      _version++;
    });
  }

  void _duplicate() {
    if (!_needSelection()) return;
    setState(() {
      _checkpoint();
      final next = <_Sheet>[];
      for (final sheet in _pages) {
        next.add(sheet);
        if (sheet.selected) next.add(sheet.copy()..selected = false);
      }
      _pages = next;
      _version++;
    });
  }

  void _moveTo({required bool start}) {
    if (!_needSelection()) return;
    setState(() {
      _checkpoint();
      final chosen = _selected;
      final rest = _pages.where((sheet) => !sheet.selected).toList();
      _pages = start ? [...chosen, ...rest] : [...rest, ...chosen];
      _version++;
    });
  }

  Future<void> _delete() async {
    if (!_needSelection()) return;
    final s = S.of(context);
    final count = _selected.length;
    if (count >= _pages.length) {
      showToast(context, s.t('pdfNeedsPage'));
      return;
    }
    final ok = await confirmSheet(context, title: s.t('deleteConfirm'), message: s.t('deletePagesMessage', {'count': '$count'}), ok: s.t('delete'));
    if (!ok || !mounted) return;
    setState(() {
      _checkpoint();
      _pages.removeWhere((sheet) => sheet.selected);
      _version++;
    });
    showToast(context, s.t('deletedSuccessfully'));
  }

  int get _insertAt {
    final selected = _selected;
    if (selected.isEmpty) return _pages.length;
    return _pages.indexOf(selected.last) + 1;
  }

  final GlobalKey _insertKey = GlobalKey();

  /// popup_insert.xml above the Insert tool: 170dp bg_popup (surface, 10dp), "Blank pages" and
  /// "Images" rows (44dp, 20dp icon, 14sp).
  Future<void> _insert() async {
    final s = S.of(context);
    final nc = NC.of(context);
    final box = _insertKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    RelativeRect position = const RelativeRect.fromLTRB(8, 0, 0, 0);
    if (box != null && overlay != null) {
      final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
      const menuHeight = 44.0 * 2 + 8;
      final top = topLeft.dy - menuHeight - 4;
      position = RelativeRect.fromLTRB(topLeft.dx + 8, top, overlay.size.width - topLeft.dx - 8 - 170, overlay.size.height - top - menuHeight);
    }
    PopupMenuItem<String> option(String value, NDrawable icon, String label) => PopupMenuItem<String>(
          value: value,
          height: 44,
          padding: const EdgeInsets.only(left: 14, right: 8),
          child: Row(
            children: [
              NativeIcon(icon, size: 20, tint: nc.textPrimary),
              const SizedBox(width: 10),
              Flexible(child: Text(label, style: TextStyle(fontSize: 14, color: nc.textPrimary))),
            ],
          ),
        );
    final choice = await showMenu<String>(
      context: context,
      position: position,
      color: nc.surface,
      elevation: 8,
      constraints: const BoxConstraints(minWidth: 170, maxWidth: 170),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        option('blank', ND.icPages, s.t('blankPages')),
        option('images', ND.icImageLine, s.t('images')),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'blank') {
      await _insertBlank();
    } else {
      await _insertImages();
    }
  }

  Future<void> _insertBlank() async {
    final at = _insertAt;
    final before = at > 0 && at - 1 < _pages.length ? _pages[at - 1] : (_pages.isNotEmpty ? _pages.first : null);
    final spec = await Navigator.of(context).push<BlankSpec>(
      MaterialPageRoute(builder: (_) => BlankPagesPage(previousWidth: before?.width, previousHeight: before?.height)),
    );
    if (spec == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await blankPdf(pages: spec.count, style: spec.style, format: spec.format, background: PdfColor.fromInt(spec.color));
      final path = await tempPdf(bytes);
      if (!mounted) return;
      setState(() {
        _checkpoint();
        _pages.insertAll(at, [for (var i = 0; i < spec.count; i++) _Sheet(src: path, index: i, width: spec.width, height: spec.height)]);
        _version++;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _insertImages() async {
    final at = _insertAt;
    final source = await chooseScanSource(context);
    if (source == null || !mounted) return;
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    List<String> paths;
    if (source == ScanSource.camera) {
      final shots = await takeDocumentPhotos();
      paths = shots?.paths ?? const [];
    } else {
      paths = await pickGalleryImages();
    }
    if (paths.isEmpty || !mounted) return;
    final s = S.of(context);
    setState(() => _busy = true);
    final pill = ProgressPill(context)..show(s.t('processingProgress', {'percent': '0'}));
    try {
      final images = <Uint8List>[];
      for (var i = 0; i < paths.length; i++) {
        // the picture as an upright JPEG (also turns HEIC / PNG into something a PDF can hold)
        final buf = await loadPixels(paths[i], 2200);
        if (buf != null) images.add(await jpegOf(buf));
        pill.show(s.t('processingProgress', {'percent': '${((i + 1) * 70 / paths.length).round()}'}));
      }
      if (images.isEmpty) throw StateError('images');
      final bytes = await imagesToPdf(images, fitPage: true);
      final path = await tempPdf(bytes);
      final sizes = await _sizes(path);
      pill.dismiss();
      if (!mounted) return;
      setState(() {
        _checkpoint();
        _pages.insertAll(at, [for (var i = 0; i < sizes.length; i++) _Sheet(src: path, index: i, width: sizes[i].$1, height: sizes[i].$2)]);
        _version++;
      });
    } catch (_) {
      pill.dismiss();
      if (mounted) showToast(context, s.t('convertFailed'), warning: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _assemble(List<_Sheet> sheets) async {
    final real = await assemblePdf([for (final sheet in sheets) sheet.part]);
    if (real != null) return real;
    // fallback: the pages as pictures
    final pieces = <PdfPiece>[];
    final open = <String, PdfDocument>{};
    try {
      for (final sheet in sheets) {
        final document = open[sheet.src] ??= await PdfDocument.openFile(sheet.src);
        final page = await document.getPage(sheet.index + 1);
        final image = await page.render(width: page.width * 1.5, height: page.height * 1.5, format: PdfPageImageFormat.jpeg, backgroundColor: '#FFFFFF', quality: 88);
        await page.close();
        if (image == null) continue;
        var bytes = image.bytes;
        if (sheet.rotate != 0) bytes = await rotateImageBytes(bytes, quarterTurns: sheet.rotate ~/ 90);
        pieces.add(PdfPiece(image: bytes, pageFormat: PdfPageFormat(sheet.width, sheet.height)));
      }
    } finally {
      for (final document in open.values) {
        await document.close();
      }
    }
    return rebuildPdf(pieces);
  }

  Future<void> _extract() async {
    if (!_needSelection()) return;
    final s = S.of(context);
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    final pill = ProgressPill(context)..show(s.t('extracting'));
    try {
      final bytes = await _assemble(_selected);
      final entry = await scope.library.importBytes(bytes, name: '${stampName('Extract')}.pdf', folder: 'split');
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      if (entry == null) throw StateError('save');
      // sheet_extracted.xml: "Extracted successfully" 19sp bold with ×, "Saved as …", View | Share
      await showAppSheet<void>(
        context,
        builder: (sheet) {
          final nc = NC.of(sheet);
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 12, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(s.t('extractedSuccessfully'), style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: nc.textPrimary)),
                      ),
                      NativeIconButton(ND.icClose, size: 40, padding: 10, tint: nc.textSecondary, tooltip: s.t('cancel'), onPressed: () => Navigator.pop(sheet)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Text(s.t('savedAs', {'name': entry.name}), style: TextStyle(fontSize: 15, color: nc.textPrimary)),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: Material(
                              color: nc.surface,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: nc.primary, width: 1.4)),
                              child: InkWell(
                                customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                                onTap: () {
                                  Navigator.pop(sheet);
                                  openEntry(context, entry);
                                },
                                child: Center(
                                  child: Text(s.t('view'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: nc.primary)),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: NativePillButton(
                            height: 44,
                            label: s.t('share'),
                            onPressed: () {
                              Navigator.pop(sheet);
                              shareEntry(context, entry);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, s.t('saveFailed'), warning: true);
    }
  }

  Future<void> _done() async {
    if (_busy || _pages.isEmpty) return;
    final s = S.of(context);
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    final pill = ProgressPill(context)..show(s.t('saving'));
    try {
      final bytes = await _assemble(_pages);
      final file = File(_path);
      await file.writeAsBytes(bytes, flush: true);
      await scope.library.scan();
      pill.dismiss();
      if (!mounted) return;
      showToast(context, s.t('savedSuccessfully'));
      await scope.ads.showInterstitial();
      if (!mounted) return;
      final updated = scope.library.byPath(_path) ?? widget.entry;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ReaderPage(entry: updated)));
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, s.t('saveFailed'), warning: true);
    }
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_selecting) {
      setState(() {
        _selecting = false;
        for (final sheet in _pages) {
          sheet.selected = false;
        }
      });
      return;
    }
    if (!_changed) {
      Navigator.of(context).pop();
      return;
    }
    final s = S.of(context);
    final discard = await confirmSheet(context, title: s.t('discardTitle'), message: s.t('discardMessage'), ok: s.t('discard'));
    if (discard && mounted) Navigator.of(context).pop();
  }

  Future<void> _preview(int start) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _PagePreview(pages: _pages, start: start)),
    );
    // the preview's checkbox selects pages
    if (mounted) setState(() {});
  }

  static const _hintKey = 'organizer_hint_closed';
  bool _hintClosed = true;
  bool _hintRead = false;

  void _readHint() {
    if (_hintRead) return;
    _hintRead = true;
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _hintClosed = prefs.getBool(_hintKey) ?? false);
    });
  }

  Future<void> _closeHint() async {
    setState(() => _hintClosed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hintKey, true);
  }

  void _toggleAll() {
    setState(() {
      final all = _pages.isNotEmpty && _selected.length == _pages.length;
      for (final sheet in _pages) {
        sheet.selected = !all;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _readHint();
    final s = S.of(context);
    final nc = NC.of(context);
    final selectedCount = _selected.length;
    final history = _undo.isNotEmpty || _redo.isNotEmpty;
    final canDone = !_busy && !_loading && _pages.isNotEmpty && _changed;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        // activity_page_organizer.xml: ← … undo redo … [Done]
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
              NativeIconButton(ND.icBack, tint: nc.textPrimary, onPressed: _back),
              const Spacer(),
              Visibility(
                visible: history,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NativeIconButton(
                      ND.icUndo,
                      tint: _undo.isEmpty || _busy ? const Color(0xFFC3C8D0) : nc.textPrimary,
                      tooltip: s.t('undo'),
                      onPressed: _undo.isEmpty || _busy ? null : _undoStep,
                    ),
                    NativeIconButton(
                      ND.icRedo,
                      tint: _redo.isEmpty || _busy ? const Color(0xFFC3C8D0) : nc.textPrimary,
                      tooltip: s.t('redo'),
                      onPressed: _redo.isEmpty || _busy ? null : _redoStep,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Material(
                color: canDone ? const Color(0xFF111317) : const Color(0xFFD9DCE1),
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: canDone ? _done : null,
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    alignment: Alignment.center,
                    child: Text(s.t('done'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
        body: _loading
            ? Center(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: nc.primary)))
            : Column(
                children: [
                  if (!_hintClosed)
                    Container(
                      height: 40,
                      color: nc.surfaceVariant,
                      padding: const EdgeInsetsDirectional.only(start: 16, end: 6),
                      child: Row(
                        children: [
                          NativeIcon(ND.icReorder, size: 18, tint: nc.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(s.t('dragHint'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: nc.textPrimary)),
                          ),
                          NativeIconButton(ND.icClose, size: 36, padding: 11, tint: nc.textSecondary, tooltip: s.t('cancel'), onPressed: _closeHint),
                        ],
                      ),
                    ),
                  // "N selected" + select all
                  Container(
                    height: 44,
                    padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.t('selected', {'count': '$selectedCount'}),
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary),
                          ),
                        ),
                        NativeIconButton(ND.icSelectAll, size: 40, padding: 9, tint: nc.textPrimary, tooltip: s.t('selectAll'), onPressed: _toggleAll),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 2 columns (8dp list padding, 6dp item padding), 3:4 pages
                        final cell = (constraints.maxWidth - 16) / 2;
                        final page = cell - 12 - 4;
                        return ReorderGrid(
                          crossAxisCount: 2,
                          childAspectRatio: cell / (page * 4 / 3 + 16),
                          spacing: 0,
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                          itemCount: _pages.length,
                          itemKey: (index) => ValueKey('sheet_${_pages[index].id}_$_version'),
                          onReorder: (from, to) => setState(() {
                            _checkpoint();
                            _pages.insert(to, _pages.removeAt(from));
                            _version++;
                          }),
                          itemBuilder: (context, index) => _tile(index, nc),
                        );
                      },
                    ),
                  ),
                  _actions(s, nc, selectedCount),
                ],
              ),
      ),
    );
  }

  /// item_page_thumb.xml: bg_thumb card (selected: 2dp primary on #E9EBEF), 3:4 page, shade and
  /// checkbox when selected, number pill; tap previews, the checkbox selects.
  Widget _tile(int index, NC nc) {
    final sheet = _pages[index];
    final on = sheet.selected;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _preview(index),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFE9EBEF) : const Color(0xFFF3F5F9),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? nc.primary : const Color(0xFFE3E6EC), width: on ? 2 : 1),
          ),
          child: Stack(
            children: [
              Positioned.fill(child: PdfThumbImage(thumbs: _thumbsFor(sheet.src), index: sheet.index, rotate: sheet.rotate ~/ 90)),
              if (on) const Positioned.fill(child: ColoredBox(color: Color(0x33000000))),
              PositionedDirectional(
                top: 0,
                end: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => sheet.selected = !sheet.selected),
                  child: NativeCheckBox(checked: on, size: 40),
                ),
              ),
              PositionedDirectional(
                start: 4,
                bottom: 4,
                child: Container(
                  height: 20,
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0x99414754), borderRadius: BorderRadius.circular(3)),
                  child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 60dp bar (elevation 6) of item_bottom_tool: Insert, Rotate, Duplicate, Move to start / end,
  /// Extract, Delete; greyed (#C3C8D0) while nothing is selected.
  Widget _actions(S s, NC nc, int selectedCount) {
    final any = selectedCount > 0;
    final allSelected = selectedCount > 0 && selectedCount == _pages.length;
    Widget action(NDrawable icon, String label, VoidCallback? onTap, {bool enabled = true, Key? key}) {
      final color = enabled && onTap != null ? nc.textPrimary : const Color(0xFFC3C8D0);
      return SizedBox(
        key: key,
        width: 72,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            radius: 36,
            onTap: _busy ? null : onTap,
            child: SizedBox(
              height: 60,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  NativeIcon(icon, size: 22, tint: color),
                  const SizedBox(height: 3),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: nc.surface,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tools = [
              action(ND.icInsertPage, s.t('insert'), _insert, key: _insertKey),
              action(ND.icRotate, s.t('rotate'), _rotate, enabled: any),
              action(ND.icQCopy, s.t('duplicate'), _duplicate, enabled: any),
              action(ND.icArrowUp, s.t('moveToStart'), () => _moveTo(start: true), enabled: any),
              action(ND.icArrowDown, s.t('moveToEnd'), () => _moveTo(start: false), enabled: any),
              action(ND.icExtract, s.t('extract'), _extract, enabled: any),
              action(ND.icDelete, s.t('delete'), allSelected ? null : _delete, enabled: any),
            ];
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: tools),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// "All pages (n/N)": the pages large, swipe to move between them.
class _PagePreview extends StatefulWidget {
  const _PagePreview({required this.pages, required this.start});

  final List<_Sheet> pages;
  final int start;

  @override
  State<_PagePreview> createState() => _PagePreviewState();
}

class _PagePreviewState extends State<_PagePreview> {
  late final PageController _controller = PageController(initialPage: widget.start);
  late int _index = widget.start;
  final Map<String, PdfThumbs> _thumbs = {};

  @override
  void dispose() {
    _controller.dispose();
    for (final thumbs in _thumbs.values) {
      thumbs.close();
    }
    super.dispose();
  }

  /// dialog_page_preview.xml: white bar with ←, "All pages (n/N)" 18sp bold and a checkbox for the
  /// shown page; the pages on surface_variant with 16dp padding.
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final current = widget.pages[_index];
    return Scaffold(
      backgroundColor: nc.surface,
      appBar: NativeTopBar(
        title: s.t('allPagesTitle', {'current': '${_index + 1}', 'total': '${widget.pages.length}'}),
        actions: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => current.selected = !current.selected),
            child: NativeCheckBox(checked: current.selected, size: 48),
          ),
        ],
      ),
      body: ColoredBox(
        color: nc.surfaceVariant,
        child: PageView.builder(
          controller: _controller,
          itemCount: widget.pages.length,
          onPageChanged: (index) => setState(() => _index = index),
          itemBuilder: (context, index) {
            final sheet = widget.pages[index];
            final thumbs = _thumbs.putIfAbsent(sheet.src, () => PdfThumbs(sheet.src, width: 900));
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: InteractiveViewer(
                  child: ColoredBox(
                    color: Colors.white,
                    child: PdfThumbImage(thumbs: thumbs, index: sheet.index, rotate: sheet.rotate ~/ 90),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
