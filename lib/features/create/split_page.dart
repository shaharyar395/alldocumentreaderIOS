import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdfx/pdfx.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/chrome.dart';
import 'pdf_picker_page.dart';
import 'pdf_thumbs.dart';
import 'select_pages_page.dart';
import 'success_page.dart';
import 'tool_widgets.dart';

/// Tools → Split PDF: pick a PDF → [SplitPage].
Future<void> startSplit(BuildContext context, {PdfPick? file}) async {
  final s = S.of(context);
  final pick = file ?? await pickOnePdf(context, title: s.t('selectPdfToSplit'));
  if (pick == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SplitPage(file: pick)));
}

class _Part {
  _Part(this.name, this.pages);
  String name;
  final List<int> pages;
}

enum _SplitMode { custom, fixed }

/// Notebook preview with the page count and Split method: Custom range ("Select pages" → named
/// parts with rename ✎, remove ⊖, add part) or Fixed range (interval [− n +]); "Split (n)" →
/// "Splitting… (x%)" → Split successfully! with every part.
class SplitPage extends StatefulWidget {
  const SplitPage({super.key, required this.file});

  final PdfPick file;

  @override
  State<SplitPage> createState() => _SplitPageState();
}

class _SplitPageState extends State<SplitPage> {
  late final PdfThumbs _thumbs = PdfThumbs(widget.file.path, width: 220);
  int _count = 0;
  bool _loading = true;
  bool _busy = false;
  _SplitMode _mode = _SplitMode.custom;
  final List<_Part> _parts = [];
  int _interval = 1;
  late final String _baseName = stampName('Split');

  @override
  void initState() {
    super.initState();
    _thumbs.pageCount().then((count) {
      if (!mounted) return;
      setState(() {
        _count = count;
        _loading = false;
        _interval = math.max(1, math.min(_interval, count));
      });
    });
  }

  @override
  void dispose() {
    _thumbs.close();
    super.dispose();
  }

  String _ranges(List<int> pages) {
    final sorted = [...pages]..sort();
    final out = <String>[];
    var i = 0;
    while (i < sorted.length) {
      var j = i;
      while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
        j++;
      }
      out.add(j > i + 1 ? '${sorted[i] + 1}-${sorted[j] + 1}' : (j == i + 1 ? '${sorted[i] + 1},${sorted[j] + 1}' : '${sorted[i] + 1}'));
      i = j + 1;
    }
    return out.join(',');
  }

  List<_Part> _fixedParts() {
    final parts = <_Part>[];
    var index = 1;
    for (var start = 0; start < _count; start += _interval) {
      final end = math.min(_count, start + _interval);
      parts.add(_Part(index == 1 ? _baseName : '${_baseName}_$index', [for (var i = start; i < end; i++) i]));
      index++;
    }
    return parts;
  }

  List<_Part> get _result => _mode == _SplitMode.custom ? _parts : _fixedParts();

  Future<void> _addPart() async {
    if (_count == 0) return;
    final pages = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute(builder: (_) => SelectPagesPage(thumbs: _thumbs, count: _count)),
    );
    if (pages == null || pages.isEmpty || !mounted) return;
    setState(() {
      final n = _parts.length + 1;
      var name = n == 1 ? _baseName : '${_baseName}_$n';
      while (_parts.any((part) => part.name == name)) {
        name = '${name}_1';
      }
      _parts.add(_Part(name, pages));
    });
  }

  Future<void> _renamePart(_Part part) async {
    final s = S.of(context);
    final name = await askText(context, title: s.t('rename'), initial: part.name, hint: s.t('nameHint'));
    if (name == null || !mounted) return;
    setState(() => part.name = name);
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_parts.isEmpty && _mode == _SplitMode.custom) {
      Navigator.of(context).pop();
      return;
    }
    final s = S.of(context);
    final quit = await confirmSheet(context, title: s.t('quitSplittingTitle'), message: s.t('quitChangesMessage'), ok: s.t('quit'));
    if (quit && mounted) Navigator.of(context).pop();
  }

  Future<void> _split() async {
    final parts = _result;
    if (_busy || parts.isEmpty) return;
    if (_count < 2) {
      showToast(context, S.of(context).t('splitOnePage'));
      return;
    }
    setState(() => _busy = true);
    final s = S.of(context);
    final scope = AppScope.of(context);
    final pill = ProgressPill(context)..show(s.t('splittingProgress', {'percent': '0'}));
    final saved = <DocEntry>[];
    try {
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final bytes = await assemblePdf([for (final page in part.pages) SourcePage(widget.file.path, page)]) ?? await _pictures(part.pages);
        final entry = await scope.library.importBytes(bytes, name: '${part.name}.pdf', folder: 'split');
        if (entry != null) saved.add(entry);
        pill.show(s.t('splittingProgress', {'percent': '${((i + 1) * 99 / parts.length).round()}'}));
      }
      pill.dismiss();
      if (!mounted) return;
      if (saved.isEmpty) throw StateError('save');
      await scope.ads.showInterstitial(unit: 2);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SuccessPage(entry: saved.first, kind: ResultKind.split, parts: saved, feature: s.t('splitPdf'), featureKey: 'split'),
        ),
      );
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, s.t('splitFailed'), warning: true);
    }
  }

  /// Fallback when real pages can't be copied: the pages as pictures.
  Future<List<int>> _pictures(List<int> pages) async {
    final document = await PdfDocument.openFile(widget.file.path);
    try {
      final pieces = <PdfPiece>[];
      for (final index in pages) {
        if (index < 0 || index >= document.pagesCount) continue;
        final page = await document.getPage(index + 1);
        final rendered = await page.render(width: page.width * 1.5, height: page.height * 1.5, format: PdfPageImageFormat.jpeg, backgroundColor: '#FFFFFF', quality: 88);
        final format = PdfPageFormat(page.width, page.height);
        await page.close();
        if (rendered != null) pieces.add(PdfPiece(image: rendered.bytes, pageFormat: format));
      }
      return await rebuildPdf(pieces);
    } finally {
      await document.close();
    }
  }

  /// Bottom action like the native btnAction: "Split (n)" for the parts list, "Select pages" for
  /// Custom range, "Split" for Fixed range.
  void _onAction() {
    if (_busy || _count < 1) return;
    if (_parts.isNotEmpty || _mode == _SplitMode.fixed) {
      _split();
    } else {
      _addPart();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final listing = _mode == _SplitMode.custom && _parts.isNotEmpty;
    final label = listing
        ? s.t('splitN', {'count': '${_parts.length}'})
        : (_mode == _SplitMode.custom ? s.t('selectPages') : s.t('splitAction'));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        appBar: NativeTopBar(
          onBack: _back,
          titleWidget: Text(
            s.t('splitPdf'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: nc.textPrimary),
          ),
          actions: [
            if (listing) NativeIconButton(ND.icFileAdd, tint: nc.textPrimary, tooltip: s.t('addPages'), onPressed: _busy ? null : _addPart),
          ],
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: nc.primary))
            : Column(
                children: [
                  Expanded(child: listing ? _partsList(s, nc) : _methodView(s, nc)),
                  NativeBottomAction(label: label, enabled: !_busy && _count > 0, onPressed: _onAction),
                ],
              ),
      ),
    );
  }

  Widget _methodView(S s, NC nc) {
    final max = math.max(1, _count);
    Widget methodRow(_SplitMode mode, String title, String subtitle) {
      return InkWell(
        onTap: () => setState(() => _mode = mode),
        child: Container(
          height: 56,
          padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: nc.textSecondary)),
                  ],
                ),
              ),
              NativeRadio(checked: _mode == mode),
            ],
          ),
        ),
      );
    }

    Widget stepper(NDrawable icon, bool enabled, VoidCallback onTap) {
      return Opacity(
        opacity: enabled ? 1 : 0.3,
        child: NativeIconButton(icon, size: 34, padding: 9, tint: nc.textPrimary, onPressed: enabled ? onTap : null),
      );
    }

    return ListView(
      children: [
        // file band: bg_soft_card, notebook 84 x 112 and the name
        Container(
          color: nc.bgSoftCard,
          padding: const EdgeInsets.only(top: 24, bottom: 20),
          child: Column(
            children: [
              Container(
                width: 84,
                height: 112,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0xFFE4E7EC), width: 0.8),
                  boxShadow: const [BoxShadow(color: Color(0x29000000), blurRadius: 5, offset: Offset(0, 2))],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 11,
                      top: 4,
                      right: 4,
                      bottom: 4,
                      child: _count > 0 ? PdfThumbImage(thumbs: _thumbs, index: 0, fit: BoxFit.cover) : const SizedBox(),
                    ),
                    const Positioned(
                      left: 1,
                      top: 0,
                      bottom: 0,
                      width: 11,
                      child: FittedBox(fit: BoxFit.fill, child: NativeIcon(ND.icSpiral, width: 14, height: 160)),
                    ),
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: Container(
                        height: 16,
                        constraints: const BoxConstraints(minWidth: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: const Color(0xB3333A45), borderRadius: BorderRadius.circular(3)),
                        child: Text('$_count', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  widget.file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, top: 18, bottom: 6),
          child: Text(s.t('splitMethod'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: nc.textPrimary)),
        ),
        methodRow(_SplitMode.custom, s.t('splitCustomRange'), s.t('splitCustomRangeSub')),
        methodRow(_SplitMode.fixed, s.t('splitFixedRange'), s.t('splitFixedRangeSub')),
        const SizedBox(height: 6),
        Divider(height: 1, thickness: 1, color: nc.divider),
        if (_mode == _SplitMode.fixed)
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: Text(s.t('intervalSettings'), style: TextStyle(fontSize: 15, color: nc.textPrimary))),
                Container(
                  height: 32,
                  decoration: BoxDecoration(color: nc.bgSoftCard, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      stepper(ND.icMinus, _interval > 1, () => setState(() => _interval--)),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          final value = await askNumber(context, title: s.t('intervalSettings'), initial: _interval, min: 1, max: max);
                          if (value != null && mounted) setState(() => _interval = value);
                        },
                        child: SizedBox(
                          width: 34,
                          child: Text('$_interval', textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
                        ),
                      ),
                      stepper(ND.icAdd, _interval < max, () => setState(() => _interval++)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// item_pdf_part.xml without ⋮⋮: ic_cat_pdf, name ✎ (tap renames), "Page: 1,2", ⊖.
  Widget _partsList(S s, NC nc) {
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        for (final part in _parts)
          Container(
            height: 58,
            color: nc.surface,
            padding: const EdgeInsetsDirectional.only(start: 6, end: 8),
            child: Row(
              children: [
                const SizedBox(width: 6),
                const NativeIcon(ND.icCatPdf, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: GestureDetector(
                              onTap: () => _renamePart(part),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 240),
                                child: Text(
                                  part.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary),
                                ),
                              ),
                            ),
                          ),
                          NativeIconButton(ND.icRename, size: 28, padding: 6, tint: nc.textHint, tooltip: s.t('rename'), onPressed: () => _renamePart(part)),
                        ],
                      ),
                      Text(
                        s.t('partPages', {'pages': _ranges(part.pages)}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: nc.textSecondary),
                      ),
                    ],
                  ),
                ),
                NativeIconButton(
                  ND.icRemoveCircle,
                  size: 40,
                  padding: 9,
                  tint: nc.textPrimary,
                  tooltip: s.t('delete'),
                  onPressed: _busy ? null : () => setState(() => _parts.remove(part)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
