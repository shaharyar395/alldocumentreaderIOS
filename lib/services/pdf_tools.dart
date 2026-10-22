import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdf/widgets.dart' as pw;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import 'platform_bridge.dart';

enum BlankStyle { blank, line, notebook, cornell, grid, graph }

Future<Uint8List> blankPdf({
  required int pages,
  BlankStyle style = BlankStyle.blank,
  PdfPageFormat format = PdfPageFormat.a4,
  PdfColor background = PdfColors.white,
}) async {
  final doc = pw.Document();
  for (var i = 0; i < pages; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Container(color: background, child: _paper(style, format)),
        ),
      ),
    );
  }
  return doc.save();
}

pw.Widget _paper(BlankStyle style, PdfPageFormat format) {
  if (style == BlankStyle.blank) return pw.SizedBox();
  final width = format.width;
  final height = format.height;
  if (style == BlankStyle.grid || style == BlankStyle.graph) {
    final step = style == BlankStyle.graph ? 18.0 : 36.0;
    return pw.Stack(
      children: [
        for (var x = 0.0; x < width; x += step)
          pw.Positioned(
            left: x,
            top: 0,
            bottom: 0,
            child: pw.Container(width: 0.4, color: PdfColors.blueGrey200),
          ),
        for (var y = 0.0; y < height; y += step)
          pw.Positioned(
            top: y,
            left: 0,
            right: 0,
            child: pw.Container(height: 0.4, color: PdfColors.blueGrey200),
          ),
      ],
    );
  }
  final left = style == BlankStyle.cornell ? width * 0.28 : (style == BlankStyle.notebook ? 56.0 : 28.0);
  return pw.Stack(
    children: [
      for (var y = 48.0; y < height - 36; y += 28)
        pw.Positioned(
          top: y,
          left: left,
          right: 24,
          child: pw.Container(height: 0.6, color: PdfColors.blue200),
        ),
      if (style == BlankStyle.notebook || style == BlankStyle.cornell)
        pw.Positioned(
          left: left - 10,
          top: 20,
          bottom: 20,
          child: pw.Container(width: 1.2, color: PdfColors.red300),
        ),
      if (style == BlankStyle.cornell)
        pw.Positioned(
          left: 20,
          right: 20,
          top: height * 0.82,
          child: pw.Container(height: 1.2, color: PdfColors.blueGrey400),
        ),
    ],
  );
}

/// One page per picture. With [fitPage] each page is shaped like its picture (long side = A4's
/// long side, picture edge to edge, like the Android app); otherwise the picture sits on an A4 page.
/// [onProgress] gets 0..1 while the pages are added and written.
Future<Uint8List> imagesToPdf(
  List<Uint8List> images, {
  bool fitPage = false,
  void Function(double progress)? onProgress,
}) async {
  final doc = pw.Document();
  for (var i = 0; i < images.length; i++) {
    final bytes = images[i];
    final memory = pw.MemoryImage(bytes);
    if (fitPage) {
      final width = (memory.width ?? 595).toDouble();
      final height = (memory.height ?? 842).toDouble();
      final scale = PdfPageFormat.a4.height / (width > height ? width : height);
      final format = PdfPageFormat(width * scale, height * scale);
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.FullPage(ignoreMargins: true, child: pw.Image(memory, fit: pw.BoxFit.fill)),
        ),
      );
    } else {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (context) => pw.Center(child: pw.Image(memory, fit: pw.BoxFit.contain)),
        ),
      );
    }
    onProgress?.call((i + 1) / images.length * 0.85);
    // let the progress pill repaint between pages
    await Future<void>.delayed(Duration.zero);
  }
  final saved = await doc.save();
  onProgress?.call(1);
  return saved;
}

Future<Uint8List> textToPdf(String text, {String? title}) async {
  final doc = pw.Document();
  final lines = text.split('\n');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (context) => [
        if (title != null && title.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 16),
            child: pw.Text(title, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          ),
        pw.Text(lines.join('\n'), style: const pw.TextStyle(fontSize: 12, lineSpacing: 4)),
      ],
    ),
  );
  return doc.save();
}

Future<Uint8List> rebuildPdf(List<PdfPiece> pieces) async {
  final doc = pw.Document();
  for (final piece in pieces) {
    if (piece.image != null) {
      final memory = pw.MemoryImage(piece.image!);
      final format = piece.pageFormat ?? PdfPageFormat.a4;
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Image(memory, fit: pw.BoxFit.fill),
        ),
      );
    } else {
      doc.addPage(
        pw.Page(
          pageFormat: piece.pageFormat ?? PdfPageFormat.a4,
          build: (context) => pw.SizedBox(),
        ),
      );
    }
  }
  return doc.save();
}

class PdfPiece {
  PdfPiece({this.image, this.pageFormat});
  final Uint8List? image;
  final PdfPageFormat? pageFormat;
}

/// One page of a new PDF made from existing PDFs: page [index] (0-based) of [src], turned by
/// [rotate] degrees (0, 90, 180, 270).
class SourcePage {
  const SourcePage(this.src, this.index, {this.rotate = 0});
  final String src;
  final int index;
  final int rotate;

  Map<String, Object> toMap() => {'src': src, 'index': index, 'rotate': rotate};
}

/// Builds a PDF from real pages of other PDFs — text, fonts and pictures are copied as they are
/// (no quality loss). Returns null when the native step is not available or fails, so callers can
/// fall back to the picture-based [rebuildPdf].
Future<Uint8List?> assemblePdf(List<SourcePage> parts) async {
  if (parts.isEmpty) return null;
  try {
    final dir = await getTemporaryDirectory();
    final out = p.join(dir.path, 'assemble_${DateTime.now().microsecondsSinceEpoch}.pdf');
    final ok = await PlatformBridge.assemblePdf(out, [for (final part in parts) part.toMap()]);
    if (!ok) return null;
    final file = File(out);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Writes [bytes] (e.g. a [blankPdf]) to a temporary PDF file and returns its path.
Future<String> tempPdf(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final out = File(p.join(dir.path, 'part_${DateTime.now().microsecondsSinceEpoch}.pdf'));
  await out.writeAsBytes(bytes, flush: true);
  return out.path;
}

/// Number of pages of the PDF at [path] (0 when it can't be opened).
Future<int> pdfPageCount(String path) async {
  try {
    final document = await PdfDocument.openFile(path);
    final count = document.pagesCount;
    await document.close();
    return count;
  } catch (_) {
    return 0;
  }
}

/// "Merged_20261015_1620" — the date/time names used by the Android app.
String stampName(String prefix) {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${prefix}_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
}

Future<Uint8List> mergePdfPaths(List<String> paths, void Function(double progress) onProgress) async {
  // real pages first (text stays text); pictures only when that is not possible
  final parts = <SourcePage>[];
  for (var i = 0; i < paths.length; i++) {
    final count = await pdfPageCount(paths[i]);
    for (var index = 0; index < count; index++) {
      parts.add(SourcePage(paths[i], index));
    }
    onProgress((i + 1) / paths.length * 0.5);
  }
  final assembled = await assemblePdf(parts);
  if (assembled != null) {
    onProgress(1);
    return assembled;
  }
  return _mergeAsPictures(paths, onProgress);
}

Future<Uint8List> _mergeAsPictures(List<String> paths, void Function(double progress) onProgress) async {
  final pieces = <PdfPiece>[];
  final total = paths.length;
  for (var i = 0; i < paths.length; i++) {
    final document = await PdfDocument.openFile(paths[i]);
    try {
      for (var pageIndex = 1; pageIndex <= document.pagesCount; pageIndex++) {
        final page = await document.getPage(pageIndex);
        final rendered = await page.render(
          width: page.width * 1.5,
          height: page.height * 1.5,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
          quality: 85,
        );
        final format = PdfPageFormat(page.width, page.height);
        await page.close();
        if (rendered != null) {
          pieces.add(PdfPiece(image: rendered.bytes, pageFormat: format));
        }
      }
    } finally {
      await document.close();
    }
    onProgress((i + 1) / total);
  }
  return rebuildPdf(pieces);
}
