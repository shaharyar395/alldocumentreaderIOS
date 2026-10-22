import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../native/native_colors.dart';

/// Page pictures of one PDF, drawn one after another in the background and kept.
class PdfThumbs {
  PdfThumbs(this.path, {this.width = 240});

  final String path;
  final double width;
  PdfDocument? _document;
  final Map<int, Uint8List> _cache = {};
  final Map<int, Future<Uint8List?>> _running = {};
  final Map<int, double> _aspect = {};
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  Uint8List? cached(int index) => _cache[index];

  /// Height / width of page [index] once it has been drawn.
  double? aspect(int index) => _aspect[index];

  Future<PdfDocument> _open() async {
    final open = _document;
    if (open != null) return open;
    final document = await PdfDocument.openFile(path);
    _document = document;
    return document;
  }

  Future<int> pageCount() {
    final completer = Completer<int>();
    _queue = _queue.then((_) async {
      try {
        completer.complete((await _open()).pagesCount);
      } catch (_) {
        completer.complete(0);
      }
    });
    return completer.future;
  }

  /// Picture of page [index] (0-based).
  Future<Uint8List?> page(int index) {
    final hit = _cache[index];
    if (hit != null) return Future.value(hit);
    return _running.putIfAbsent(index, () {
      final completer = Completer<Uint8List?>();
      _queue = _queue.then((_) async {
        if (_closed) {
          completer.complete(null);
          return;
        }
        try {
          final document = await _open();
          final page = await document.getPage(index + 1);
          final height = width * page.height / page.width;
          final image = await page.render(width: width, height: height, format: PdfPageImageFormat.jpeg, backgroundColor: '#FFFFFF', quality: 80);
          _aspect[index] = page.height / page.width;
          await page.close();
          if (image != null) _cache[index] = image.bytes;
          completer.complete(image?.bytes);
        } catch (_) {
          completer.complete(null);
        } finally {
          _running.remove(index);
        }
      });
      return completer.future;
    });
  }

  Future<void> close() async {
    _closed = true;
    final queue = _queue;
    await queue;
    await _document?.close();
    _document = null;
  }
}

/// One page picture from [thumbs], drawn when it is first shown.
class PdfThumbImage extends StatefulWidget {
  const PdfThumbImage({super.key, required this.thumbs, required this.index, this.rotate = 0, this.fit = BoxFit.contain});

  final PdfThumbs thumbs;
  final int index;

  /// Quarter turns (clockwise) shown on top of the page.
  final int rotate;
  final BoxFit fit;

  @override
  State<PdfThumbImage> createState() => _PdfThumbImageState();
}

class _PdfThumbImageState extends State<PdfThumbImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PdfThumbImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thumbs != widget.thumbs || oldWidget.index != widget.index) {
      _bytes = null;
      _load();
    }
  }

  void _load() {
    final cached = widget.thumbs.cached(widget.index);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    final thumbs = widget.thumbs;
    final index = widget.index;
    thumbs.page(index).then((bytes) {
      if (!mounted || thumbs != widget.thumbs || index != widget.index) return;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4, color: NC.of(context).textHint)));
    }
    final image = Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
    if (widget.rotate % 4 == 0) return image;
    return RotatedBox(quarterTurns: widget.rotate % 4, child: image);
  }
}
