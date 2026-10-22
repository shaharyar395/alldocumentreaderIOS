import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../services/ocr_service.dart';
import '../../services/office_layout.dart';
import '../../services/office_pdf.dart';
import '../../services/pdf_rewrite.dart';
import '../../services/pdf_text.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart' show MiddleEllipsisText;
import '../editor/editor_flow.dart';
import '../files/file_actions.dart';
import '../home/create_sheet.dart';
import '../settings/native_bars.dart';
import 'doc_pages.dart';
import 'image_viewer.dart';
import 'paged_view.dart';
import 'pdf_pages.dart';
import 'reader_menu.dart';
import 'reader_search.dart';
import 'sheet_parser.dart';
import 'sheet_view.dart';
import 'text_decode.dart';

/// Word / PowerPoint layout, read off the UI thread.
Future<OfficeLayout?> _officeJob(Uint8List bytes, bool slides) async {
  try {
    return await Isolate.run(() => readOfficeLayout(bytes, slides: slides));
  } catch (_) {
    return readOfficeLayout(bytes, slides: slides);
  }
}

/// PDF text for search, read off the UI thread: the text lines of every page with their place
/// on the page (for highlight boxes) when the file allows it, and the text of every page.
Future<(List<List<PdfTextLine>>?, List<String>)> _pdfTextJob(Uint8List bytes) async {
  (List<List<PdfTextLine>>?, List<String>) work() {
    List<List<PdfTextLine>>? lines;
    try {
      lines = readPdfTextLines(bytes);
    } catch (_) {
      lines = null;
    }
    if (lines != null && lines.any((page) => page.any((line) => line.readable))) {
      return (lines, [for (final page in lines) page.where((line) => line.readable).map((line) => line.text).join('\n')]);
    }
    try {
      return (null, readPdfPageTexts(bytes) ?? extractPdfPages(bytes));
    } catch (_) {
      return (null, <String>[]);
    }
  }

  try {
    return await Isolate.run(work);
  } catch (_) {
    return work();
  }
}

/// Every sheet of a spreadsheet, read off the UI thread (throws when unreadable).
Future<List<SheetData>> _sheetJob(Uint8List bytes, String name) async {
  try {
    return await Isolate.run(() => parseSpreadsheet(bytes, name));
  } catch (_) {
    return parseSpreadsheet(bytes, name);
  }
}

const _invertFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

/// The reader for PDF, Word, Excel, PowerPoint and TXT (pictures open [ImageViewerPage]),
/// like the Android ViewerActivity: page chip + Go to page, Vertical / Horizontal, Rotate,
/// Search, Invert, Share, ⋮ menu, convert, tap to hide the bars, page slider and zoom.
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.entry});

  final DocEntry entry;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late DocEntry _entry = widget.entry;
  bool _started = false;

  // content
  bool _loading = true;
  String? _errorKey;
  DocPaginator? _paginator;
  List<DocPage> _pages = const [];
  PdfPages? _pdf;
  List<String>? _pdfTexts;
  List<List<PdfTextLine>>? _pdfLines;
  final Map<int, String> _pdfFolded = {};
  final Map<int, List<String>> _pdfLineFolded = {};
  List<SheetData> _sheets = const [];
  int _sheet = 0;
  PageController? _sheetPager;
  final Map<int, GlobalKey<SheetGridState>> _gridKeys = {};
  final _paged = PagedController();
  final _contentKey = GlobalKey();
  int _pageCount = 0;
  int _layoutVersion = 0;

  // reading options
  bool _horizontal = false;
  bool _inverted = false;
  bool _chrome = true;
  bool _barsHidden = false;
  bool _swipeTip = false;
  bool _jumpTip = false;
  String? _pill;
  bool _pillShown = false;
  NDrawable _pillIcon = ND.icVertical;
  Timer? _pillTimer;

  // convert banner
  double? _convertProgress;
  DocEntry? _converted;

  // search
  bool _searching = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  int _searchGen = 0;
  bool _searchRunning = false;
  String _query = '';
  List<SearchHit> _hits = [];
  int _hit = 0;
  int _searchCursor = 0;
  bool _jumpedDuringSearch = false;
  Map<int, List<SearchHit>> _hitsByPage = {};
  final Map<int, String> _ocrText = {};
  bool _ocrStarted = false;

  bool get _isPdf => _entry.kind == DocKind.pdf;

  bool get _ready => !_loading && _errorKey == null;

  SearchHit? get _current => _hits.isEmpty ? null : _hits[_hit.clamp(0, _hits.length - 1)];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    for (final entry in scope.library.entries) {
      if (entry.id == _entry.id) {
        _entry = entry;
        break;
      }
    }
    if (_started) return;
    _started = true;
    if (_entry.kind == DocKind.image) return;
    _load(scope.library.fileOf(_entry));
  }

  @override
  void dispose() {
    _searchGen++;
    _debounce?.cancel();
    _pillTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _paged.dispose();
    _sheetPager?.dispose();
    final pdf = _pdf;
    if (pdf != null) {
      pdf.sizesVersion.removeListener(_onPdfSizes);
      pdf.close();
    }
    if (_barsHidden) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  // ------------------------------------------------------------------ loading

  Future<void> _load(File file) async {
    final name = _entry.name.toLowerCase();
    try {
      if (_entry.kind == DocKind.pdf) {
        await _loadPdf(file);
      } else if (_entry.kind == DocKind.excel || name.endsWith('.tsv')) {
        await _loadSheets(file);
      } else if (_entry.kind == DocKind.word || _entry.kind == DocKind.ppt) {
        await _loadOffice(file);
      } else {
        await _loadText(file);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorKey = _isPdf ? 'pdfProtected' : 'unsupportedFile';
      });
    }
  }

  Future<void> _loadPdf(File file) async {
    final pdf = PdfPages(file.path);
    await pdf.open();
    if (!mounted || pdf.pageCount == 0) {
      await pdf.close();
      if (mounted) throw const FormatException('No pages');
      return;
    }
    _pdf = pdf;
    pdf.sizesVersion.addListener(_onPdfSizes);
    setState(() {
      _loading = false;
      _pageCount = pdf.pageCount;
    });
    _afterOpen();
    pdf.loadSizes(() => mounted);
    final bytes = await file.readAsBytes();
    final (lines, texts) = await _pdfTextJob(bytes);
    if (!mounted) return;
    setState(() {
      _pdfLines = lines != null && lines.length == pdf.pageCount ? lines : null;
      _pdfTexts = [for (var i = 0; i < pdf.pageCount; i++) i < texts.length ? texts[i] : ''];
    });
    if (_searching) _startOcr();
  }

  void _onPdfSizes() {
    if (mounted) setState(() => _layoutVersion++);
  }

  Future<void> _loadOffice(File file) async {
    final bytes = await file.readAsBytes();
    final slides = _entry.kind == DocKind.ppt;
    if (!slides && bytes.length > 5 && bytes[0] == 0x7B && bytes[1] == 0x5C && bytes[2] == 0x72 && bytes[3] == 0x74 && bytes[4] == 0x66) {
      // .rtf: shown as text
      final text = rtfToText(latin1.decode(bytes, allowInvalid: true));
      if (!mounted) return;
      await _paginate(DocPaginator(blocks: textBlocks(text)));
      return;
    }
    final layout = await _officeJob(bytes, slides);
    if (!mounted) return;
    if (layout == null) throw const FormatException('Not an Office file');
    if (slides) {
      final pages = slidePages(layout);
      if (pages.isEmpty) throw const FormatException('No slides');
      setState(() {
        _pages = pages;
        _pageCount = pages.length;
        _loading = false;
      });
      _afterOpen();
    } else {
      await _paginate(DocPaginator.word(layout));
    }
  }

  Future<void> _loadText(File file) async {
    final bytes = await file.readAsBytes();
    if (_entry.kind != DocKind.txt) {
      final head = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
      if (head.contains(0)) throw const FormatException('Binary file');
    }
    final text = decodeTextBytes(bytes);
    if (!mounted) return;
    await _paginate(DocPaginator(blocks: textBlocks(text)));
  }

  Future<void> _loadSheets(File file) async {
    final bytes = await file.readAsBytes();
    if (isLegacyExcel(bytes)) throw const FormatException('Old .xls file');
    final sheets = await _sheetJob(bytes, _entry.name);
    if (!mounted) return;
    if (sheets.isEmpty) throw const FormatException('No sheets');
    setState(() {
      _sheets = sheets;
      _sheet = 0;
      _loading = false;
    });
  }

  /// Lays out a Word / TXT document a little at a time: the first pages show at once and the
  /// page count grows while the rest is laid out.
  Future<void> _paginate(DocPaginator paginator) async {
    _paginator = paginator;
    _pages = paginator.pages;
    var shown = false;
    final watch = Stopwatch()..start();
    while (mounted) {
      final more = paginator.layoutSome();
      final ready = paginator.readyPages;
      if (!shown && (ready >= 3 || !more)) {
        shown = true;
        watch.reset();
        setState(() {
          _loading = false;
          _pageCount = ready;
        });
        _afterOpen();
      } else if (shown && ready != _pageCount && (!more || watch.elapsedMilliseconds > 400)) {
        watch.reset();
        setState(() => _pageCount = ready);
      }
      if (!more) break;
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _afterOpen() {
    if (!mounted) return;
    final settings = AppScope.of(context).settings;
    final paginator = _paginator;
    final stillLaying = paginator != null && !paginator.complete;
    final many = _pageCount > 1 || stillLaying;
    if (!settings.pageTipSeen && many && _sheets.isEmpty) setState(() => _jumpTip = true);
  }

  // ------------------------------------------------------------------ bars, mode, rotate, invert

  void _toggleChrome() {
    if (_searching) return;
    setState(() {
      _chrome = !_chrome;
      if (!_chrome) _jumpTip = false;
    });
    _barsHidden = !_chrome;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: _chrome ? SystemUiOverlay.values : const [SystemUiOverlay.bottom],
    );
  }

  /// Dark pill under the toolbar that fades out (250 ms) after 1.6 s.
  void _showPill(NDrawable icon, String text) {
    _pillTimer?.cancel();
    setState(() {
      _pill = text;
      _pillIcon = icon;
      _pillShown = true;
    });
    _pillTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _pillShown = false);
    });
  }

  void _toggleMode() {
    final s = S.of(context);
    final settings = AppScope.of(context).settings;
    final horizontal = !_horizontal;
    final firstTime = horizontal && !settings.horizontalHintSeen;
    if (_sheets.isNotEmpty) {
      if (horizontal) {
        _sheetPager = PageController(initialPage: _sheet);
      } else {
        final old = _sheetPager;
        _sheetPager = null;
        if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    setState(() {
      _horizontal = horizontal;
      if (firstTime) _swipeTip = true;
    });
    if (firstTime) settings.setFlag('horizontalHintSeen', true);
    _showPill(horizontal ? ND.icHorizontal : ND.icVertical, s.t(horizontal ? 'pageByPage' : 'continuousPages'));
  }

  Future<void> _rotate() async {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    await SystemChrome.setPreferredOrientations(
      portrait ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp],
    );
  }

  void _toggleInvert() {
    final s = S.of(context);
    setState(() => _inverted = !_inverted);
    _showPill(ND.icInvert, s.t(_inverted ? 'colorInversionOn' : 'colorInversionOff'));
  }

  // ------------------------------------------------------------------ page chip / go to page

  void _dismissJumpTip() {
    setState(() => _jumpTip = false);
    AppScope.of(context).settings.setFlag('pageTipSeen', true);
  }

  Future<void> _goToPage() async {
    final s = S.of(context);
    final settings = AppScope.of(context).settings;
    final total = _pageCount;
    if (total <= 0) return;
    if (_jumpTip || !settings.pageTipSeen) {
      setState(() => _jumpTip = false);
      settings.setFlag('pageTipSeen', true);
    }
    final controller = TextEditingController(text: '${_paged.page + 1}');
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    // FileSheets.askNumber (sheet_number_input.xml) as a bottom sheet
    final value = await showAppSheet<int>(
      context,
      builder: (sheetContext) => _NumberSheet(
        title: s.t('goToPage'),
        controller: controller,
        min: 1,
        max: total,
        cancel: s.t('cancel'),
        ok: s.t('ok'),
      ),
    );
    // the dialog still draws the field while it closes
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (value == null || !mounted) return;
    if (_searchRunning) _jumpedDuringSearch = true;
    FocusManager.instance.primaryFocus?.unfocus();
    _paged.jumpTo(value - 1);
  }

  // ------------------------------------------------------------------ search

  String _searchHint(S s) {
    if (_entry.name.toLowerCase().endsWith('.tsv')) return s.t('searchInExcel');
    return switch (_entry.kind) {
      DocKind.pdf => s.t('searchInPdf'),
      DocKind.ppt => s.t('searchInPpt'),
      DocKind.excel => s.t('searchInExcel'),
      DocKind.txt => s.t('searchInTxt'),
      _ => s.t('searchInDocument'),
    };
  }

  void _openSearch() {
    if (!_ready) return;
    setState(() {
      _searching = true;
      _chrome = true;
      _jumpTip = false;
    });
    if (_barsHidden) {
      _barsHidden = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    _startOcr();
  }

  void _closeSearch() {
    _debounce?.cancel();
    _searchGen++;
    _search.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searching = false;
      _searchRunning = false;
      _query = '';
      _hits = [];
      _hit = 0;
      _hitsByPage = {};
    });
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _jumpedDuringSearch = false;
    _debounce = Timer(const Duration(milliseconds: 450), _runSearch);
  }

  int _searchablePages() {
    if (_sheets.isNotEmpty) return _sheets.length;
    if (_pdf != null) return _pdfTexts?.length ?? 0;
    final paginator = _paginator;
    if (paginator != null) return paginator.readyPages;
    return _pages.length;
  }

  bool _searchComplete() {
    if (_sheets.isNotEmpty) return true;
    if (_pdf != null) return _pdfTexts != null;
    return _paginator?.complete ?? true;
  }

  List<SearchHit> _ocrHits(int page, String query) {
    final text = _ocrText[page];
    if (text == null || text.isEmpty) return const [];
    return [for (final match in findMatches(foldForSearch(text), query)) SearchHit(page, -2, match.$1, match.$2)];
  }

  List<SearchHit> _findOnPage(int page, String query) {
    final hits = <SearchHit>[];
    if (_sheets.isNotEmpty) {
      final sheet = _sheets[page];
      final keys = sheet.cells.keys.toList()..sort();
      for (final key in keys) {
        for (final match in findMatches(foldForSearch(sheet.cells[key] ?? ''), query)) {
          hits.add(SearchHit(page, key, match.$1, match.$2));
        }
      }
      return hits;
    }
    final texts = _pdfTexts;
    final lines = _pdfLines;
    if (_pdf != null) {
      if (lines != null && page < lines.length) {
        final folded = _pdfLineFolded[page] ??= [
          for (final line in lines[page]) line.readable ? foldForSearch(line.text) : '',
        ];
        for (var i = 0; i < folded.length; i++) {
          for (final match in findMatches(folded[i], query)) {
            hits.add(SearchHit(page, i, match.$1, match.$2));
          }
        }
      } else if (texts != null && page < texts.length) {
        final folded = _pdfFolded[page] ??= foldForSearch(texts[page]);
        for (final match in findMatches(folded, query)) {
          hits.add(SearchHit(page, -1, match.$1, match.$2));
        }
      }
    } else if (page < _pages.length) {
      final items = _pages[page].items;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item is! TextItem || item.decor) continue;
        for (final match in findMatches(item.folded, query)) {
          hits.add(SearchHit(page, i, match.$1, match.$2));
        }
      }
    }
    hits.addAll(_ocrHits(page, query));
    return hits;
  }

  void _indexHits() {
    final map = <int, List<SearchHit>>{};
    for (final hit in _hits) {
      (map[hit.page] ??= <SearchHit>[]).add(hit);
    }
    _hitsByPage = map;
  }

  /// Shows the results found so far; the first time, jumps to the first match (from the page
  /// the user went to while searching, if they did). Returns whether a match is on screen.
  bool _pushHits(bool shown) {
    if (_hits.isEmpty) return shown;
    if (shown) {
      setState(_indexHits);
      return true;
    }
    final from = _jumpedDuringSearch ? (_sheets.isNotEmpty ? _sheet : _paged.page) : 0;
    final index = _hits.indexWhere((hit) => hit.page >= from);
    if (index < 0 && from > 0) {
      setState(_indexHits);
      return false;
    }
    setState(() {
      _hit = index < 0 ? 0 : index;
      _indexHits();
    });
    _showHit();
    return true;
  }

  /// Finds every match (in the background of the page drawing): results appear while it runs,
  /// the count grows ("3/12…"), and pages still being laid out are searched when ready.
  Future<void> _runSearch() async {
    _debounce?.cancel();
    final gen = ++_searchGen;
    final query = foldQuery(_search.text);
    setState(() {
      _query = query;
      _hits = [];
      _hit = 0;
      _hitsByPage = {};
      _searchCursor = 0;
      _searchRunning = query.isNotEmpty;
    });
    if (query.isEmpty) return;
    var shown = false;
    var pushed = 0;
    final watch = Stopwatch()..start();
    var page = 0;
    while (true) {
      if (!mounted || gen != _searchGen) return;
      if (page >= _searchablePages()) {
        if (_searchComplete()) break;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        continue;
      }
      _hits.addAll(_findOnPage(page, query));
      page++;
      _searchCursor = page;
      if (_hits.length != pushed && (!shown || watch.elapsedMilliseconds > 300)) {
        pushed = _hits.length;
        watch.reset();
        shown = _pushHits(shown);
      }
      if (page % 8 == 0) await Future<void>.delayed(Duration.zero);
    }
    if (!mounted || gen != _searchGen) return;
    _searchCursor = 1 << 30;
    setState(() {
      _searchRunning = false;
      _indexHits();
    });
    _jumpedDuringSearch = false;
    if (_hits.isEmpty) {
      showToast(context, S.of(context).t('searchNoResults'));
    } else if (!shown) {
      _jumpedDuringSearch = false;
      _pushHits(false);
    }
  }

  void _step(int delta) {
    if (_hits.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _hit = (_hit + delta + _hits.length) % _hits.length);
    _showHit();
  }

  void _showHit() {
    final hit = _current;
    if (hit == null) return;
    if (_sheets.isNotEmpty) {
      if (_sheet != hit.page) {
        setState(() => _sheet = hit.page);
        final pager = _sheetPager;
        if (_horizontal && pager != null && pager.hasClients) pager.jumpToPage(hit.page);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _gridKey(hit.page).currentState?.revealCell(hit.item ~/ 100000, hit.item % 100000);
      });
      return;
    }
    final lines = _pdfLines;
    if (_pdf != null && lines != null && hit.item >= 0 && !_horizontal) {
      if (hit.page < lines.length && hit.item < lines[hit.page].length) {
        _paged.jumpTo(hit.page, fraction: lines[hit.page][hit.item].top, third: true);
        return;
      }
    }
    if (hit.item >= 0 && hit.page < _pages.length && !_horizontal) {
      final page = _pages[hit.page];
      if (hit.item < page.items.length) {
        final item = page.items[hit.item];
        if (item is TextItem) {
          final top = matchTop(item, hit.start, hit.end);
          _paged.jumpTo(hit.page, fraction: top / page.height, third: true);
          return;
        }
      }
    }
    _paged.jumpTo(hit.page);
  }

  String _countLabel() {
    if (_query.isEmpty) return '';
    if (_hits.isEmpty) return _searchRunning ? '…' : '0/0';
    return '${_hit.clamp(0, _hits.length - 1) + 1}/${_hits.length}${_searchRunning ? '…' : ''}';
  }

  Map<int, List<(int, int, bool)>> _marksFor(int page) {
    final list = _hitsByPage[page];
    if (list == null || list.isEmpty) return const {};
    final current = _current;
    final marks = <int, List<(int, int, bool)>>{};
    for (final hit in list) {
      if (hit.item < 0) continue;
      (marks[hit.item] ??= <(int, int, bool)>[]).add((hit.start, hit.end, identical(hit, current)));
    }
    return marks;
  }

  /// Highlight boxes on a PDF page (fractions of the page), from the text line positions.
  List<(Rect, bool)> _pdfBoxes(int page) {
    final lines = _pdfLines;
    final list = _hitsByPage[page];
    if (lines == null || list == null || page >= lines.length) return const [];
    final current = _current;
    final boxes = <(Rect, bool)>[];
    for (final hit in list) {
      if (hit.item < 0 || hit.item >= lines[page].length) continue;
      final line = lines[page][hit.item];
      final length = line.text.length;
      if (length == 0) continue;
      final width = line.right - line.left;
      final left = line.left + width * hit.start / length;
      final right = line.left + width * hit.end / length;
      boxes.add((Rect.fromLTRB(left, line.top, right, line.bottom), identical(hit, current)));
    }
    return boxes;
  }

  Set<int> _sheetMarks(int sheet) => {for (final hit in _hitsByPage[sheet] ?? const <SearchHit>[]) hit.item};

  int? _sheetCurrent(int sheet) {
    final current = _current;
    return current != null && current.page == sheet ? current.item : null;
  }

  // ------------------------------------------------------------------ text inside pictures

  /// Reads the words in pictures (scanned PDF pages without text, picture pages in Word /
  /// PowerPoint, also in documents that mix text and picture pages) so search finds them.
  void _startOcr() {
    if (_ocrStarted || !_ready) return;
    final scope = AppScope.of(context);
    final languageTag = scope.settings.languageTag;
    if (_pdf != null) {
      if (_pdfTexts == null) return;
      _ocrStarted = true;
      _ocrPdf(scope.library.fileOf(_entry).path, languageTag);
    } else if (_sheets.isEmpty) {
      _ocrStarted = true;
      _ocrDoc(languageTag);
    }
  }

  Future<void> _ocrPdf(String path, String languageTag) async {
    final texts = _pdfTexts;
    if (texts == null) return;
    final missing = [
      for (var i = 0; i < texts.length; i++)
        if (texts[i].trim().isEmpty) i + 1,
    ];
    if (missing.isEmpty) return;
    try {
      await ocrPdfPages(
        path,
        languageTag: languageTag,
        onlyPages: missing,
        isCancelled: () => !mounted,
        onText: (number, text) {
          if (!mounted || text.trim().isEmpty) return;
          _ocrText[number - 1] = text;
          _onOcrPage(number - 1);
        },
      );
    } catch (_) {
      // reading pictures is optional: search still works on the text layer
    }
  }

  Future<void> _ocrDoc(String languageTag) async {
    var p = 0;
    while (mounted) {
      if (p >= _searchablePages()) {
        if (_searchComplete()) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        continue;
      }
      final page = _pages[p];
      final area = page.width * page.height;
      final buffer = StringBuffer();
      for (final item in page.items) {
        if (item is! ImageItem) continue;
        if (item.rect.width * item.rect.height < area * 0.12) continue;
        final text = await ocrImageBytes(item.bytes, languageTag: languageTag);
        if (!mounted) return;
        if (text.isNotEmpty) buffer.writeln(text);
      }
      if (buffer.isNotEmpty) {
        _ocrText[p] = buffer.toString();
        _onOcrPage(p);
      }
      p++;
    }
  }

  /// Text was read from a page's pictures after the running search had passed that page.
  void _onOcrPage(int page) {
    if (!mounted || _query.isEmpty || page >= _searchCursor) return;
    final extra = _ocrHits(page, _query);
    if (extra.isEmpty) return;
    final current = _current;
    setState(() {
      _hits = [..._hits, ...extra]..sort((a, b) => a.compareTo(b));
      _hit = current == null ? 0 : _hits.indexOf(current);
      if (_hit < 0) _hit = 0;
      _indexHits();
    });
    if (current == null) _showHit();
  }

  // ------------------------------------------------------------------ actions

  Future<void> _convert() async {
    if (_isPdf) {
      await convertPdfToWord(context, entry: _entry);
      return;
    }
    if (_convertProgress != null && _converted == null) return;
    final s = S.of(context);
    final library = AppScope.of(context).library;
    final path = library.fileOf(_entry).path;
    final name = _entry.name;
    setState(() {
      _convertProgress = 0;
      _converted = null;
    });
    DocEntry? saved;
    try {
      final bytes = await officeFileToPdf(
        path,
        onProgress: (progress) {
          if (mounted) setState(() => _convertProgress = progress.clamp(0.0, 1.0));
        },
      );
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      saved = await library.importBytes(bytes, name: '$stem.pdf', folder: 'convert');
    } catch (_) {
      saved = null;
    }
    if (!mounted) return;
    if (saved == null) {
      setState(() => _convertProgress = null);
      showToast(context, s.t('convertFailed'));
      return;
    }
    setState(() {
      _convertProgress = 1;
      _converted = saved;
    });
  }

  void _closeBanner() {
    setState(() {
      _convertProgress = null;
      _converted = null;
    });
  }

  Future<void> _openConverted() async {
    final entry = _converted;
    _closeBanner();
    if (entry != null) await openEntry(context, entry);
  }

  Future<void> _print() async {
    final scope = AppScope.of(context);
    final file = scope.library.fileOf(_entry);
    final name = _entry.name;
    final bytes = await file.readAsBytes();
    // the system print screen is not "leaving the app": no Welcome back after it
    scope.guard.arm(scope.settings);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
  }

  Future<void> _menu() {
    final isPdf = _isPdf;
    return showReaderMenu(
      context,
      entry: _entry,
      onDeleted: () {
        if (mounted) Navigator.of(context).pop();
      },
      onPages: isPdf ? () => openManagePages(context, entry: _entry) : null,
      onPrint: isPdf ? _print : null,
      onMerge: isPdf ? () => openMerge(context, entry: _entry) : null,
      onSplit: isPdf ? () => openSplit(context, entry: _entry) : null,
    );
  }

  Future<void> _pdfTools() async {
    final s = S.of(context);
    Widget row(BuildContext sheet, NDrawable icon, String label, VoidCallback onTap) {
      final nc = NC.of(sheet);
      return InkWell(
        onTap: () {
          Navigator.pop(sheet);
          onTap();
        },
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 20, end: 16),
            child: Row(
              children: [
                NativeIcon(icon, size: 24),
                const SizedBox(width: 16),
                Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: nc.textPrimary))),
              ],
            ),
          ),
        ),
      );
    }

    await showAppSheet<void>(
      context,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row(sheet, ND.icEtEditText, s.t('editText'), () => openMarkup(context, entry: _entry, tool: MarkTool.text)),
            row(sheet, ND.icEtAnnotate, s.t('annotate'), () => openMarkup(context, entry: _entry)),
            row(sheet, ND.icEtAddText, s.t('addText'), () => openMarkup(context, entry: _entry, tool: MarkTool.text)),
            row(sheet, ND.icEtSign, s.t('sign'), () => openMarkup(context, entry: _entry, tool: MarkTool.sign)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  GlobalKey<SheetGridState> _gridKey(int index) => _gridKeys.putIfAbsent(index, () => GlobalKey<SheetGridState>());

  Widget _grid(S s, int index) {
    return SheetGrid(
      key: _gridKey(index),
      sheet: _sheets[index],
      emptyLabel: s.t('emptySheet'),
      marks: _sheetMarks(index),
      current: _sheetCurrent(index),
      onTap: _toggleChrome,
    );
  }

  void _selectSheet(int index) {
    setState(() => _sheet = index);
    final pager = _sheetPager;
    if (_horizontal && pager != null && pager.hasClients) pager.jumpToPage(index);
  }

  /// Sheet tabs of a workbook (not in the Android app, which shows sheets as pages): a 40dp
  /// strip on @color/surface, the chosen sheet in the Excel colour.
  Widget _sheetTabs(NC nc) {
    return Material(
      color: nc.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 1, color: nc.divider),
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _sheets.length,
              itemBuilder: (context, index) {
                final selected = index == _sheet;
                final name = _sheets[index].name.isEmpty ? 'Sheet${index + 1}' : _sheets[index].name;
                return InkWell(
                  onTap: () => _selectSheet(index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? nc.surfaceVariant : null,
                      border: Border(top: BorderSide(color: selected ? nc.typeExcel : Colors.transparent, width: 2.5)),
                    ),
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                        color: selected ? nc.typeExcel : nc.textPrimary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetBody(S s, NC nc) {
    final tabs = _sheets.length > 1 || _sheets.first.name.isNotEmpty;
    final Widget grid;
    if (_horizontal) {
      grid = PageView.builder(
        controller: _sheetPager,
        itemCount: _sheets.length,
        onPageChanged: (index) => setState(() => _sheet = index),
        itemBuilder: (context, index) => _grid(s, index),
      );
    } else {
      grid = _grid(s, _sheet.clamp(0, _sheets.length - 1));
    }
    return Column(
      children: [
        Expanded(child: grid),
        if (tabs) _sheetTabs(nc),
      ],
    );
  }

  Widget _content(S s, NC nc) {
    if (_loading) {
      // activity_viewer.xml #loading: @color/surface, 36dp spinner, "Loading…" 14sp bold
      return ColoredBox(
        color: nc.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3.5, color: nc.primary),
              ),
              const SizedBox(height: 8),
              Text(s.t('loading'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: nc.textPrimary)),
            ],
          ),
        ),
      );
    }
    final error = _errorKey;
    if (error != null) {
      return ColoredBox(
        color: nc.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(s.t(error), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
          ),
        ),
      );
    }
    if (_sheets.isNotEmpty) return _sheetBody(s, nc);
    final pdf = _pdf;
    return PagedView(
      controller: _paged,
      count: _pageCount,
      aspectOf: pdf != null
          ? pdf.aspectOf
          : (index) => index < _pages.length && _pages[index].width > 0 ? _pages[index].height / _pages[index].width : 1.414,
      itemBuilder: (context, index) {
        if (pdf != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              PdfPageTile(pages: pdf, index: index),
              IgnorePointer(child: CustomPaint(painter: PdfHitPainter(_pdfBoxes(index)))),
            ],
          );
        }
        return DocPageView(page: _pages[index], marks: _marksFor(index));
      },
      horizontal: _horizontal,
      onTap: _toggleChrome,
      bottomGap: _isPdf && _chrome && !_searching ? 16 + 52 + 8 : 6,
      layoutVersion: _layoutVersion,
    );
  }

  /// activity_viewer.xml #normalBar: back, the name (18sp bold, middle ellipsis), convert
  /// (ic_convert_word for PDF, ic_convert_pdf otherwise), Pages (PDF), ⋮.
  Widget _topBar(S s, NC nc) {
    final converting = _convertProgress != null && _converted == null;
    return Row(
      children: [
        const NativeBackButton(),
        Expanded(
          child: MiddleEllipsisText(
            _entry.name,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary),
          ),
        ),
        if (_ready && _isPdf)
          NativeIconButton(icon: ND.icConvertWord, tint: nc.textPrimary, tooltip: s.t('pdfToWord'), onTap: _convert),
        if (_ready && !_isPdf)
          NativeIconButton(
            icon: ND.icConvertPdf,
            tint: nc.textPrimary,
            tooltip: s.t('convertToPdf'),
            onTap: converting ? null : _convert,
          ),
        if (_ready && _isPdf)
          NativeIconButton(
            icon: ND.icPages,
            tint: nc.textPrimary,
            tooltip: s.t('pagesMenu'),
            onTap: () => openManagePages(context, entry: _entry),
          ),
        NativeIconButton(icon: ND.icMoreVert, tint: nc.textPrimary, onTap: _menu),
      ],
    );
  }

  /// activity_viewer.xml #searchBar: back, the 40dp field (bg_search_field), "3/12", ▲ ▼.
  Widget _searchBar(S s, NC nc) {
    return Row(
      children: [
        NativeBackButton(onTap: _closeSearch),
        Expanded(
          child: Container(
            height: 40,
            decoration: NS.bgSearchField(context),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: AlignmentDirectional.centerStart,
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              maxLines: 1,
              textInputAction: TextInputAction.search,
              onChanged: (_) => _scheduleSearch(),
              onSubmitted: (_) {
                _jumpedDuringSearch = false;
                _runSearch();
              },
              cursorColor: nc.primary,
              style: TextStyle(fontSize: 15, color: nc.textPrimary),
              decoration: InputDecoration(
                hintText: _searchHint(s),
                hintStyle: TextStyle(fontSize: 15, color: nc.textHint),
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 40),
          child: Text(
            _countLabel(),
            textAlign: TextAlign.center,
            style: TextStyle(color: nc.textSecondary, fontSize: 13),
          ),
        ),
        NativeIconButton(
          icon: ND.icArrowUp,
          size: 40,
          tint: nc.textPrimary,
          onTap: _hits.isEmpty ? null : () => _step(-1),
        ),
        NativeIconButton(
          icon: ND.icArrowDown,
          size: 40,
          tint: nc.textPrimary,
          onTap: _hits.isEmpty ? null : () => _step(1),
        ),
      ],
    );
  }

  /// item_bottom_tool.xml: 22dp icon + 12sp label (marginTop 3dp), tint @color/tool_tint
  /// (selected = primary, disabled = #C3C8D0, else text_primary), borderless ripple.
  Widget _tool(NC nc, NDrawable icon, String label, VoidCallback? onTap, {bool selected = false}) {
    final color = onTap == null ? const Color(0xFFC3C8D0) : (selected ? nc.primary : nc.textPrimary);
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        containedInkWell: false,
        radius: 36,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            NativeIcon(icon, size: 22, tint: color),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(S s, NC nc) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final enabled = _ready;
    return Material(
      color: nc.surface,
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            _tool(
              nc,
              _horizontal ? ND.icHorizontal : ND.icVertical,
              s.t(_horizontal ? 'horizontal' : 'vertical'),
              enabled ? _toggleMode : null,
            ),
            _tool(nc, ND.icRotate, s.t('rotate'), _rotate, selected: landscape),
            _tool(nc, ND.icSearchText, s.t('search'), enabled ? _openSearch : null),
            _tool(nc, ND.icInvert, s.t('invert'), _toggleInvert, selected: _inverted),
            _tool(nc, ND.icShare, s.t('share'), () => shareEntry(context, _entry)),
          ],
        ),
      ),
    );
  }

  /// "Converting… N%" / "Saved successfully [Open] ✕" (activity_viewer.xml #banner, bg_banner).
  Widget _banner(S s, NC nc) {
    final done = _converted != null;
    final percent = ((_convertProgress ?? 0) * 100).round();
    return Material(
      color: nc.surfaceVariant,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
          child: Row(
            children: [
              if (done)
                const NativeIcon(ND.icCheckCircle, size: 22)
              else
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4, color: nc.primary),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  done ? s.t('savedSuccessfully') : s.t('convertingProgress', {'percent': '$percent'}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: nc.textPrimary, fontSize: 15),
                ),
              ),
              if (done)
                Material(
                  color: Colors.transparent,
                  shape: StadiumBorder(side: BorderSide(color: nc.primary, width: 1.2)),
                  clipBehavior: Clip.antiAlias,
                  child: Ink(
                    color: nc.surface,
                    child: InkWell(
                      onTap: _openConverted,
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.center,
                        child: Text(
                          s.t('open'),
                          style: TextStyle(color: nc.primary, fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                ),
              if (done)
                NativeIconButton(
                  icon: ND.icClose,
                  size: 36,
                  tint: nc.textSecondary,
                  tooltip: s.t('cancel'),
                  onTap: _closeBanner,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// tvPageChip: 28dp, bg_page_chip (#CC2B303A, 14dp corners), 13sp bold white.
  Widget _pageChip(S s) {
    return ListenableBuilder(
      listenable: _paged,
      builder: (context, _) {
        final total = _pageCount;
        final current = (_paged.page + 1).clamp(1, total < 1 ? 1 : total);
        final hit = _current;
        final flagged = _searching && hit != null && hit.item < 0 && hit.page == _paged.page;
        return Material(
          color: flagged ? const Color(0xFFE65100) : const Color(0xCC2B303A),
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _goToPage,
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              child: Text(
                s.t('ofPages', {'current': '$current', 'total': '$total'}),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
          ),
        );
      },
    );
  }

  /// jumpTip: 170dp bubble (bg_tip_bubble, elevation 6, padding 10dp) with OK (64×26dp).
  Widget _jumpTipCard(S s, NC nc) {
    return Material(
      color: nc.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('jumpTip'), style: TextStyle(color: nc.textPrimary, fontSize: 13)),
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _OutlinePill(label: s.t('ok'), width: 64, height: 26, fontSize: 13, onTap: _dismissJumpTip),
            ),
          ],
        ),
      ),
    );
  }

  /// tvTopPill: 36dp, bg_top_pill (#E6283040, 20dp corners), elevation 4, 18dp white icon,
  /// 14sp bold white text.
  Widget _pillView(String text) {
    return IgnorePointer(
      child: Center(
        child: AnimatedOpacity(
          opacity: _pillShown ? 1 : 0,
          duration: Duration(milliseconds: _pillShown ? 0 : 250),
          child: Material(
            color: const Color(0xE6283040),
            elevation: 4,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              height: 36,
              padding: const EdgeInsetsDirectional.only(start: 12, end: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NativeIcon(_pillIcon, size: 18, tint: Colors.white),
                  const SizedBox(width: 6),
                  Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// For results without a position on the page (PDF text, text read from pictures): the
  /// words around the match, since the page itself cannot be highlighted.
  Widget? _snippet(S s, NC nc) {
    final hit = _current;
    if (!_searching || hit == null || hit.item >= 0) return null;
    final texts = _pdfTexts;
    final String text;
    if (hit.item == -2) {
      text = _ocrText[hit.page] ?? '';
    } else {
      text = texts != null && hit.page < texts.length ? texts[hit.page] : '';
    }
    if (text.isEmpty || hit.end > text.length) return null;
    final (before, match, after) = snippetAround(text, hit.start, hit.end);
    return Material(
      color: nc.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('pages', {'count': '${hit.page + 1}'}),
              style: TextStyle(color: nc.textSecondary, fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: before),
                  TextSpan(
                    text: match,
                    style: TextStyle(backgroundColor: currentHitColor, fontWeight: FontWeight.w700, color: nc.textPrimary),
                  ),
                  TextSpan(text: after),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: nc.textPrimary, fontSize: 13, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_entry.kind == DocKind.image) return ImageViewerPage(entry: _entry);
    final s = S.of(context);
    final nc = NC.of(context);
    final paged = _ready && _sheets.isEmpty;
    final showFab = _isPdf && _ready && _chrome && !_searching;
    final showTop = _chrome || _searching;
    final pill = _pill;
    final snippet = _snippet(s, nc);
    final content = KeyedSubtree(key: _contentKey, child: _content(s, nc));
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _searching) _closeSearch();
      },
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: nc.surface,
            body: SafeArea(
              top: !showTop,
              child: Column(
                children: [
                  // 56dp top bar on @color/surface (Theme.DocReader.WhiteBar status bar)
                  if (showTop)
                    Material(
                      color: nc.surface,
                      child: SafeArea(
                        bottom: false,
                        left: false,
                        right: false,
                        child: SizedBox(
                          height: 56,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _searching ? _searchBar(s, nc) : _topBar(s, nc),
                          ),
                        ),
                      ),
                    ),
                  if (_convertProgress != null) _banner(s, nc),
                  Expanded(
                    // #content: @color/surface_variant (#1B1E24 while the colours are inverted)
                    child: ColoredBox(
                      color: _inverted ? const Color(0xFF1B1E24) : nc.surfaceVariant,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _inverted ? ColorFiltered(colorFilter: _invertFilter, child: content) : content,
                          ),
                          if (paged && _chrome && _pageCount > 0)
                            PositionedDirectional(start: 12, bottom: 12, child: _pageChip(s)),
                          if (paged && _chrome && _jumpTip && !_searching)
                            PositionedDirectional(start: 10, bottom: 48, width: 170, child: _jumpTipCard(s, nc)),
                          if (pill != null) Positioned(top: 12, left: 0, right: 0, child: _pillView(pill)),
                          if (snippet != null) PositionedDirectional(start: 12, end: 56, bottom: 50, child: snippet),
                          if (showFab)
                            PositionedDirectional(
                              end: 16,
                              bottom: 16,
                              // fabEdit: 52dp bg_fab_red, elevation 6, ic_pen white (padding 14dp)
                              child: Material(
                                color: nc.danger,
                                shape: const CircleBorder(),
                                elevation: 6,
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: _pdfTools,
                                  child: Tooltip(
                                    message: s.t('editPdf'),
                                    child: const SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: Center(child: NativeIcon(ND.icPen, size: 24, tint: Colors.white)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_chrome) _bottomBar(s, nc),
                  const BannerSlot(),
                ],
              ),
            ),
          ),
          if (_swipeTip) Positioned.fill(child: _SwipeTutorial(onDone: () => setState(() => _swipeTip = false))),
        ],
      ),
    );
  }
}

/// bg_outline_pill: @color/surface, 1.2dp primary stroke, 16dp corners; bold primary label.
class _OutlinePill extends StatelessWidget {
  const _OutlinePill({
    required this.label,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.onTap,
    this.large = false,
  });

  final String label;
  final double width;
  final double height;
  final double fontSize;
  final VoidCallback onTap;

  /// bg_outline_pill_large: 2dp stroke, 20dp corners.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(large ? 20 : 16),
      side: BorderSide(color: nc.primary, width: large ? 2 : 1.2),
    );
    return Material(
      color: nc.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: SizedBox(
          width: width,
          height: height,
          child: Center(
            child: Text(label, style: TextStyle(color: nc.primary, fontSize: fontSize, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }
}

/// Go to page (FileSheets.askNumber, sheet_number_input.xml): title, a 50dp field
/// (bg_rename_field) with a clear button, "1 – N" (red when out of range), Cancel / OK.
class _NumberSheet extends StatefulWidget {
  const _NumberSheet({
    required this.title,
    required this.controller,
    required this.min,
    required this.max,
    required this.cancel,
    required this.ok,
  });

  final String title;
  final TextEditingController controller;
  final int min;
  final int max;
  final String cancel;
  final String ok;

  @override
  State<_NumberSheet> createState() => _NumberSheetState();
}

class _NumberSheetState extends State<_NumberSheet> {
  bool _invalid = false;

  void _submit() {
    final number = int.tryParse(widget.controller.text.trim());
    if (number == null || number < widget.min || number > widget.max) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, number);
  }

  Widget _button(String label, Color background, Color foreground, VoidCallback onTap) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(label, style: TextStyle(color: foreground, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              widget.title,
              style: TextStyle(color: nc.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            height: 50,
            decoration: NS.bgRenameField(context),
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    autofocus: true,
                    maxLength: 5,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _submit(),
                    cursorColor: nc.primary,
                    style: TextStyle(fontSize: 15, color: nc.textPrimary),
                    decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, counterText: ''),
                  ),
                ),
                NativeIconButton(
                  icon: ND.icClose,
                  size: 36,
                  tint: nc.textSecondary,
                  onTap: () => widget.controller.clear(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.min} – ${widget.max}',
            style: TextStyle(fontSize: 12, color: _invalid ? nc.danger : nc.textSecondary),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _button(widget.cancel, nc.btnGray, nc.textPrimary, () => Navigator.pop(context))),
              const SizedBox(width: 16),
              Expanded(child: _button(widget.ok, nc.primary, Colors.white, _submit)),
            ],
          ),
        ],
      ),
    );
  }
}

/// First switch to Horizontal (view_swipe_tutorial.xml): "Swipe left/right to turn pages" with a
/// hand moving left and right under the arrows over the dimmed reader, and OK.
class _SwipeTutorial extends StatefulWidget {
  const _SwipeTutorial({required this.onDone});

  final VoidCallback onDone;

  @override
  State<_SwipeTutorial> createState() => _SwipeTutorialState();
}

class _SwipeTutorialState extends State<_SwipeTutorial> with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 180),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    _fade.dispose();
    super.dispose();
  }

  Future<void> _ok() async {
    _controller.stop();
    await _fade.reverse();
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    return FadeTransition(
      opacity: _fade,
      child: Material(
        color: const Color(0x99000000),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 220,
                    height: 152,
                    child: Stack(
                      children: [
                        const Positioned(
                          top: 0,
                          left: 0,
                          child: NativeIcon(ND.icSwipeArrows, width: 220, height: 80),
                        ),
                        Positioned(
                          top: 43,
                          left: (220 - 58) / 2,
                          child: AnimatedBuilder(
                            animation: _controller,
                            builder: (context, child) => Transform.translate(
                              offset: Offset((Curves.easeInOutSine.transform(_controller.value) * 2 - 1) * 34, 0),
                              child: child,
                            ),
                            child: Image.asset('assets/images/swipe_hand.png', width: 58, height: 86, fit: BoxFit.contain),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  NativeIcon(ND.icTipPointerUp, width: 22, height: 11, tint: nc.surface),
                  Container(
                    width: 280,
                    decoration: NS.bgTutorialCard(context),
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          s.t('swipePagesTip'),
                          style: TextStyle(color: nc.textPrimary, fontSize: 19, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: _OutlinePill(
                            label: s.t('ok'),
                            width: 116,
                            height: 40,
                            fontSize: 17,
                            large: true,
                            onTap: _ok,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
