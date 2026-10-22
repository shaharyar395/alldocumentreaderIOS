import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/office_layout.dart';
import 'reader_search.dart';

/// One laid-out page (Word / TXT) or slide (PowerPoint). Units are points; the page is drawn at
/// its own size and scaled to the screen, so line breaks never depend on the phone.
class DocPage {
  DocPage(this.width, this.height, {this.background = 0xFFFFFFFF});

  final double width;
  final double height;

  /// ARGB page colour.
  final int background;
  final List<PageItem> items = [];
}

sealed class PageItem {
  const PageItem(this.rect);

  final Rect rect;
}

class TextItem extends PageItem {
  TextItem(
    super.rect,
    this.runs, {
    this.align = TextAlign.start,
    this.rtl = false,
    this.lineSpacing = 1.0,
    this.shading,
    this.decor = false,
  }) : text = runs.map((run) => run.text).join();

  final List<OfficeRun> runs;
  final TextAlign align;
  final bool rtl;
  final double lineSpacing;
  final int? shading;

  /// Header / footer text repeated on every page (not searched).
  final bool decor;
  final String text;
  String? _folded;

  String get folded => _folded ??= foldForSearch(text);
}

class ImageItem extends PageItem {
  ImageItem(super.rect, this.bytes) : decodeWidth = _decodeWidth(bytes);

  final Uint8List bytes;

  /// Decode width limit (big page scans are decoded at 1600 px, like the Android app).
  final int? decodeWidth;

  static int? _decodeWidth(Uint8List bytes) {
    final size = imagePixelSize(bytes);
    if (size == null) return 1600;
    return size.$1 > 1600 ? 1600 : null;
  }
}

class BoxItem extends PageItem {
  const BoxItem(super.rect, {this.fill, this.border = true});

  final int? fill;
  final bool border;
}

/// Search highlights like the Android HighlightView: all matches #66FFD400, the current one #88FF8A00.
const hitColor = Color(0x66FFD400);
const currentHitColor = Color(0x88FF8A00);

TextAlign textAlignOf(RunAlign align) {
  return switch (align) {
    RunAlign.center => TextAlign.center,
    RunAlign.end => TextAlign.end,
    RunAlign.start => TextAlign.start,
  };
}

bool _within(int c, int low, int high) => c >= low && c <= high;

/// True when the first letter of [text] is Arabic, Hebrew, Persian, Urdu … (right to left).
bool looksRtl(String text) {
  for (final c in text.codeUnits) {
    if (_within(c, 0x0590, 0x08FF) || _within(c, 0xFB1D, 0xFDFF) || _within(c, 0xFE70, 0xFEFC)) return true;
    if (_within(c, 65, 90) || _within(c, 97, 122) || _within(c, 0x00C0, 0x024F) || _within(c, 0x0400, 0x04FF)) {
      return false;
    }
  }
  return false;
}

TextStyle runStyle(OfficeRun run, double lineSpacing, {Color? background}) {
  final highlight = run.highlight;
  final TextDecoration decoration;
  if (run.underline && run.strike) {
    decoration = TextDecoration.combine([TextDecoration.underline, TextDecoration.lineThrough]);
  } else if (run.underline) {
    decoration = TextDecoration.underline;
  } else if (run.strike) {
    decoration = TextDecoration.lineThrough;
  } else {
    decoration = TextDecoration.none;
  }
  return TextStyle(
    color: Color(0xFF000000 | (run.color ?? 0x000000)),
    fontSize: run.size <= 0 ? 11.0 : run.size,
    fontWeight: run.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
    decoration: decoration,
    height: 1.17 * lineSpacing,
    backgroundColor: background ?? (highlight == null ? null : Color(0xFF000000 | highlight)),
  );
}

/// The runs of one text item as a span; [marks] are (start, end, current) search highlights,
/// sorted and not overlapping. Highlights only change colours, never the layout.
TextSpan spanFor(List<OfficeRun> runs, double lineSpacing, [List<(int, int, bool)> marks = const []]) {
  if (runs.isEmpty) return const TextSpan(text: '');
  final children = <TextSpan>[];
  var offset = 0;
  for (final run in runs) {
    final style = runStyle(run, lineSpacing);
    final end = offset + run.text.length;
    var cursor = offset;
    for (final mark in marks) {
      final s = math.max(mark.$1, offset);
      final e = math.min(mark.$2, end);
      if (e <= s || s < cursor) continue;
      if (s > cursor) children.add(TextSpan(text: run.text.substring(cursor - offset, s - offset), style: style));
      children.add(TextSpan(
        text: run.text.substring(s - offset, e - offset),
        style: style.copyWith(backgroundColor: mark.$3 ? currentHitColor : hitColor),
      ));
      cursor = e;
    }
    if (cursor < end) children.add(TextSpan(text: run.text.substring(cursor - offset), style: style));
    offset = end;
  }
  // the root style only sets the line metrics (children would inherit a background colour)
  final first = runs.first;
  return TextSpan(
    style: TextStyle(
      color: const Color(0xFF000000),
      fontSize: first.size <= 0 ? 11.0 : first.size,
      height: 1.17 * lineSpacing,
    ),
    children: children,
  );
}

/// Measures text exactly as [DocPageView] draws it.
TextPainter layoutText(List<OfficeRun> runs, TextAlign align, bool rtl, double lineSpacing, double width) {
  final painter = TextPainter(
    text: spanFor(runs, lineSpacing),
    textAlign: align,
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  );
  painter.layout(maxWidth: math.max(width, 4.0));
  return painter;
}

/// Top of a match inside a text item, in page points (for scrolling it into view).
double matchTop(TextItem item, int start, int end) {
  final painter = layoutText(item.runs, item.align, item.rtl, item.lineSpacing, item.rect.width);
  try {
    final boxes = painter.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end));
    return item.rect.top + (boxes.isEmpty ? 0 : boxes.first.top);
  } finally {
    painter.dispose();
  }
}

double _emptyHeight(OfficeParagraph paragraph) {
  final size = paragraph.runs.isEmpty ? 11.0 : paragraph.runs.first.size;
  return (size <= 0 ? 11.0 : size) * 1.17 * paragraph.lineSpacing;
}

(List<OfficeRun>, List<OfficeRun>) _splitRuns(List<OfficeRun> runs, int cut) {
  final head = <OfficeRun>[];
  final tail = <OfficeRun>[];
  var offset = 0;
  for (final run in runs) {
    final end = offset + run.text.length;
    if (end <= cut) {
      head.add(run);
    } else if (offset >= cut) {
      tail.add(run);
    } else {
      head.add(run.withText(run.text.substring(0, cut - offset)));
      tail.add(run.withText(run.text.substring(cut - offset)));
    }
    offset = end;
  }
  return (head, tail);
}

/// Splits Word / TXT blocks into pages by measured height (not a fixed number of blocks per
/// page): paragraphs break between lines, table rows and pictures move to the next page when
/// they do not fit. Runs in small steps ([layoutSome]) so long documents show their first pages
/// at once while the rest is laid out.
class DocPaginator {
  DocPaginator({
    required this.blocks,
    this.width = 595,
    this.height = 842,
    double marginLeft = 54,
    double marginTop = 54,
    double marginRight = 54,
    double marginBottom = 54,
    double headerDistance = 30,
    double footerDistance = 30,
    List<OfficeParagraph> header = const [],
    List<OfficeParagraph> footer = const [],
  }) {
    _left = marginLeft.clamp(0.0, width / 3);
    final right = marginRight.clamp(0.0, width / 3);
    _contentWidth = math.max(72.0, width - _left - right);
    var top = marginTop.clamp(0.0, height / 3);
    var bottom = height - marginBottom.clamp(0.0, height / 3);

    // header and footer: the same text items on every page, in the top / bottom margins
    var y = headerDistance.clamp(0.0, height / 4);
    for (final paragraph in header) {
      final item = _measureItem(paragraph, paragraph.runs, _left, y, _contentWidth, decor: true);
      if (item == null) continue;
      _decor.add(item);
      y += item.rect.height;
    }
    if (_decor.isNotEmpty && y + 6 > top) top = math.min(y + 6, height / 2);
    final footerItems = <TextItem>[];
    var footerHeight = 0.0;
    for (final paragraph in footer) {
      final item = _measureItem(paragraph, paragraph.runs, _left, 0, _contentWidth, decor: true);
      if (item == null) continue;
      footerItems.add(item);
      footerHeight += item.rect.height;
    }
    if (footerItems.isNotEmpty) {
      var fy = height - footerDistance.clamp(0.0, height / 4) - footerHeight;
      for (final item in footerItems) {
        _decor.add(TextItem(
          Rect.fromLTWH(item.rect.left, fy, item.rect.width, item.rect.height),
          item.runs,
          align: item.align,
          rtl: item.rtl,
          lineSpacing: item.lineSpacing,
          decor: true,
        ));
        fy += item.rect.height;
      }
      final footerTop = height - footerDistance.clamp(0.0, height / 4) - footerHeight - 6;
      if (footerTop < bottom) bottom = math.max(footerTop, height / 2);
    }
    _top = top;
    _bottom = bottom;
    _newPage();
  }

  factory DocPaginator.word(OfficeLayout layout) {
    return DocPaginator(
      blocks: layout.blocks.isNotEmpty ? layout.blocks : [for (final p in layout.paragraphs) OfficeBlock.paragraph(p)],
      width: layout.pageWidth,
      height: layout.pageHeight,
      marginLeft: layout.marginLeft,
      marginTop: layout.marginTop,
      marginRight: layout.marginRight,
      marginBottom: layout.marginBottom,
      headerDistance: layout.headerDistance,
      footerDistance: layout.footerDistance,
      header: layout.header,
      footer: layout.footer,
    );
  }

  final List<OfficeBlock> blocks;
  final double width;
  final double height;
  final List<DocPage> pages = [];
  final List<TextItem> _decor = [];
  late final double _left;
  late final double _contentWidth;
  late final double _top;
  late final double _bottom;
  int _next = 0;
  double _y = 0;

  /// True once every block has been placed.
  bool complete = false;

  /// Pages that are finished (the page still being filled counts once everything is done).
  int get readyPages => complete ? pages.length : math.max(0, pages.length - 1);

  DocPage get _page => pages.last;

  bool get _atTop => _y <= _top + 0.5;

  void _newPage() {
    final page = DocPage(width, height);
    page.items.addAll(_decor);
    pages.add(page);
    _y = _top;
  }

  /// Lays out blocks for about [budgetMs] milliseconds; false when the document is done.
  bool layoutSome([int budgetMs = 10]) {
    if (complete) return false;
    final watch = Stopwatch()..start();
    while (_next < blocks.length && watch.elapsedMilliseconds < budgetMs) {
      final block = blocks[_next];
      final paragraph = block.paragraph;
      if (block.pageBreak) {
        if (_page.items.length > _decor.length || !_atTop) _newPage();
      } else if (block.image != null) {
        _addImage(block);
      } else if (block.rows.isNotEmpty) {
        _addTable(block);
      } else if (paragraph != null) {
        _addParagraph(paragraph);
      }
      _next++;
    }
    if (_next >= blocks.length) {
      if (pages.length > 1 && _page.items.length == _decor.length) pages.removeLast();
      complete = true;
    }
    return !complete;
  }

  TextItem? _measureItem(OfficeParagraph p, List<OfficeRun> runs, double x, double y, double w, {bool decor = false}) {
    final text = runs.map((run) => run.text).join();
    if (text.isEmpty) return null;
    final rtl = p.rtl || looksRtl(text);
    final align = textAlignOf(p.align);
    final painter = layoutText(runs, align, rtl, p.lineSpacing, w);
    final h = painter.height;
    painter.dispose();
    return TextItem(Rect.fromLTWH(x, y, w, h), runs, align: align, rtl: rtl, lineSpacing: p.lineSpacing, shading: p.shading, decor: decor);
  }

  void _addParagraph(OfficeParagraph p) {
    final indent = p.indent.clamp(0.0, _contentWidth * 0.6);
    final x = _left + indent;
    final w = _contentWidth - indent;
    if (!_atTop) _y += p.spaceBefore.clamp(0.0, 72.0);
    if (p.plain.isEmpty) {
      final h = _emptyHeight(p);
      if (_y + h > _bottom) {
        _newPage();
      } else {
        _y += h;
      }
      _y += p.spaceAfter.clamp(0.0, 72.0);
      return;
    }
    final align = textAlignOf(p.align);
    var runs = p.runs;
    final rtl = p.rtl || looksRtl(p.plain);
    var guard = 0;
    while (guard++ < 2000) {
      final painter = layoutText(runs, align, rtl, p.lineSpacing, w);
      final h = painter.height;
      final avail = _bottom - _y;
      if (h <= avail) {
        painter.dispose();
        _page.items.add(TextItem(Rect.fromLTWH(x, _y, w, h), runs, align: align, rtl: rtl, lineSpacing: p.lineSpacing, shading: p.shading));
        _y += h;
        break;
      }
      final lines = painter.computeLineMetrics();
      var k = 0;
      while (k < lines.length && lines[k].baseline + lines[k].descent <= avail) {
        k++;
      }
      if (k == 0) {
        if (!_atTop) {
          painter.dispose();
          _newPage();
          continue;
        }
        k = 1; // a single line taller than the page: place it anyway
      }
      if (k >= lines.length) {
        painter.dispose();
        _page.items.add(TextItem(Rect.fromLTWH(x, _y, w, h), runs, align: align, rtl: rtl, lineSpacing: p.lineSpacing, shading: p.shading));
        _y += h;
        break;
      }
      final total = runs.fold<int>(0, (sum, run) => sum + run.text.length);
      final line = lines[k];
      final pos = painter.getPositionForOffset(Offset(1, line.baseline - line.ascent + 1));
      final cut = painter.getLineBoundary(pos).start;
      final headHeight = lines[k - 1].baseline + lines[k - 1].descent;
      painter.dispose();
      if (cut <= 0 || cut >= total) {
        // cannot split here: the paragraph is clipped at the page end
        _page.items.add(TextItem(Rect.fromLTWH(x, _y, w, h), runs, align: align, rtl: rtl, lineSpacing: p.lineSpacing, shading: p.shading));
        _y = _bottom;
        break;
      }
      final (head, tail) = _splitRuns(runs, cut);
      _page.items.add(TextItem(Rect.fromLTWH(x, _y, w, headHeight), head, align: align, rtl: rtl, lineSpacing: p.lineSpacing, shading: p.shading));
      _newPage();
      runs = tail;
    }
    _y += p.spaceAfter.clamp(0.0, 72.0);
  }

  void _addImage(OfficeBlock block) {
    final bytes = block.image;
    if (bytes == null) return;
    var w = block.width;
    var h = block.height;
    if (w == null || h == null || w <= 0 || h <= 0) {
      final px = imagePixelSize(bytes);
      if (px == null) {
        w = _contentWidth;
        h = _contentWidth * 0.75;
      } else {
        w = px.$1 * 0.75;
        h = px.$2 * 0.75;
      }
    }
    final maxHeight = _bottom - _top;
    final scale = math.min(1.0, math.min(_contentWidth / w, maxHeight / h));
    w *= scale;
    h *= scale;
    if (_y + h > _bottom && !_atTop) _newPage();
    final x = switch (block.align) {
      RunAlign.center => _left + (_contentWidth - w) / 2,
      RunAlign.end => _left + _contentWidth - w,
      RunAlign.start => _left,
    };
    _page.items.add(ImageItem(Rect.fromLTWH(x, _y, w, h), bytes));
    _y += h + 4;
  }

  void _addTable(OfficeBlock block) {
    const pad = 3.0;
    for (var r = 0; r < block.rows.length; r++) {
      final row = block.rows[r];
      if (row.isEmpty) continue;
      var fractions = r < block.cellWidths.length && block.cellWidths[r].length == row.length
          ? block.cellWidths[r]
          : List<double>.filled(row.length, 1 / row.length);
      final sum = fractions.fold<double>(0, (a, b) => a + b);
      if (sum <= 0) fractions = List<double>.filled(row.length, 1 / row.length);
      final total = sum <= 0 ? 1.0 : sum;
      final widths = [for (final f in fractions) f / total * _contentWidth];
      final fills = r < block.cellFills.length ? block.cellFills[r] : const <int?>[];
      final measured = <List<(OfficeParagraph, double)>>[];
      var rowHeight = 0.0;
      for (var c = 0; c < row.length; c++) {
        final inner = math.max(8.0, widths[c] - 2 * pad);
        final list = <(OfficeParagraph, double)>[];
        var cellHeight = 0.0;
        for (final p in row[c]) {
          double ph;
          if (p.plain.isEmpty) {
            ph = _emptyHeight(p);
          } else {
            final painter = layoutText(p.runs, textAlignOf(p.align), p.rtl || looksRtl(p.plain), p.lineSpacing, inner);
            ph = painter.height;
            painter.dispose();
          }
          list.add((p, ph));
          cellHeight += ph + p.spaceAfter.clamp(0.0, 12.0);
        }
        measured.add(list);
        rowHeight = math.max(rowHeight, cellHeight);
      }
      rowHeight += 2 * pad;
      if (_y + rowHeight > _bottom && !_atTop) _newPage();
      var x = _left;
      for (var c = 0; c < row.length; c++) {
        _page.items.add(BoxItem(Rect.fromLTWH(x, _y, widths[c], rowHeight), fill: c < fills.length ? fills[c] : null));
        final inner = math.max(8.0, widths[c] - 2 * pad);
        var cy = _y + pad;
        for (final (p, ph) in measured[c]) {
          if (p.plain.isNotEmpty) {
            _page.items.add(TextItem(
              Rect.fromLTWH(x + pad, cy, inner, ph),
              p.runs,
              align: textAlignOf(p.align),
              rtl: p.rtl || looksRtl(p.plain),
              lineSpacing: p.lineSpacing,
              shading: p.shading,
            ));
          }
          cy += ph + p.spaceAfter.clamp(0.0, 12.0);
        }
        x += widths[c];
      }
      _y += rowHeight;
    }
    _y += 6;
  }
}

/// TXT files as blocks: lines in chunks (one text item per chunk keeps long files fast).
List<OfficeBlock> textBlocks(String text) {
  const linesPerBlock = 60;
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final blocks = <OfficeBlock>[];
  for (var i = 0; i < lines.length; i += linesPerBlock) {
    final end = math.min(i + linesPerBlock, lines.length);
    final chunk = lines.sublist(i, end).join('\n').replaceAll('\t', '    ');
    blocks.add(OfficeBlock.paragraph(OfficeParagraph([OfficeRun(chunk.isEmpty ? ' ' : chunk, size: 11)], lineSpacing: 1.1)));
  }
  if (blocks.isEmpty) blocks.add(const OfficeBlock.paragraph(OfficeParagraph([OfficeRun(' ', size: 11)])));
  return blocks;
}

/// PowerPoint slides as pages (one page per slide, at the slide's own size in points).
List<DocPage> slidePages(OfficeLayout layout) {
  final w = layout.slideWidth <= 0 ? 960.0 : layout.slideWidth;
  final h = layout.slideHeight <= 0 ? 540.0 : layout.slideHeight;
  final pages = <DocPage>[];
  for (final slide in layout.slides) {
    final page = DocPage(w, h, background: slide.background);
    for (final box in slide.boxes) {
      final rect = Rect.fromLTWH(box.left * w, box.top * h, box.width * w, box.height * h);
      final fill = box.fill;
      if (fill != null) page.items.add(BoxItem(rect, fill: fill, border: false));
      final image = box.image;
      if (image != null) {
        page.items.add(ImageItem(rect, image));
        continue;
      }
      if (box.table.isNotEmpty) {
        _slideTable(page, rect, box.table);
        continue;
      }
      final inner = Rect.fromLTRB(rect.left + 7.2, rect.top + 3.6, math.max(rect.left + 17.2, rect.right - 7.2), rect.bottom - 3.6);
      final measured = <(OfficeParagraph, double, bool, TextAlign)>[];
      var total = 0.0;
      for (final p in box.paragraphs) {
        final rtl = p.rtl || looksRtl(p.plain);
        final align = textAlignOf(p.align);
        double ph;
        if (p.plain.isEmpty) {
          ph = _emptyHeight(p);
        } else {
          final painter = layoutText(p.runs, align, rtl, p.lineSpacing, inner.width);
          ph = painter.height;
          painter.dispose();
        }
        measured.add((p, ph, rtl, align));
        total += ph + p.spaceAfter;
      }
      var y = switch (box.vAlign) {
        1 => inner.top + (inner.height - total) / 2,
        2 => inner.bottom - total,
        _ => inner.top,
      };
      if (y < inner.top) y = inner.top;
      for (final (p, ph, rtl, align) in measured) {
        if (p.plain.isNotEmpty) {
          page.items.add(TextItem(Rect.fromLTWH(inner.left, y, inner.width, ph), p.runs, align: align, rtl: rtl, lineSpacing: p.lineSpacing));
        }
        y += ph + p.spaceAfter;
      }
    }
    pages.add(page);
  }
  return pages;
}

void _slideTable(DocPage page, Rect rect, List<List<String>> rows) {
  final columns = rows.fold<int>(1, (max, row) => row.length > max ? row.length : max);
  final cellWidth = rect.width / columns;
  var y = rect.top;
  for (final row in rows) {
    final heights = <double>[];
    final runsList = <List<OfficeRun>>[];
    for (var c = 0; c < columns; c++) {
      final text = c < row.length ? row[c] : '';
      final runs = [OfficeRun(text, size: 12)];
      runsList.add(runs);
      if (text.isEmpty) {
        heights.add(14);
        continue;
      }
      final painter = layoutText(runs, TextAlign.start, looksRtl(text), 1, cellWidth - 8);
      heights.add(painter.height);
      painter.dispose();
    }
    final rowHeight = heights.fold<double>(14, math.max) + 8;
    for (var c = 0; c < columns; c++) {
      final cell = Rect.fromLTWH(rect.left + c * cellWidth, y, cellWidth, rowHeight);
      page.items.add(BoxItem(cell));
      if (runsList[c].first.text.isNotEmpty) {
        page.items.add(TextItem(Rect.fromLTWH(cell.left + 4, y + 4, cellWidth - 8, heights[c]), runsList[c], rtl: looksRtl(runsList[c].first.text)));
      }
    }
    y += rowHeight;
  }
}

/// Draws one [DocPage], scaled to the space it gets. [marks]: search highlights per item index.
class DocPageView extends StatelessWidget {
  const DocPageView({super.key, required this.page, this.marks = const {}});

  final DocPage page;
  final Map<int, List<(int, int, bool)>> marks;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: page.width,
        height: page.height,
        child: ClipRect(
          child: ColoredBox(
            color: Color(page.background),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (var i = 0; i < page.items.length; i++) _item(page.items[i], marks[i] ?? const []),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(PageItem item, List<(int, int, bool)> itemMarks) {
    return switch (item) {
      TextItem text => _text(text, itemMarks),
      ImageItem image => _image(image),
      BoxItem box => _box(box),
    };
  }

  Widget _text(TextItem item, List<(int, int, bool)> itemMarks) {
    final rect = item.rect;
    Widget text = RichText(
      text: spanFor(item.runs, item.lineSpacing, itemMarks),
      textAlign: item.align,
      textDirection: item.rtl ? TextDirection.rtl : TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      softWrap: true,
      overflow: TextOverflow.clip,
    );
    final shading = item.shading;
    if (shading != null) text = ColoredBox(color: Color(0xFF000000 | shading), child: text);
    return Positioned(left: rect.left, top: rect.top, width: rect.width, child: text);
  }

  Widget _image(ImageItem item) {
    return Positioned.fromRect(
      rect: item.rect,
      child: Image.memory(
        item.bytes,
        fit: BoxFit.fill,
        cacheWidth: item.decodeWidth,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _box(BoxItem item) {
    final fill = item.fill;
    return Positioned.fromRect(
      rect: item.rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill == null ? null : Color(0xFF000000 | fill),
          border: item.border ? Border.all(color: const Color(0xFF6B7280), width: 0.6) : null,
        ),
      ),
    );
  }
}
