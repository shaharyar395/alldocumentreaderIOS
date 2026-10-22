import 'dart:io';

import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';

import 'office_layout.dart' show isRasterImage;
import 'office_text.dart';

TextRecognitionScript scriptForLanguage(String languageTag) {
  final tag = languageTag.toLowerCase();
  if (tag.startsWith('zh')) return TextRecognitionScript.chinese;
  if (tag.startsWith('ja')) return TextRecognitionScript.japanese;
  if (tag.startsWith('ko')) return TextRecognitionScript.korean;
  if (tag.startsWith('hi') || tag.startsWith('mr') || tag.startsWith('ne') || tag.startsWith('sa')) {
    return TextRecognitionScript.devanagiri;
  }
  return TextRecognitionScript.latin;
}

String? tesseractLanguage(String languageTag) {
  final tag = languageTag.toLowerCase();
  if (tag.startsWith('ar')) return 'ara';
  if (tag.startsWith('fa')) return 'fas';
  if (tag.startsWith('ur')) return 'urd';
  if (tag.startsWith('th')) return 'tha';
  return null;
}

Future<String> recognizeImageFile(String path, {String languageTag = 'en'}) async {
  final script = tesseractLanguage(languageTag);
  if (script != null) {
    final extra = await _tesseract(path, script);
    if (extra.trim().isNotEmpty) return extra;
  }
  final preferred = scriptForLanguage(languageTag);
  final first = await _recognize(path, preferred);
  if (first.trim().isNotEmpty || preferred == TextRecognitionScript.latin) return first;
  return _recognize(path, TextRecognitionScript.latin);
}

Future<String> _tesseract(String path, String language) async {
  try {
    return await FlutterTesseractOcr.extractText(path, language: language, args: const {
      'psm': '6',
      'preserve_interword_spaces': '1',
    });
  } catch (_) {
    return '';
  }
}

Future<String> _recognize(String path, TextRecognitionScript script) async {
  TextRecognizer? recognizer;
  try {
    recognizer = TextRecognizer(script: script);
    final recognized = await recognizer.processImage(InputImage.fromFilePath(path));
    return recognized.text;
  } catch (_) {
    return '';
  } finally {
    await recognizer?.close();
  }
}

Future<String> ocrPdf(
  String path, {
  String languageTag = 'en',
  void Function(int done, int total)? onPage,
}) async {
  final pages = await ocrPdfPages(path, languageTag: languageTag, onPage: onPage);
  return pages.where((page) => page.trim().isNotEmpty).join('\n\n').trim();
}

/// Recognizes one PDF page. [pageNumber] is 1-based.
Future<String> ocrPdfPage(String path, int pageNumber, {String languageTag = 'en'}) async {
  final document = await PdfDocument.openFile(path);
  try {
    if (pageNumber < 1 || pageNumber > document.pagesCount) return '';
    return await _ocrPage(document, pageNumber, languageTag);
  } finally {
    await document.close();
  }
}

/// Recognizes the pages of a PDF (all, or [onlyPages], 1-based). [onText] gets each page's text
/// as soon as it is read; when [isCancelled] returns true the remaining pages are skipped.
Future<List<String>> ocrPdfPages(
  String path, {
  String languageTag = 'en',
  void Function(int done, int total)? onPage,
  List<int>? onlyPages,
  void Function(int pageNumber, String text)? onText,
  bool Function()? isCancelled,
}) async {
  final document = await PdfDocument.openFile(path);
  try {
    final total = document.pagesCount;
    final wanted = onlyPages ?? [for (var index = 1; index <= total; index++) index];
    final texts = List<String>.filled(total, '');
    var done = 0;
    for (final index in wanted) {
      if (isCancelled?.call() ?? false) break;
      if (index < 1 || index > total) continue;
      texts[index - 1] = await _ocrPage(document, index, languageTag);
      done++;
      onText?.call(index, texts[index - 1]);
      onPage?.call(done, wanted.length);
    }
    return texts;
  } finally {
    await document.close();
  }
}

/// Recognizes the text in one picture (PNG, JPEG, GIF, BMP, WebP). Empty for other formats.
Future<String> ocrImageBytes(List<int> bytes, {String languageTag = 'en'}) async {
  if (!isRasterImage(bytes)) return '';
  final ext = bytes[0] == 0x89 ? 'png' : (bytes[0] == 0xFF ? 'jpg' : (bytes[0] == 0x47 ? 'gif' : (bytes[0] == 0x42 ? 'bmp' : 'webp')));
  final temp = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}ocr_image_${DateTime.now().microsecondsSinceEpoch}.$ext',
  );
  try {
    await temp.writeAsBytes(bytes, flush: true);
    final text = await recognizeImageFile(temp.path, languageTag: languageTag);
    return text.trim();
  } catch (_) {
    return '';
  } finally {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {
      // temp files are cleaned by the system later
    }
  }
}

Future<String> _ocrPage(PdfDocument document, int pageNumber, String languageTag) async {
  final page = await document.getPage(pageNumber);
  try {
    final rendered = await page.render(
      width: page.width * 1.6,
      height: page.height * 1.6,
      format: PdfPageImageFormat.jpeg,
      backgroundColor: '#FFFFFF',
      quality: 80,
    );
    if (rendered == null) return '';
    final temp = File('${Directory.systemTemp.path}${Platform.pathSeparator}ocr_page_${pageNumber}_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await temp.writeAsBytes(rendered.bytes, flush: true);
    final text = await recognizeImageFile(temp.path, languageTag: languageTag);
    if (await temp.exists()) await temp.delete();
    return text.trim();
  } finally {
    await page.close();
  }
}

/// OCR pictures embedded in a Word or PowerPoint file when the document has no text layer.
Future<String> ocrOfficeImages(List<int> bytes, {String languageTag = 'en'}) async {
  final images = officeMedia(bytes);
  if (images.isEmpty) return '';
  final buffer = StringBuffer();
  for (final image in images) {
    final text = await ocrImageBytes(image, languageTag: languageTag);
    if (text.isNotEmpty) {
      buffer.writeln(text);
      buffer.writeln();
    }
  }
  return buffer.toString().trim();
}
