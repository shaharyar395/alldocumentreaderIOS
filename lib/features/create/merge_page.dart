import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/chrome.dart';
import 'pdf_picker_page.dart';
import 'success_page.dart';
import 'tool_widgets.dart';

/// Tools → Merge PDF: "Select PDFs to merge" (checkboxes, Continue (n), Browse) → [MergePage].
Future<void> startMerge(BuildContext context, {List<PdfPick> preselected = const []}) async {
  final s = S.of(context);
  final picks = await Navigator.of(context).push<List<PdfPick>>(
    MaterialPageRoute(builder: (_) => PdfPickerPage(title: s.t('selectPdfsToMerge'), multiple: true, minimum: 2, preselected: preselected)),
  );
  if (picks == null || picks.length < 2 || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MergePage(initial: picks)));
}

/// The files to merge: ⋮⋮ drag to reorder, "2 pages · 8.7 KB", ⊖ remove, add more; back →
/// "Quit merging?"; "Merge (n)" → "Merging… (x%)" → Merged successfully!
class MergePage extends StatefulWidget {
  const MergePage({super.key, this.initial = const []});

  final List<PdfPick> initial;

  @override
  State<MergePage> createState() => _MergePageState();
}

class _MergePageState extends State<MergePage> {
  late final List<PdfPick> _files = List<PdfPick>.of(widget.initial);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _countPages();
  }

  Future<void> _countPages() async {
    for (final file in List<PdfPick>.of(_files)) {
      if (file.pages > 0) continue;
      final count = await pdfPageCount(file.path);
      if (!mounted) return;
      setState(() => file.pages = count);
    }
  }

  Future<void> _add() async {
    final s = S.of(context);
    final picks = await Navigator.of(context).push<List<PdfPick>>(
      MaterialPageRoute(builder: (_) => PdfPickerPage(title: s.t('selectPdfsToMerge'), multiple: true, minimum: 1, preselected: _files)),
    );
    if (picks == null || !mounted) return;
    setState(() {
      final keep = [for (final file in _files) if (picks.any((pick) => pick.path == file.path)) file];
      final added = [for (final pick in picks) if (!_files.any((file) => file.path == pick.path)) pick];
      _files
        ..clear()
        ..addAll(keep)
        ..addAll(added);
    });
    await _countPages();
  }

  Future<void> _back() async {
    if (_busy) return;
    final s = S.of(context);
    final quit = await confirmSheet(context, title: s.t('quitMergingTitle'), message: s.t('quitChangesMessage'), ok: s.t('quit'));
    if (quit && mounted) Navigator.of(context).pop();
  }

  Future<void> _merge() async {
    if (_busy || _files.length < 2) return;
    setState(() => _busy = true);
    final s = S.of(context);
    final scope = AppScope.of(context);
    final pill = ProgressPill(context)..show(s.t('mergingProgress', {'percent': '0'}));
    try {
      final bytes = await mergePdfPaths(
        [for (final file in _files) file.path],
        (value) => pill.show(s.t('mergingProgress', {'percent': '${(value * 99).round()}'})),
      );
      final entry = await scope.library.importBytes(bytes, name: '${stampName('Merged')}.pdf', folder: 'merged');
      pill.dismiss();
      if (!mounted) return;
      if (entry == null) throw StateError('save');
      await scope.ads.showInterstitial(unit: 2);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SuccessPage(entry: entry, kind: ResultKind.merged, feature: s.t('mergePdf'), featureKey: 'merge'),
        ),
      );
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, s.t('mergeFailed'), warning: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final canMerge = !_busy && _files.length >= 2;
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
            s.t('mergePdf'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: nc.textPrimary),
          ),
          actions: [
            NativeIconButton(ND.icFileAdd, tint: nc.textPrimary, tooltip: s.t('addFiles'), onPressed: _busy ? null : _add),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(top: 4),
                itemCount: _files.length,
                proxyDecorator: (child, index, animation) => Material(
                  elevation: 8,
                  color: nc.surface,
                  child: Opacity(opacity: 0.95, child: child),
                ),
                onReorderItem: (oldIndex, newIndex) {
                  setState(() => _files.insert(newIndex, _files.removeAt(oldIndex)));
                },
                itemBuilder: (context, index) {
                  final file = _files[index];
                  // item_pdf_part.xml: 58dp, ⋮⋮ 24dp, ic_cat_pdf 30dp, name 15sp bold, meta 12sp, ⊖ 40dp
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(file.path),
                    index: index,
                    enabled: !_busy,
                    child: Container(
                      height: 58,
                      color: nc.surface,
                      padding: const EdgeInsetsDirectional.only(start: 6, end: 8),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            enabled: !_busy,
                            child: const NativeIcon(ND.icDragDots, size: 24),
                          ),
                          const SizedBox(width: 6),
                          const NativeIcon(ND.icCatPdf, size: 30),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  file.pages > 0
                                      ? s.t('pagesAndSize', {'count': '${file.pages}', 'size': formatBytes(file.bytes)})
                                      : formatBytes(file.bytes),
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
                            onPressed: _busy ? null : () => setState(() => _files.removeAt(index)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            NativeBottomAction(
              label: s.t('mergeN', {'count': '${_files.length}'}),
              enabled: _files.length >= 2,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              onPressed: canMerge ? _merge : null,
            ),
          ],
        ),
      ),
    );
  }
}
