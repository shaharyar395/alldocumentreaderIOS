import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Renders PDF pages to pictures for the reader's page list (vertical list or page-by-page),
/// one page at a time on the document (pdfx / Android PdfRenderer allow only one open page).
/// Only page 1 is measured before the document shows; other page sizes follow in the background.
class PdfPages {
  PdfPages(this.path);

  final String path;
  PdfDocument? _doc;
  int pageCount = 0;
  Size defaultSize = const Size(595, 842);
  List<Size?> _sizes = const [];
  bool _closed = false;
  Future<void> _queue = Future<void>.value();
  final Map<int, Uint8List> _cache = {};
  final Map<int, int> _cacheWidth = {};
  final Map<int, Future<Uint8List?>> _pending = {};
  final Map<int, int> _wanted = {};

  /// Bumped when page sizes other than the first one are known (the page list re-measures).
  final ValueNotifier<int> sizesVersion = ValueNotifier<int>(0);

  Future<void> open() async {
    final doc = await PdfDocument.openFile(path);
    _doc = doc;
    pageCount = doc.pagesCount;
    _sizes = List<Size?>.filled(pageCount, null);
    if (pageCount == 0) return;
    final first = await _serial(() async {
      final page = await doc.getPage(1);
      try {
        return Size(page.width, page.height);
      } finally {
        await page.close();
      }
    });
    if (first != null && first.width > 0 && first.height > 0) {
      defaultSize = first;
      _sizes[0] = first;
    }
  }

  double aspectOf(int index) {
    final size = index >= 0 && index < _sizes.length ? (_sizes[index] ?? defaultSize) : defaultSize;
    if (size.width <= 0 || size.height <= 0) return 842 / 595;
    return size.height / size.width;
  }

  /// Reads the sizes of the other pages; [alive] stops it when the reader closes.
  Future<void> loadSizes(bool Function() alive) async {
    var changed = false;
    for (var i = 1; i < pageCount; i++) {
      if (_closed || !alive()) return;
      if (_sizes[i] != null) continue;
      final size = await _serial(() async {
        final doc = _doc;
        if (doc == null || _closed) return null;
        final page = await doc.getPage(i + 1);
        try {
          return Size(page.width, page.height);
        } finally {
          await page.close();
        }
      });
      if (_closed) return;
      if (size == null || size.width <= 0) {
        _sizes[i] = defaultSize;
        continue;
      }
      _sizes[i] = size;
      if ((size.height / size.width - defaultSize.height / defaultSize.width).abs() > 0.01) changed = true;
      if (changed && i % 25 == 0) {
        changed = false;
        sizesVersion.value++;
      }
    }
    if (changed && !_closed) sizesVersion.value++;
  }

  Uint8List? cached(int index) => _cache[index];

  /// A page widget shows / hides: only pages on screen are drawn when their turn comes.
  void want(int index, bool on) {
    if (on) {
      _wanted[index] = (_wanted[index] ?? 0) + 1;
    } else {
      final left = (_wanted[index] ?? 1) - 1;
      if (left <= 0) {
        _wanted.remove(index);
      } else {
        _wanted[index] = left;
      }
    }
  }

  /// The page as a JPEG [widthPx] wide (null when it could not be drawn or is no longer wanted).
  Future<Uint8List?> render(int index, int widthPx) {
    final have = _cache[index];
    if (have != null && (_cacheWidth[index] ?? 0) >= widthPx * 0.9) return Future<Uint8List?>.value(have);
    final running = _pending[index];
    if (running != null) return running;
    final future = _serial(() async {
      final doc = _doc;
      if (doc == null || _closed || !_wanted.containsKey(index)) return null;
      final page = await doc.getPage(index + 1);
      try {
        final width = widthPx.toDouble();
        final height = page.width <= 0 ? width * 1.414 : width * page.height / page.width;
        final image = await page.render(
          width: width,
          height: height,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
          quality: 92,
        );
        final bytes = image?.bytes;
        if (bytes != null) {
          _cache.remove(index);
          _cache[index] = bytes;
          _cacheWidth[index] = widthPx;
          while (_cache.length > 10) {
            final oldest = _cache.keys.first;
            _cache.remove(oldest);
            _cacheWidth.remove(oldest);
          }
        }
        return bytes;
      } finally {
        await page.close();
      }
    });
    _pending[index] = future;
    future.whenComplete(() {
      _pending.remove(index);
    });
    return future;
  }

  /// Runs [task] after every earlier one (errors become null).
  Future<T?> _serial<T>(Future<T?> Function() task) {
    final completer = Completer<T?>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await task());
      } catch (_) {
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    sizesVersion.dispose();
    await _serial<bool>(() async {
      await _doc?.close();
      _doc = null;
      return true;
    });
  }
}

/// One PDF page in the page list: drawn at 1.5× the screen pixels for sharp text, white while
/// it is being drawn.
class PdfPageTile extends StatefulWidget {
  const PdfPageTile({super.key, required this.pages, required this.index});

  final PdfPages pages;
  final int index;

  @override
  State<PdfPageTile> createState() => _PdfPageTileState();
}

class _PdfPageTileState extends State<PdfPageTile> {
  Uint8List? _bytes;
  int _requested = 0;

  @override
  void initState() {
    super.initState();
    widget.pages.want(widget.index, true);
    _bytes = widget.pages.cached(widget.index);
  }

  @override
  void didUpdateWidget(PdfPageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index || oldWidget.pages != widget.pages) {
      oldWidget.pages.want(oldWidget.index, false);
      widget.pages.want(widget.index, true);
      _bytes = widget.pages.cached(widget.index);
      _requested = 0;
    }
  }

  @override
  void dispose() {
    widget.pages.want(widget.index, false);
    super.dispose();
  }

  void _request(int width) {
    if (width <= _requested) return;
    _requested = width;
    final index = widget.index;
    widget.pages.render(index, width).then((bytes) {
      if (!mounted || bytes == null || widget.index != index) return;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        final want = (width * ratio * 1.5).clamp(400.0, 2400.0).round();
        _request(want);
        final bytes = _bytes;
        return ColoredBox(
          color: Colors.white,
          child: bytes == null
              ? const Center(
                  child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4)),
                )
              : Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true, width: double.infinity, height: double.infinity),
        );
      },
    );
  }
}

/// Search highlights over a PDF page: boxes as fractions of the page (0..1), the current
/// match orange, the others yellow.
class PdfHitPainter extends CustomPainter {
  PdfHitPainter(this.boxes);

  final List<(Rect, bool)> boxes;

  @override
  void paint(Canvas canvas, Size size) {
    if (boxes.isEmpty) return;
    // HighlightView: all matches #66FFD400, the current one #88FF8A00 with a 1.5dp #E65100
    // outline; boxes grow 1.5dp and have 1.5dp corners
    final hit = Paint()..color = const Color(0x66FFD400);
    final current = Paint()..color = const Color(0x88FF8A00);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFFE65100);
    const pad = 1.5;
    for (final (box, isCurrent) in boxes) {
      final rect = RRect.fromLTRBR(
        box.left * size.width - pad,
        box.top * size.height - pad,
        box.right * size.width + pad,
        box.bottom * size.height + pad,
        const Radius.circular(pad),
      );
      canvas.drawRRect(rect, isCurrent ? current : hit);
      if (isCurrent) canvas.drawRRect(rect, stroke);
    }
  }

  @override
  bool shouldRepaint(PdfHitPainter oldDelegate) => oldDelegate.boxes != boxes;
}
