import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/doc_scanner.dart';
import '../../services/image_ops.dart';
import '../../widgets/chrome.dart';
import 'image_pdf_page.dart';
import 'scan_flow.dart';
import 'tool_widgets.dart';

String scanFilterLabel(S s, ScanFilter filter) {
  return switch (filter) {
    ScanFilter.original => s.t('original'),
    ScanFilter.auto => s.t('filterAuto'),
    ScanFilter.docs => s.t('filterDocs'),
    ScanFilter.color => s.t('filterColor'),
    ScanFilter.image => s.t('filterImage'),
    ScanFilter.superClear => s.t('filterSuper'),
    ScanFilter.enhance => s.t('filterEnhance'),
    ScanFilter.enhance2 => s.t('filterEnhance2'),
    ScanFilter.bw => s.t('filterBw'),
    ScanFilter.bw2 => s.t('filterBw2'),
    ScanFilter.gray => s.t('filterGray'),
    ScanFilter.invert => s.t('filterInvert'),
  };
}

/// Page editor after taking / choosing pictures: swipe between pages (neighbours peek in), ×
/// to remove a page, "< n/N >", hold to compare with the original, look filters with "Apply to
/// all", Retake, Pages (add more), Rotate and Crop. Done → "Processing… (x%)" → Image to PDF list.
class ScanEditPage extends StatefulWidget {
  const ScanEditPage({super.key, required this.job, this.start = 0, this.fromList = false});

  final ScanJob job;
  final int start;

  /// Opened from the Image to PDF list (returns true when pages changed).
  final bool fromList;

  @override
  State<ScanEditPage> createState() => _ScanEditPageState();
}

class _ScanEditPageState extends State<ScanEditPage> {
  late PageController _pager;
  final ScanRenderer _renderer = ScanRenderer();
  late List<ScanPage> _snapshot;
  int _index = 0;
  bool _applyAll = false;
  bool _compare = false;
  bool _busy = false;

  // crop mode
  bool _cropMode = false;
  PixelBuf? _cropBase;
  Uint8List? _cropImage;
  int _cropRotation = 0;
  List<double> _cropQuad = List<double>.of(fullQuad);
  String _cropStart = '';

  List<ScanPage> get _pages => widget.job.pages;

  ScanPage? get _current => _index >= 0 && _index < _pages.length ? _pages[_index] : null;

  @override
  void initState() {
    super.initState();
    _index = widget.start.clamp(0, math.max(0, _pages.length - 1));
    _pager = PageController(initialPage: _index, viewportFraction: 0.86);
    _snapshot = [for (final page in _pages) page.copy()];
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final cropChanged = _cropState() != _cropStart;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        // native top bar: ← … [Done] (#111317 pill) or ✓ in crop mode
        appBar: NativeTopBar(
          onBack: _back,
          titleWidget: const SizedBox.shrink(),
          actions: [
            if (_cropMode)
              Opacity(
                opacity: cropChanged ? 1 : 0.35,
                child: NativeIconButton(ND.icCheck, tint: nc.textPrimary, tooltip: s.t('ok'), onPressed: cropChanged ? _applyCrop : null),
              )
            else
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: _DoneButton(label: s.t('done'), onPressed: _busy || _pages.isEmpty ? null : _done),
              ),
          ],
        ),
        body: _pages.isEmpty
            ? const SizedBox()
            : Column(
                children: [
                  // the pager stays alive under the crop frame, so it keeps its page
                  Expanded(
                    child: ColoredBox(
                      color: nc.surfaceVariant,
                      child: IndexedStack(index: _cropMode ? 1 : 0, children: [_pagerArea(), if (_cropMode) _cropArea() else const SizedBox()]),
                    ),
                  ),
                  _counterRow(s, nc),
                  if (!_cropMode) _filterStrip(s, nc),
                  _toolBar(s, nc),
                ],
              ),
      ),
    );
  }

  /// ViewPager2 with 36dp side padding (the neighbours peek in) and 12dp top / bottom.
  Widget _pagerArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fraction = constraints.maxWidth > 120 ? (constraints.maxWidth - 72) / constraints.maxWidth : 0.86;
        if ((fraction - _pager.viewportFraction).abs() > 0.001) {
          final old = _pager;
          _pager = PageController(initialPage: _index, viewportFraction: fraction);
          WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: PageView.builder(
            controller: _pager,
            itemCount: _pages.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) {
              final page = _pages[index];
              final filter = _compare && index == _index ? ScanFilter.original : page.filter;
              // item_scan_page.xml: 8 / 12 / 8 / 8 padding, the picture fitted and centred
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                child: Center(
                  child: _PreviewImage(
                    key: ValueKey('page_${page.id}'),
                    cacheKey: page.key(filter),
                    load: () => _renderer.preview(page, filter: filter),
                    cached: _renderer.cached('p:${page.key(filter)}'),
                    onRemove: () => _removePage(index),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 52dp surface_variant row: [<] 1/2 [>] (32dp bg_nav_square) and the 34dp compare button.
  Widget _counterRow(S s, NC nc) {
    final canPrev = _index > 0 && !_cropMode;
    final canNext = _index < _pages.length - 1 && !_cropMode;
    Widget nav(bool enabled, bool back, VoidCallback onTap) {
      return Material(
        color: nc.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Color(0xFFDCE0E8))),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Transform.rotate(
                angle: back ? math.pi : 0,
                child: NativeIcon(ND.icChevronRight, tint: enabled ? nc.textPrimary : const Color(0xFFC3C8D0)),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 52,
      color: nc.surfaceVariant,
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                nav(canPrev, true, () => _pager.animateToPage(_index - 1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)),
                const SizedBox(width: 18),
                Text('${_index + 1}/${_pages.length}', style: TextStyle(fontSize: 14, color: nc.textPrimary)),
                const SizedBox(width: 18),
                nav(canNext, false, () => _pager.animateToPage(_index + 1, duration: const Duration(milliseconds: 250), curve: Curves.easeOut)),
              ],
            ),
          ),
          if (!_cropMode)
            PositionedDirectional(
              end: 16,
              top: 9,
              child: Tooltip(
                message: s.t('compare'),
                child: GestureDetector(
                  onTapDown: (_) => setState(() => _compare = true),
                  onTapUp: (_) => setState(() => _compare = false),
                  onTapCancel: () => setState(() => _compare = false),
                  child: Container(
                    width: 34,
                    height: 34,
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: _compare ? nc.divider : nc.surfaceVariant,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: NativeIcon(ND.icCompare, tint: nc.textPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// filterPanel: "Apply to all" checkbox (more than one page) and the filter strip.
  Widget _filterStrip(S s, NC nc) {
    final page = _current;
    if (page == null) return const SizedBox();
    return Container(
      color: nc.surface,
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_pages.length > 1)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: InkWell(
                onTap: () => setState(() {
                  _applyAll = !_applyAll;
                  if (_applyAll) {
                    for (final other in _pages) {
                      other.filter = page.filter;
                    }
                  }
                }),
                child: SizedBox(
                  height: 36,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NativeCheckBox(checked: _applyAll),
                      const SizedBox(width: 4),
                      Text(s.t('applyToAll'), style: TextStyle(color: nc.textPrimary, fontSize: 14)),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ),
          SizedBox(
            height: 56 + 2 + 6 + 4 + 16,
            child: _FilterThumbs(
              key: ValueKey('thumbs_${page.key(ScanFilter.original)}'),
              load: () => _renderer.thumbs(page),
              selected: page.filter,
              labelOf: (filter) => scanFilterLabel(s, filter),
              onSelect: (filter) => setState(() {
                if (_applyAll) {
                  for (final other in _pages) {
                    other.filter = filter;
                  }
                } else {
                  page.filter = filter;
                }
              }),
            ),
          ),
        ],
      ),
    );
  }

  /// editTools / cropTools: 62dp, item_bottom_tool (22dp icon + 12sp label, tool_tint).
  Widget _toolBar(S s, NC nc) {
    Widget tool(NDrawable icon, String label, VoidCallback onTap) => Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkResponse(
              onTap: _busy ? null : onTap,
              radius: 36,
              child: SizedBox(
                height: 62,
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
    final full = isFullQuad(_cropQuad);
    return Material(
      color: nc.surface,
      child: SafeArea(
        top: false,
        child: Row(
          children: _cropMode
              ? [
                  tool(ND.icRotateLeft, s.t('left'), () => _turnCrop(270)),
                  tool(ND.icRotateRight, s.t('right'), () => _turnCrop(90)),
                  tool(full ? ND.icAutoCrop : ND.icNoCrop, full ? s.t('autoCrop') : s.t('noCrop'), _toggleCrop),
                ]
              : [
                  tool(ND.icCamera, s.t('retake'), _retake),
                  tool(ND.icInsertPage, s.t('pagesLabel'), _addPages),
                  tool(ND.icRotate, s.t('rotate'), _rotate),
                  tool(ND.icCrop, s.t('crop'), _enterCrop),
                ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ pages

  void _removePage(int index) {
    if (_busy || index < 0 || index >= _pages.length) return;
    setState(() {
      _pages.removeAt(index);
      if (_index >= _pages.length) _index = math.max(0, _pages.length - 1);
    });
    if (_pages.isEmpty) {
      Navigator.of(context).pop(widget.fromList);
    }
  }

  Future<void> _addPages() async {
    final added = await addScanPages(context, widget.job);
    if (!mounted || added.isEmpty) return;
    final first = _pages.length;
    setState(() => _pages.addAll(added));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pager.hasClients) _pager.jumpToPage(first);
    });
    setState(() => _index = first);
  }

  Future<void> _retake() async {
    final page = _current;
    if (page == null) return;
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    final shots = await takeDocumentPhotos(maxPages: 1);
    if (!mounted || shots == null || shots.paths.isEmpty) return;
    List<double>? quad;
    if (!shots.fromScanner && scope.settings.scanCrop == ScanCrop.auto) {
      quad = await detectPageEdges(shots.paths.first);
    }
    if (!mounted) return;
    setState(() {
      page.source = shots.paths.first;
      page.quad = quad;
      page.rotation = 0;
    });
  }

  void _rotate() {
    final page = _current;
    if (page == null) return;
    setState(() => page.rotation = (page.rotation + 270) % 360);
  }

  // ------------------------------------------------------------------ crop

  String _cropState() => '$_cropRotation:${_cropQuad.map((v) => v.toStringAsFixed(3)).join(',')}';

  Future<void> _enterCrop() async {
    final page = _current;
    if (page == null) return;
    setState(() => _busy = true);
    final source = await _renderer.source(page.source, previewPx);
    if (!mounted) return;
    if (source == null) {
      setState(() => _busy = false);
      showToast(context, S.of(context).t('convertFailed'), warning: true);
      return;
    }
    final rotated = await _rotateIsolated(source, page.rotation);
    final bytes = await _jpegIsolated(rotated);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cropBase = rotated;
      _cropImage = bytes;
      _cropRotation = page.rotation;
      _cropQuad = rotateQuad(page.quad ?? fullQuad, page.rotation);
      _cropStart = _cropState();
      _cropMode = true;
    });
  }

  Future<void> _turnCrop(int degrees) async {
    final base = _cropBase;
    if (base == null || _busy) return;
    setState(() => _busy = true);
    final turned = await _rotateIsolated(base, degrees);
    final bytes = await _jpegIsolated(turned);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cropBase = turned;
      _cropImage = bytes;
      _cropRotation = (_cropRotation + degrees) % 360;
      _cropQuad = rotateQuad(_cropQuad, degrees);
    });
  }

  /// "No crop" frames the whole picture; when it is already whole it becomes "Auto crop".
  Future<void> _toggleCrop() async {
    final base = _cropBase;
    if (base == null) return;
    if (!isFullQuad(_cropQuad)) {
      setState(() => _cropQuad = List<double>.of(fullQuad));
      return;
    }
    setState(() => _busy = true);
    final quad = await detectPageEdgesIn(base);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (quad != null) _cropQuad = quad;
    });
    if (quad == null) showToast(context, S.of(context).t('noEdgesFound'));
  }

  void _applyCrop() {
    final page = _current;
    if (page == null) return;
    final q = unrotateQuad(_cropQuad, _cropRotation);
    setState(() {
      page.rotation = ((_cropRotation % 360) + 360) % 360;
      page.quad = isFullQuad(q) ? null : q;
      _exitCrop();
    });
  }

  void _exitCrop() {
    _cropMode = false;
    _cropBase = null;
    _cropImage = null;
  }

  Widget _cropArea() {
    final image = _cropImage;
    final base = _cropBase;
    if (image == null || base == null) return Center(child: CircularProgressIndicator(color: NC.of(context).primary));
    return CropEditor(
      image: image,
      imageWidth: base.width.toDouble(),
      imageHeight: base.height.toDouble(),
      quad: _cropQuad,
      onChanged: (quad) => setState(() => _cropQuad = quad),
    );
  }

  // ------------------------------------------------------------------ done / back

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = S.of(context);
    final pill = ProgressPill(context)..show(s.t('processingProgress', {'percent': '0'}));
    var ok = true;
    final list = List<ScanPage>.of(_pages);
    try {
      for (var i = 0; i < list.length; i++) {
        final path = await _renderer.finalFile(list[i]);
        if (path == null) {
          ok = false;
          break;
        }
        pill.show(s.t('processingProgress', {'percent': '${((i + 1) * 100 / list.length).round()}'}));
      }
    } catch (_) {
      ok = false;
    }
    pill.dismiss();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      showToast(context, s.t('convertFailed'), warning: true);
      return;
    }
    if (widget.fromList) {
      Navigator.of(context).pop(true);
    } else {
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ImagePdfPage(job: widget.job)));
    }
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_cropMode) {
      setState(_exitCrop);
      return;
    }
    if (widget.fromList) {
      // leave the list as it was
      _pages
        ..clear()
        ..addAll(_snapshot);
      Navigator.of(context).pop(false);
      return;
    }
    final s = S.of(context);
    final discard = await confirmSheet(context, title: s.t('discardTitle'), message: s.t('discardMessage'), ok: s.t('discard'));
    if (discard && mounted) Navigator.of(context).pop();
  }
}

Future<PixelBuf> _rotateIsolated(PixelBuf buf, int degrees) => Isolate.run(() => rotateBuf(buf, degrees));

Future<Uint8List> _jpegIsolated(PixelBuf buf) => Isolate.run(() => encodeJpeg(buf, quality: 85));

/// A page picture that keeps showing the last one while the next one is made, with the × on
/// its top-left corner.
class _PreviewImage extends StatefulWidget {
  const _PreviewImage({super.key, required this.cacheKey, required this.load, required this.onRemove, this.cached});

  final String cacheKey;
  final Future<Uint8List?> Function() load;
  final Uint8List? cached;
  final VoidCallback onRemove;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.cached;
    if (_bytes == null) _start();
  }

  @override
  void didUpdateWidget(covariant _PreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      if (widget.cached != null) {
        _bytes = widget.cached;
        _loading = false;
      } else {
        _start();
      }
    }
  }

  /// Called from initState / didUpdateWidget, so the flag is set without setState (a build follows).
  Future<void> _start() async {
    final key = widget.cacheKey;
    _loading = true;
    final bytes = await widget.load();
    if (!mounted || key != widget.cacheKey) return;
    setState(() {
      _loading = false;
      if (bytes != null) _bytes = bytes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.6, color: NC.of(context).primary));
    }
    // ivPage: white, elevation 2; btnDelete: bg_delete_bubble 24dp at -10 / -10
    return Stack(
      clipBehavior: Clip.none,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Color(0x29000000), blurRadius: 3, offset: Offset(0, 1))],
          ),
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        ),
        PositionedDirectional(start: -10, top: -10, child: RemoveDot(bubble: true, onTap: widget.onRemove)),
        if (_loading)
          PositionedDirectional(
            end: 8,
            top: 8,
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: NC.of(context).primary)),
          ),
      ],
    );
  }
}

/// The filter strip: a small preview of the page in every filter.
class _FilterThumbs extends StatefulWidget {
  const _FilterThumbs({super.key, required this.load, required this.selected, required this.labelOf, required this.onSelect});

  final Future<List<Uint8List>?> Function() load;
  final ScanFilter selected;
  final String Function(ScanFilter filter) labelOf;
  final void Function(ScanFilter filter) onSelect;

  @override
  State<_FilterThumbs> createState() => _FilterThumbsState();
}

class _FilterThumbsState extends State<_FilterThumbs> {
  List<Uint8List>? _thumbs;
  final ScrollController _scroll = ScrollController();

  static const _itemWidth = 68.0;

  @override
  void initState() {
    super.initState();
    widget.load().then((value) {
      if (mounted && value != null) setState(() => _thumbs = value);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!mounted || !_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target = (widget.selected.index * _itemWidth) - viewport / 2 + _itemWidth / 2;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  /// item_scan_filter.xml: 68dp wide, 56dp bg_filter_thumb (white; selected 2dp primary, else
  /// 1dp #E1E4EA; 6dp) with 2dp padding, selected shade #4D1B2A4A + white ✓, label 12sp.
  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    final thumbs = _thumbs;
    return ListView.builder(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: ScanFilter.values.length,
      itemExtent: _itemWidth,
      itemBuilder: (context, index) {
        final filter = ScanFilter.values[index];
        final on = filter == widget.selected;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelect(filter),
          child: Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: on ? nc.primary : const Color(0xFFE1E4EA), width: on ? 2 : 1),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbs != null) Image.memory(thumbs[index], fit: BoxFit.cover, gaplessPlayback: true),
                      if (on) const ColoredBox(color: Color(0x4D1B2A4A)),
                      if (on) const Center(child: NativeIcon(ND.icCheck, size: 20, tint: Colors.white)),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.labelOf(filter),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w700 : FontWeight.w400, color: on ? nc.primary : nc.textSecondary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Crop frame editor: the picture with a blue frame; drag the round corner handles (any shape —
/// the page is straightened later) or the bars in the middle of each side. A round magnifier
/// shows the spot under the finger. Corners are 0..1 fractions of the picture: TL, TR, BR, BL.
class CropEditor extends StatefulWidget {
  const CropEditor({
    super.key,
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    required this.quad,
    required this.onChanged,
  });

  final Uint8List image;
  final double imageWidth;
  final double imageHeight;
  final List<double> quad;
  final void Function(List<double> quad) onChanged;

  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  int _corner = -1;
  int _edge = -1;
  Offset? _focus;

  static const _pad = 22.0;

  /// CropView frame / handle blue.
  static const _blue = Color(0xFF1E6FE6);

  Rect _imageRect(Size size) {
    final aw = size.width - 2 * _pad;
    final ah = size.height - 2 * _pad;
    if (aw <= 0 || ah <= 0) return Offset.zero & size;
    final scale = math.min(aw / widget.imageWidth, ah / widget.imageHeight);
    final w = widget.imageWidth * scale;
    final h = widget.imageHeight * scale;
    return Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  Offset _point(Rect rect, int i) => Offset(rect.left + widget.quad[i * 2] * rect.width, rect.top + widget.quad[i * 2 + 1] * rect.height);

  void _start(Offset local, Rect rect) {
    _corner = -1;
    _edge = -1;
    var best = 30.0;
    for (var i = 0; i < 4; i++) {
      final d = (local - _point(rect, i)).distance;
      if (d < best) {
        best = d;
        _corner = i;
      }
    }
    if (_corner < 0) {
      for (var i = 0; i < 4; i++) {
        final mid = (_point(rect, i) + _point(rect, (i + 1) % 4)) / 2;
        final d = (local - mid).distance;
        if (d < best) {
          best = d;
          _edge = i;
        }
      }
    }
    setState(() => _focus = _corner >= 0 || _edge >= 0 ? local : null);
  }

  void _move(Offset delta, Rect rect) {
    if (_corner < 0 && _edge < 0) return;
    final q = List<double>.of(widget.quad);
    void shift(int i) {
      q[i * 2] = (q[i * 2] + delta.dx / rect.width).clamp(0.0, 1.0);
      q[i * 2 + 1] = (q[i * 2 + 1] + delta.dy / rect.height).clamp(0.0, 1.0);
    }

    if (_corner >= 0) {
      shift(_corner);
    } else {
      shift(_edge);
      shift((_edge + 1) % 4);
    }
    widget.onChanged(q);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final rect = _imageRect(size);
        Offset? focusPoint;
        if (_corner >= 0) focusPoint = _point(rect, _corner);
        if (_edge >= 0) focusPoint = (_point(rect, _edge) + _point(rect, (_edge + 1) % 4)) / 2;
        const radius = 46.0;
        const zoom = 2.2;
        var loupeCenter = const Offset(radius + 10, radius + 10);
        if (focusPoint != null && focusPoint.dx < loupeCenter.dx + radius * 1.4 && focusPoint.dy < loupeCenter.dy + radius * 1.4) {
          loupeCenter = Offset(size.width - radius - 10, radius + 10);
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _start(details.localPosition, rect),
          onPanUpdate: (details) => _move(details.delta, rect),
          onPanEnd: (_) => setState(() {
            _corner = -1;
            _edge = -1;
            _focus = null;
          }),
          onPanCancel: () => setState(() {
            _corner = -1;
            _edge = -1;
            _focus = null;
          }),
          child: Stack(
            children: [
              Positioned.fromRect(rect: rect, child: Image.memory(widget.image, fit: BoxFit.fill, gaplessPlayback: true)),
              Positioned.fill(child: CustomPaint(painter: _CropPainter(rect: rect, quad: widget.quad, color: _blue))),
              if (_focus != null && focusPoint != null)
                Positioned(
                  left: loupeCenter.dx - radius,
                  top: loupeCenter.dy - radius,
                  width: radius * 2,
                  height: radius * 2,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: const [BoxShadow(color: Color(0x33000000), spreadRadius: 1, offset: Offset(0, 2))],
                    ),
                    child: ClipOval(
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          const Positioned.fill(child: ColoredBox(color: Color(0xFFF3F4FA))),
                          Positioned(
                            left: radius - (focusPoint.dx - rect.left) * zoom,
                            top: radius - (focusPoint.dy - rect.top) * zoom,
                            width: rect.width * zoom,
                            height: rect.height * zoom,
                            child: Image.memory(widget.image, fit: BoxFit.fill, gaplessPlayback: true),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _CropPainter(
                                rect: Rect.fromLTWH(radius - (focusPoint.dx - rect.left) * zoom, radius - (focusPoint.dy - rect.top) * zoom, rect.width * zoom, rect.height * zoom),
                                quad: widget.quad,
                                color: _blue,
                                handles: false,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.rect, required this.quad, required this.color, this.handles = true});

  final Rect rect;
  final List<double> quad;
  final Color color;
  final bool handles;

  @override
  void paint(Canvas canvas, Size size) {
    Offset pt(int i) => Offset(rect.left + quad[i * 2] * rect.width, rect.top + quad[i * 2 + 1] * rect.height);
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < 4; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    path.close();
    if (handles && !isFullQuad(quad)) {
      canvas.save();
      canvas.clipRect(rect);
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect)
        ..addPath(path, Offset.zero);
      canvas.drawPath(outside, Paint()..color = const Color(0x55000000));
      canvas.restore();
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    if (!handles) return;
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0; i < 4; i++) {
      final a = pt(i);
      final b = pt((i + 1) % 4);
      final mid = (a + b) / 2;
      final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
      canvas.save();
      canvas.translate(mid.dx, mid.dy);
      canvas.rotate(angle);
      final bar = RRect.fromRectAndRadius(const Rect.fromLTWH(-11, -4, 22, 8), const Radius.circular(4));
      canvas.drawRRect(bar, fill);
      canvas.drawRRect(bar, stroke);
      canvas.restore();
    }
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(pt(i), 8, fill);
      canvas.drawCircle(pt(i), 8, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) => true;
}

/// btnDone: 36dp bg_done_btn (#111317, 18dp corners; #D9DCE1 when disabled), 18dp side padding,
/// "Done" 15sp bold white.
class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onPressed == null ? const Color(0xFFD9DCE1) : const Color(0xFF111317),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        splashColor: const Color(0x33FFFFFF),
        onTap: onPressed,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ),
    );
  }
}
