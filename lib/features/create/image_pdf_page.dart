import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/chrome.dart';
import 'scan_edit_page.dart';
import 'scan_flow.dart';
import 'success_page.dart';
import 'tool_widgets.dart';

/// "Image to PDF": the finished pages in a numbered 2-column grid — long press and drag to
/// reorder, × to remove, tap to edit again, Add pages (tile or top-right icon) — then Convert →
/// "Converting… (x%)" → Converted successfully. Saved as Image_PDF_yyyyMMdd_HHmm.pdf.
class ImagePdfPage extends StatefulWidget {
  const ImagePdfPage({super.key, required this.job});

  final ScanJob job;

  @override
  State<ImagePdfPage> createState() => _ImagePdfPageState();
}

class _ImagePdfPageState extends State<ImagePdfPage> {
  static const _hintKey = 'img2pdf_hint_closed';
  bool _busy = false;
  bool _hintClosed = true;
  int _version = 0;

  List<ScanPage> get _pages => widget.job.pages;

  final ScanRenderer _renderer = ScanRenderer();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _hintClosed = prefs.getBool(_hintKey) ?? false);
    });
    _ensureOutputs();
  }

  /// Pages that have no finished picture yet (e.g. added and then backed out of the editor).
  Future<void> _ensureOutputs() async {
    for (final page in List<ScanPage>.of(_pages)) {
      if (page.outputReady) continue;
      try {
        await _renderer.finalFile(page);
      } catch (_) {
        continue;
      }
      if (!mounted) return;
      setState(() => _version++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: nc.surface,
        appBar: NativeTopBar(
          title: s.t('imageToPdf'),
          onBack: _confirmDiscard,
          actions: [
            NativeIconButton(ND.icInsertPage, tint: nc.textPrimary, tooltip: s.t('addPages'), onPressed: _busy ? null : _addPages),
          ],
        ),
        body: Column(
          children: [
            // hintBanner: bg_banner 40dp, ic_reorder (primary), "Long press and drag to reorder", ×
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
                      child: Text(
                        s.t('dragHint'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: nc.textPrimary),
                      ),
                    ),
                    NativeIconButton(
                      ND.icClose,
                      size: 36,
                      padding: 11,
                      tint: nc.textSecondary,
                      tooltip: s.t('cancel'),
                      onPressed: () async {
                        setState(() => _hintClosed = true);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(_hintKey, true);
                      },
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ReorderGrid(
                itemCount: _pages.length,
                padding: const EdgeInsets.all(16),
                spacing: 12,
                childAspectRatio: 0.8,
                itemKey: (index) => ValueKey('img_${_pages[index].id}_$_version'),
                onReorder: (from, to) => setState(() {
                  final page = _pages.removeAt(from);
                  _pages.insert(to, page);
                  _version++;
                }),
                itemBuilder: (context, index) => _tile(index, nc),
                footer: AddTile(label: s.t('addPages'), onTap: _addPages),
              ),
            ),
            // btnConvert: 52dp bg_apply_btn, 16dp margins, "Convert" 17sp bold
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: NativePillButton(
                    height: 52,
                    fontSize: 17,
                    label: s.t('convert'),
                    onPressed: _busy || _pages.isEmpty ? null : _convert,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// item_scan_thumb.xml: 8:9 picture (centerCrop on #F1F3F7), 26dp dark × at the top end,
  /// number pill (bg_page_number) at the bottom start.
  Widget _tile(int index, NC nc) {
    final page = _pages[index];
    final output = page.output;
    return GestureDetector(
      onTap: () => _edit(index),
      child: Align(
        alignment: Alignment.topCenter,
        child: AspectRatio(
          aspectRatio: 8 / 9,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xFFF1F3F7),
                  child: output == null
                      ? Center(
                          child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.6, color: nc.primary)),
                        )
                      : Image.file(File(output), fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 420),
                ),
              ),
              PositionedDirectional(
                top: 6,
                end: 6,
                child: RemoveDot(onTap: () => _remove(index)),
              ),
              PositionedDirectional(
                start: 5,
                bottom: 5,
                child: Container(
                  height: 20,
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0x99414754), borderRadius: BorderRadius.circular(3)),
                  child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _remove(int index) {
    if (_busy) return;
    setState(() {
      _pages.removeAt(index);
      _version++;
    });
    if (_pages.isEmpty) Navigator.of(context).pop();
  }

  Future<void> _edit(int index) async {
    if (_busy) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ScanEditPage(job: widget.job, start: index, fromList: true)),
    );
    if (!mounted) return;
    if (_pages.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _version++);
    await _ensureOutputs();
  }

  Future<void> _addPages() async {
    if (_busy) return;
    final added = await addScanPages(context, widget.job);
    if (!mounted || added.isEmpty) return;
    final first = _pages.length;
    _pages.addAll(added);
    await _edit(first);
  }

  Future<void> _convert() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = S.of(context);
    final scope = AppScope.of(context);
    final pill = ProgressPill(context)..show(s.t('convertingProgress', {'percent': '0'}));
    try {
      // pages not finished yet are made first
      final images = <Uint8List>[];
      for (var i = 0; i < _pages.length; i++) {
        final path = await _renderer.finalFile(_pages[i]);
        if (path == null) throw StateError('page');
        images.add(await File(path).readAsBytes());
        pill.show(s.t('convertingProgress', {'percent': '${((i + 1) * 40 / _pages.length).round()}'}));
      }
      final bytes = await imagesToPdf(
        images,
        fitPage: true,
        onProgress: (value) => pill.show(s.t('convertingProgress', {'percent': '${(40 + value * 59).round()}'})),
      );
      final entry = await scope.library.importBytes(bytes, name: '${stampName('Image_PDF')}.pdf', folder: 'convert');
      pill.dismiss();
      if (!mounted) return;
      if (entry == null) {
        showToast(context, s.t('convertFailed'), warning: true);
        setState(() => _busy = false);
        return;
      }
      await scope.ads.showInterstitial();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => SuccessPage(entry: entry, kind: ResultKind.converted, feature: s.t('imageToPdf'), featureKey: 'image_to_pdf')),
      );
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, s.t('convertFailed'), warning: true);
    }
  }

  Future<void> _confirmDiscard() async {
    if (_busy) return;
    final s = S.of(context);
    final discard = await confirmSheet(context, title: s.t('discardTitle'), message: s.t('discardMessage'), ok: s.t('discard'));
    if (discard && mounted) Navigator.of(context).pop();
  }
}
