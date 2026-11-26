import 'dart:convert';
import 'dart:math' as math;
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

/// PDF → Word the way the Android app does it: each PDF page is a full-page picture on its own
/// Word page, at the PDF page size, with no margins. The words stay where they were.
Uint8List buildPageImageDocx(List<({Uint8List jpeg, double width, double height})> pages) {
  final first = pages.first;
  final pageW = first.width;
  final pageH = first.height;
  final body = StringBuffer();
  final rels = StringBuffer();
  final archive = Archive();
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final jpeg = page.jpeg;
    archive.addFile(ArchiveFile('word/media/page${i + 1}.jpeg', jpeg.length, jpeg));
    final rid = 'rIdImg${i + 1}';
    rels.write(
      '<Relationship Id="$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/page${i + 1}.jpeg"/>',
    );
    final fit = math.min(pageW / page.width, pageH / page.height);
    final dw = page.width * fit;
    final dh = page.height * fit;
    body.write(_pagePicture(
      i,
      rid,
      (dw * 12700).round(),
      (dh * 12700).round(),
      ((pageW - dw) / 2 * 12700).round(),
      ((pageH - dh) / 2 * 12700).round(),
    ));
  }
  final tw = (pageW * 20).round();
  final th = (pageH * 20).round();
  final orient = pageW > pageH ? ' w:orient="landscape"' : '';
  final document = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>$body<w:sectPr><w:pgSz w:w="$tw" w:h="$th"$orient/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr></w:body></w:document>''';
  final types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>''';
  const rootRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''';
  final docRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>''';
  void put(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  put('[Content_Types].xml', types);
  put('_rels/.rels', rootRels);
  put('word/_rels/document.xml.rels', docRels);
  put('word/document.xml', document);
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// One Word paragraph: the page picture anchored to the page, and a page break before every page after the first.
String _pagePicture(int index, String rid, int cx, int cy, int offX, int offY) {
  final id = index + 1;
  final breakBefore = index > 0
      ? '<w:pPr><w:pageBreakBefore/><w:spacing w:before="0" w:after="0"/></w:pPr>'
      : '<w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>';
  return '<w:p>$breakBefore<w:r><w:drawing>'
      '<wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="$id" behindDoc="1" locked="1" layoutInCell="1" allowOverlap="1">'
      '<wp:simplePos x="0" y="0"/>'
      '<wp:positionH relativeFrom="page"><wp:posOffset>$offX</wp:posOffset></wp:positionH>'
      '<wp:positionV relativeFrom="page"><wp:posOffset>$offY</wp:posOffset></wp:positionV>'
      '<wp:extent cx="$cx" cy="$cy"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>'
      '<wp:docPr id="$id" name="Page $id"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>'
      '<pic:nvPicPr><pic:cNvPr id="$id" name="page$id.jpeg"/><pic:cNvPicPr/></pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
      '</pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>';
}
