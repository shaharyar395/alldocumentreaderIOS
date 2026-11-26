import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../features/reader/doc_pages.dart';
import '../features/reader/sheet_parser.dart';
import 'office_layout.dart';

/// Word, TXT or PowerPoint → PDF using the same pages the viewer draws, so line breaks and
/// pictures match the file on screen. Runs on the UI isolate (text measurement needs it).
Future<Uint8List> viewOfficeToPdf(
  String path, {
  required bool slides,
  void Function(double progress)? onProgress,
}) async {
  final bytes = await File(path).readAsBytes();
  onProgress?.call(0.04);
  final pages = await _pagesOf(path, bytes, slides: slides, onProgress: onProgress);
  if (pages.isEmpty) throw const FormatException('empty');
  return docPagesToPdf(pages, onProgress: (value) => onProgress?.call(0.45 + value * 0.54));
}

Future<List<DocPage>> _pagesOf(
  String path,
  Uint8List bytes, {
  required bool slides,
  void Function(double progress)? onProgress,
}) async {
  final lower = path.toLowerCase();
  if (slides) {
    final layout = readOfficeLayout(bytes, slides: true);
    if (layout == null || layout.slides.isEmpty) throw const FormatException('binary office');
    onProgress?.call(0.2);
    return slidePages(layout);
  }
  if (lower.endsWith('.txt') || lower.endsWith('.text') || lower.endsWith('.log') || lower.endsWith('.md')) {
    final paginator = DocPaginator(blocks: textBlocks(decodeTextBytes(bytes)));
    while (paginator.layoutSome(40)) {
      await Future<void>.delayed(Duration.zero);
    }
    onProgress?.call(0.4);
    return paginator.pages;
  }
  final layout = readOfficeLayout(bytes, slides: false);
  if (layout == null) throw const FormatException('binary office');
  final paginator = DocPaginator.word(layout);
  while (paginator.layoutSome(24)) {
    onProgress?.call(0.08 + (paginator.readyPages / math.max(1, paginator.pages.length)) * 0.32);
    await Future<void>.delayed(Duration.zero);
  }
  return paginator.pages;
}

/// One PDF page per laid-out page, the picture of that page filling it.
Future<Uint8List> docPagesToPdf(List<DocPage> pages, {void Function(double progress)? onProgress}) async {
  final doc = pw.Document(compress: true);
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final png = await _rasterize(page);
    final image = pw.MemoryImage(png);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(page.width, page.height),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(image, width: page.width, height: page.height, fit: pw.BoxFit.fill),
      ),
    );
    onProgress?.call((i + 1) / pages.length);
    await Future<void>.delayed(Duration.zero);
  }
  return doc.save();
}

Future<Uint8List> _rasterize(DocPage page) async {
  final scale = math.min(2.0, 1600 / math.max(page.width, page.height));
  final width = math.max(1, (page.width * scale).round());
  final height = math.max(1, (page.height * scale).round());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  canvas.drawRect(Rect.fromLTWH(0, 0, page.width, page.height), Paint()..color = Color(page.background));
  for (final item in page.items) {
    switch (item) {
      case BoxItem box:
        final fill = box.fill;
        if (fill != null) {
          canvas.drawRect(box.rect, Paint()..color = Color(0xFF000000 | fill));
        }
        if (box.border) {
          canvas.drawRect(
            box.rect,
            Paint()
              ..color = const Color(0xFF6B7280)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.6,
          );
        }
      case ImageItem image:
        final codec = await ui.instantiateImageCodec(image.bytes);
        final frame = await codec.getNextFrame();
        final bitmap = frame.image;
        canvas.drawImageRect(
          bitmap,
          Rect.fromLTWH(0, 0, bitmap.width.toDouble(), bitmap.height.toDouble()),
          image.rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
        bitmap.dispose();
        codec.dispose();
      case TextItem text:
        final shading = text.shading;
        if (shading != null) {
          canvas.drawRect(text.rect, Paint()..color = Color(0xFF000000 | shading));
        }
        final painter = layoutText(text.runs, text.align, text.rtl, text.lineSpacing, text.rect.width);
        painter.paint(canvas, text.rect.topLeft);
        painter.dispose();
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw const FormatException('page');
  return data.buffer.asUint8List();
}
