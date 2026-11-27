import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../services/office_layout.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/chrome.dart';
import '../files/files_ui.dart' hide NativePillButton;
import '../reader/doc_pages.dart';
import '../reader/sheet_parser.dart';
import 'pdf_thumbs.dart';
import 'tool_widgets.dart' hide NativeTopBar;

/// Word to PDF, PPT to PDF and PDF to Word, the way the Android app does it: the file's pages
/// first, then "Convert to PDF" / "Convert to Word". Conversion starts only from that button.
class ConvertPreviewPage extends StatefulWidget {
  const ConvertPreviewPage({
    super.key,
    required this.path,
    required this.name,
    required this.pdfToWord,
    required this.slides,
    required this.onConvert,
  });

  final String path;
  final String name;
  final bool pdfToWord;
  final bool slides;
  final Future<void> Function(BuildContext context) onConvert;

  @override
  State<ConvertPreviewPage> createState() => _ConvertPreviewPageState();
}

class _ConvertPreviewPageState extends State<ConvertPreviewPage> {
  PdfThumbs? _thumbs;
  int _pdfPages = 0;
  List<DocPage> _office = const [];
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _thumbs?.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.pdfToWord) {
      if (Platform.isIOS) {
        try {
          final count = await PlatformBridge.pdfPageCount(widget.path);
          if (count <= 0) {
            _fail('convertFailed');
            return;
          }
        } on PlatformException catch (error) {
          _fail(error.code == 'pdf_locked' ? 'pdfProtected' : 'convertFailed');
          return;
        }
      }
      final thumbs = PdfThumbs(widget.path, width: 900);
      final count = await thumbs.pageCount();
      if (!mounted) {
        await thumbs.close();
        return;
      }
      if (count <= 0) {
        await thumbs.close();
        _fail('convertFailed');
        return;
      }
      setState(() {
        _thumbs = thumbs;
        _pdfPages = count;
        _ready = true;
      });
      return;
    }
    final pages = await _officePages(widget.path, slides: widget.slides);
    if (!mounted) return;
    if (pages == null || pages.isEmpty) {
      _fail('convertFailed');
      return;
    }
    setState(() {
      _office = pages;
      _ready = true;
    });
  }

  void _fail(String key) {
    if (!mounted) return;
    showToast(context, S.of(context).t(key), warning: true);
    Navigator.of(context).maybePop();
  }

  Future<void> _convert() async {
    if (!_ready || _busy) return;
    setState(() => _busy = true);
    await widget.onConvert(context);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final label = widget.pdfToWord ? s.t('convertToWord') : s.t('convertToPdf');
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: c.bgScreen,
        body: SafeArea(
          child: Column(
            children: [
              NativeTopBar(title: widget.name),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.circular(16)),
                    child: _ready ? _pages(c) : Center(child: CircularProgressIndicator(color: c.primary)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: NativePillButton(
                  label: label,
                  height: 52,
                  width: double.infinity,
                  fontSize: 17,
                  onPressed: _ready && !_busy ? _convert : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pages(NC c) {
    final thumbs = _thumbs;
    if (thumbs != null) {
      return ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        itemCount: _pdfPages,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, index) => _PdfSheet(thumbs: thumbs, index: index),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      itemCount: _office.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, index) {
        final page = _office[index];
        return _sheet(c, page.width / page.height, DocPageView(page: page));
      },
    );
  }

  Widget _sheet(NC c, double aspect, Widget child) => _pageSheet(c, aspect, child);
}

class _PdfSheet extends StatefulWidget {
  const _PdfSheet({required this.thumbs, required this.index});

  final PdfThumbs thumbs;
  final int index;

  @override
  State<_PdfSheet> createState() => _PdfSheetState();
}

class _PdfSheetState extends State<_PdfSheet> {
  double _aspect = 1 / 1.414;

  @override
  void initState() {
    super.initState();
    widget.thumbs.page(widget.index).then((_) {
      if (!mounted) return;
      final aspect = widget.thumbs.aspect(widget.index);
      if (aspect != null && aspect > 0) setState(() => _aspect = aspect);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _pageSheet(
      NC.of(context),
      1 / _aspect,
      PdfThumbImage(thumbs: widget.thumbs, index: widget.index, fit: BoxFit.contain),
    );
  }
}

Widget _pageSheet(NC c, double aspect, Widget child) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(4),
      boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))],
    ),
    child: AspectRatio(aspectRatio: aspect, child: child),
  );
}

Future<List<DocPage>?> _officePages(String path, {required bool slides}) async {
  final bytes = await File(path).readAsBytes();
  final lower = path.toLowerCase();
  if (slides) {
    final layout = readOfficeLayout(bytes, slides: true);
    if (layout == null || layout.slides.isEmpty) return null;
    return slidePages(layout);
  }
  if (lower.endsWith('.txt') || lower.endsWith('.text') || lower.endsWith('.log') || lower.endsWith('.md')) {
    final paginator = DocPaginator(blocks: textBlocks(decodeTextBytes(bytes)));
    while (paginator.layoutSome(40)) {
      await Future<void>.delayed(Duration.zero);
    }
    return paginator.pages;
  }
  final layout = readOfficeLayout(bytes, slides: false);
  if (layout == null) return null;
  final paginator = DocPaginator.word(layout);
  while (paginator.layoutSome(24)) {
    await Future<void>.delayed(Duration.zero);
  }
  return paginator.pages;
}
