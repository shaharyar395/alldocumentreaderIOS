import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

List<Uint8List> officeMedia(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final images = <Uint8List>[];
    for (final file in archive.files) {
      final name = file.name.toLowerCase();
      final isMedia = name.startsWith('word/media/') || name.startsWith('ppt/media/');
      if (!isMedia) continue;
      images.add(Uint8List.fromList(file.content as List<int>));
    }
    return images;
  } catch (_) {
    return const [];
  }
}

String extractOfficeText(Uint8List bytes, {required bool slides}) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (!slides) {
      final file = archive.findFile('word/document.xml');
      if (file == null) return '';
      return _paragraphs(file.content as List<int>, paragraph: 'p', text: 't');
    }
    final buffer = StringBuffer();
    final names = archive.files.map((f) => f.name).where((n) => n.startsWith('ppt/slides/slide') && n.endsWith('.xml')).toList()
      ..sort();
    for (final name in names) {
      final file = archive.findFile(name);
      if (file == null) continue;
      final text = _paragraphs(file.content as List<int>, paragraph: 'sp', text: 't');
      if (text.trim().isNotEmpty) {
        buffer.writeln(text.trim());
        buffer.writeln();
      }
    }
    return buffer.toString().trim();
  } catch (error) {
    return '';
  }
}

String _paragraphs(List<int> bytes, {required String paragraph, required String text}) {
  final document = XmlDocument.parse(utf8.decode(bytes));
  final buffer = StringBuffer();
  for (final node in document.descendants.whereType<XmlElement>()) {
    if (node.name.local != paragraph) continue;
    final parts = node.descendants.whereType<XmlElement>().where((e) => e.name.local == text).map((e) => e.innerText);
    final line = parts.join();
    if (line.trim().isNotEmpty) buffer.writeln(line);
  }
  return buffer.toString().trim();
}

/// Minimal Word document so PDF to Word has a real .docx when text exists.
Uint8List buildDocx(String text) {
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final paragraphs = escaped.split('\n').map((line) {
    return '<w:p><w:r><w:t xml:space="preserve">${line.isEmpty ? ' ' : line}</w:t></w:r></w:p>';
  }).join();
  final document = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$paragraphs<w:sectPr/></w:body></w:document>''';
  const types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
  const rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';
  final archive = Archive()
    ..addFile(ArchiveFile('[Content_Types].xml', types.length, types))
    ..addFile(ArchiveFile('_rels/.rels', rels.length, rels))
    ..addFile(ArchiveFile('word/document.xml', document.length, document));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
