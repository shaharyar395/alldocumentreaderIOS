import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/chrome.dart';
import '../editor/editor_flow.dart';
import '../files/file_actions.dart';
import '../files/storage_browser_page.dart';
import '../home/create_sheet.dart';
import '../settings/feedback_page.dart';
import 'tool_widgets.dart';

enum ResultKind { converted, merged, split, created, saved }

/// "Converted / Merged / Split successfully!": notebook preview with the page count, file name
/// with rename, Open / Share, tools that act on this file, and (once per feature) "Are you
/// satisfied with our "X" feature?".
class SuccessPage extends StatefulWidget {
  const SuccessPage({
    super.key,
    required this.entry,
    this.kind = ResultKind.converted,
    this.feature,
    this.featureKey,
    this.parts = const [],
  });

  final DocEntry entry;
  final ResultKind kind;

  /// Shown name of the tool ("Merge PDF") for the satisfaction card, and its storage key.
  final String? feature;
  final String? featureKey;

  /// Split PDF: every part (the [entry] is the first one).
  final List<DocEntry> parts;

  @override
  State<SuccessPage> createState() => _SuccessPageState();
}

class _SuccessPageState extends State<SuccessPage> with SingleTickerProviderStateMixin {
  late DocEntry _entry = widget.entry;
  late List<DocEntry> _parts = widget.parts;
  Uint8List? _preview;
  int _pages = 0;
  bool _askSatisfied = false;
  bool _started = false;

  /// ConvertResultActivity.animateIn: the pill drops in (300 ms) and fades at 2.6 s (400 ms), the
  /// notebook pops from 0.85 (350 ms) and three sparkles twinkle (1100 ms, 180 ms apart, 3 times).
  static const _introMs = 3660.0;
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 3660));

  @override
  void initState() {
    super.initState();
    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  bool get _isPdf => _entry.kind == DocKind.pdf;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _loadPreview();
    _checkSatisfied();
  }

  Future<void> _checkSatisfied() async {
    final key = widget.featureKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _askSatisfied = !(prefs.getBool('satisfied_answered_$key') ?? false));
  }

  Future<void> _answerSatisfied({required bool good}) async {
    final key = widget.featureKey;
    setState(() => _askSatisfied = false);
    if (key != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('satisfied_answered_$key', true);
    }
    if (!mounted) return;
    if (good) {
      showToast(context, S.of(context).t('thanksFeedback'));
    } else {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FeedbackPage()));
    }
  }

  Future<void> _loadPreview() async {
    if (!_isPdf) return;
    final path = AppScope.of(context).library.fileOf(_entry).path;
    try {
      final document = await PdfDocument.openFile(path);
      try {
        final count = document.pagesCount;
        final page = await document.getPage(1);
        const width = 360.0;
        final height = width * page.height / page.width;
        final image = await page.render(width: width, height: height, format: PdfPageImageFormat.jpeg, backgroundColor: '#FFFFFF', quality: 85);
        await page.close();
        if (!mounted) return;
        setState(() {
          _pages = count;
          _preview = image?.bytes;
        });
      } finally {
        await document.close();
      }
    } catch (_) {
      // no preview
    }
  }

  void _refreshEntry() {
    final library = AppScope.of(context).library;
    for (final entry in library.entries) {
      if (entry.id == _entry.id) _entry = entry;
    }
    _parts = [
      for (final part in _parts) library.entries.cast<DocEntry?>().firstWhere((e) => e?.id == part.id, orElse: () => part)!,
    ];
  }

  /// FileSheets.showRename (sheet_rename) like the native result screen.
  Future<void> _rename() async {
    final renamed = await renameEntry(context, _entry);
    if (renamed == null || !mounted) return;
    setState(() {
      _entry = renamed;
      _refreshEntry();
    });
  }

  /// "View locally": the folder of the file in the storage browser (Android only).
  void _viewLocally() {
    final path = AppScope.of(context).library.fileOf(_entry).path;
    final folder = p.dirname(path);
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => StorageBrowserPage(root: folder, rootName: p.basename(folder))),
    );
  }

  Future<void> _afterTool(Future<void> Function() tool) async {
    await tool();
    if (!mounted) return;
    setState(_refreshEntry);
    await _loadPreview();
  }

  Future<void> _print() async {
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    final file = scope.library.fileOf(_entry);
    try {
      final bytes = await file.readAsBytes();
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: _entry.name);
    } catch (_) {
      if (mounted) showToast(context, S.of(context).t('saveFailed'), warning: true);
    }
  }

  String _title(S s) {
    return switch (widget.kind) {
      ResultKind.converted => s.t('convertedSuccessfullyExcl'),
      ResultKind.merged => s.t('mergedSuccessfullyExcl'),
      ResultKind.split => s.t('splitSuccessfullyExcl'),
      ResultKind.created || ResultKind.saved => s.t('savedSuccessfully'),
    };
  }

  double _ms() => _intro.value * _introMs;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    // same order as the native result screen: Edit text, Annotate, Add text, Sign / PDF to Word,
    // Manage pages, Print PDF
    final tools = <(NDrawable, String, Future<void> Function())>[
      (ND.icRtEditText, s.t('editText'), () => openMarkup(context, entry: _entry, tool: MarkTool.editText)),
      (ND.icRtAnnotate, s.t('annotate'), () => openMarkup(context, entry: _entry, tool: MarkTool.pen)),
      (ND.icRtAddText, s.t('addText'), () => openMarkup(context, entry: _entry, tool: MarkTool.text)),
      (ND.icRtSign, s.t('sign'), () => openMarkup(context, entry: _entry, tool: MarkTool.sign)),
      (ND.icRtPdf2word, s.t('pdfToWord'), () => convertPdfToWord(context, entry: _entry)),
      (ND.icRtManagePages, s.t('managePages'), () => openManagePages(context, entry: _entry)),
      (ND.icRtPrint, s.t('printPdf'), _print),
    ];
    return Scaffold(
      backgroundColor: nc.surface,
      appBar: AppBar(
        toolbarHeight: 56,
        backgroundColor: nc.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              PositionedDirectional(
                start: 4,
                top: 6,
                child: NativeIconButton(ND.icBack, tint: nc.textPrimary, onPressed: () => Navigator.maybePop(context)),
              ),
              Center(child: _successPill(s)),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  _notebook(nc),
                  const SizedBox(height: 4),
                  // file name (17sp bold) + 34dp rename button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            _entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: nc.textPrimary),
                          ),
                        ),
                        NativeIconButton(ND.icRename, size: 34, padding: 8, tint: nc.textHint, tooltip: s.t('rename'), onPressed: _rename),
                      ],
                    ),
                  ),
                  if (Platform.isAndroid) ...[
                    const SizedBox(height: 4),
                    Material(
                      color: nc.surfaceVariant,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _viewLocally,
                        child: Container(
                          height: 28,
                          padding: const EdgeInsetsDirectional.only(start: 8, end: 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              NativeIcon(ND.icFolderOutline, size: 24, tint: nc.primary),
                              const SizedBox(width: 6),
                              Text(s.t('viewLocally'), style: TextStyle(fontSize: 14, color: nc.primary)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  // Open (bg_outline_btn) | Share (bg_apply_btn), 140 x 46dp
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 140,
                        height: 46,
                        child: Material(
                          color: nc.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22),
                            side: BorderSide(color: nc.primary, width: 1.4),
                          ),
                          child: InkWell(
                            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                            onTap: () => openEntry(context, _entry),
                            child: Center(
                              child: Text(s.t('open'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: nc.primary)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      NativePillButton(width: 140, height: 46, fontSize: 17, label: s.t('share'), onPressed: () => shareEntry(context, _entry)),
                    ],
                  ),
                  if (_parts.length > 1) ...[
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          s.t('splitDone', {'count': '${_parts.length}'}),
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: nc.textPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final part in _parts) _partRow(part, nc),
                  ],
                  if (_isPdf) ...[
                    const SizedBox(height: 36),
                    // "—— Tools ——" with fading lines
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 1,
                              decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0x00D5DAE2), Color(0xFFD5DAE2)])),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(s.t('tools'), style: TextStyle(fontSize: 14, color: nc.textSecondary)),
                          ),
                          Expanded(
                            child: Container(
                              height: 1,
                              decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFD5DAE2), Color(0x00D5DAE2)])),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: NativeToolGrid(
                        cells: [
                          for (final tool in tools) NativeToolCell(icon: tool.$1, label: tool.$2, onTap: () => _afterTool(tool.$3)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_askSatisfied && widget.feature != null) _satisfiedCard(s, nc),
          const BannerSlot(unit: 2),
        ],
      ),
    );
  }

  /// tvSuccess: 36dp bg_success_pill (#2DC26B, 18dp), ic_check_circle_outline white, 15sp bold.
  Widget _successPill(S s) {
    return AnimatedBuilder(
      animation: _intro,
      builder: (context, child) {
        final ms = _ms();
        final inT = Curves.decelerate.transform((ms / 300).clamp(0.0, 1.0));
        final outT = ((ms - 2600) / 400).clamp(0.0, 1.0);
        final opacity = (inT * (1 - outT)).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(offset: Offset(0, -16 * (1 - inT)), child: child),
        );
      },
      child: Container(
        height: 36,
        padding: const EdgeInsetsDirectional.only(start: 12, end: 16),
        decoration: BoxDecoration(color: const Color(0xFF2DC26B), borderRadius: BorderRadius.circular(18)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NativeIcon(ND.icCheckCircleOutline, size: 24, tint: Colors.white),
            const SizedBox(width: 8),
            Text(_title(s), style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _partRow(DocEntry part, NC nc) {
    return InkWell(
      onTap: () => openEntry(context, part),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 20, end: 8, top: 6, bottom: 6),
        child: Row(
          children: [
            const NativeIcon(ND.icCatPdf, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    part.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: nc.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(formatBytes(part.bytes), style: TextStyle(fontSize: 12, color: nc.textSecondary)),
                ],
              ),
            ),
            NativeIconButton(ND.icShare, tint: nc.textSecondary, tooltip: S.of(context).t('share'), onPressed: () => shareEntry(context, part)),
          ],
        ),
      ),
    );
  }

  /// 220 x 178 frame: three ic_sparkle and the 120 x 160 bg_notebook (white, 0.8dp #E4E7EC, 3dp,
  /// elevation 6) with the first page (centerCrop), the ic_spiral and the page-count badge.
  Widget _notebook(NC nc) {
    final preview = _preview;
    Widget sparkle(int index, double size) {
      return AnimatedBuilder(
        animation: _intro,
        builder: (context, child) {
          final local = _ms() - 180 * index;
          if (local <= 0 || local >= 3300) return const SizedBox.shrink();
          final cycle = (local % 1100) / 1100;
          final up = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2;
          return Opacity(
            opacity: up.clamp(0.0, 1.0),
            child: Transform.scale(scale: 0.4 + 0.7 * up, child: child),
          );
        },
        child: NativeIcon(ND.icSparkle, size: size),
      );
    }

    return SizedBox(
      width: 220,
      height: 178,
      child: Stack(
        children: [
          PositionedDirectional(start: 18, top: (178 - 18) / 2 - 10, child: sparkle(0, 18)),
          PositionedDirectional(start: 30, top: 36, child: sparkle(1, 10)),
          PositionedDirectional(end: 34, bottom: 30, child: sparkle(2, 12)),
          Center(
            child: AnimatedBuilder(
              animation: _intro,
              builder: (context, child) {
                final t = Curves.decelerate.transform((_ms() / 350).clamp(0.0, 1.0));
                return Transform.scale(scale: 0.85 + 0.15 * t, child: child);
              },
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0xFFE4E7EC), width: 0.8),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3))],
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      left: 14,
                      top: 6,
                      right: 6,
                      bottom: 6,
                      child: preview == null
                          ? Center(child: NativeIcon(_isPdf ? ND.icCatPdf : ND.icCatWord, size: 40))
                          : Image.memory(preview, fit: BoxFit.cover, alignment: Alignment.topCenter),
                    ),
                    const Positioned(left: 2, top: 0, bottom: 0, width: 14, child: _Spiral()),
                    if (_pages > 0)
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: Container(
                          height: 18,
                          constraints: const BoxConstraints(minWidth: 18),
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: const Color(0xB3333A45), borderRadius: BorderRadius.circular(3)),
                          child: Text(
                            '$_pages',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
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
  }

  /// feedbackCard: bg_satisfied_card (bg_soft_card, 12dp), question 13sp bold, × 32dp text_hint,
  /// two 52dp bg_satisfied_btn (surface, 8dp) "😞 / Not good" and "🥰 / Good" 12sp, 18dp apart.
  Widget _satisfiedCard(S s, NC nc) {
    Widget choice(String emoji, String label, bool good) => Expanded(
          child: Material(
            color: nc.surface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              splashColor: const Color(0x1A000000),
              highlightColor: const Color(0x1A000000),
              onTap: () => _answerSatisfied(good: good),
              child: SizedBox(
                height: 52,
                child: Center(
                  child: Text(
                    '$emoji\n$label',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: nc.textPrimary),
                  ),
                ),
              ),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 8, 12),
      decoration: BoxDecoration(color: nc.bgSoftCard, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.t('satisfiedQuestion', {'feature': widget.feature ?? ''}),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: nc.textPrimary),
                ),
              ),
              NativeIconButton(
                ND.icClose,
                size: 32,
                padding: 8,
                tint: nc.textHint,
                tooltip: s.t('cancel'),
                onPressed: () => setState(() => _askSatisfied = false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: Row(
              children: [
                choice('\u{1F61E}', s.t('notGood'), false),
                const SizedBox(width: 18),
                choice('\u{1F970}', s.t('good'), true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// res/drawable/ic_spiral (14 x 160) stretched to the notebook height (scaleType fitXY).
class _Spiral extends StatelessWidget {
  const _Spiral();

  @override
  Widget build(BuildContext context) {
    return const FittedBox(fit: BoxFit.fill, child: NativeIcon(ND.icSpiral, width: 14, height: 160));
  }
}
