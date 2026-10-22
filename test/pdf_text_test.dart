import 'dart:typed_data';

import 'package:alldocreader/services/pdf_rewrite.dart';
import 'package:alldocreader/services/pdf_text.dart';
import 'package:alldocreader/services/pdf_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('pdf text layer survives a round trip', () async {
    final bytes = await textToPdf('Hello reader\nSecond line');
    final text = extractPdfText(bytes);
    expect(text.toLowerCase(), contains('hello'));
    expect(text.toLowerCase(), contains('second'));
  });

  test('editing the text layer keeps the words in the PDF', () async {
    final bytes = await textToPdf('Hello reader');
    final edited = rewritePdf(bytes, changes: const [PdfTextChange('Hello reader', 'Hello editor')]);
    expect(edited, isNotNull);
    expect(extractPdfText(edited!).toLowerCase(), contains('editor'));
  });

  test('an image stamp keeps the existing text layer', () async {
    final bytes = await textToPdf('Hello reader');
    final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));
    final edited = rewritePdf(
      bytes,
      marks: [
        PdfVectorMark(page: 1, tool: 'image', points: const [(0.2, 0.3)], image: jpeg),
      ],
    );
    expect(edited, isNotNull);
    expect(extractPdfText(edited!).toLowerCase(), contains('hello'));
    expect(String.fromCharCodes(edited), contains('/Subtype /Image'));
  });
}