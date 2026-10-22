import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

import 'pdf_text.dart';

class PdfTextChange {
  const PdfTextChange(this.from, this.to);

  final String from;
  final String to;
}

class PdfVectorMark {
  const PdfVectorMark({
    required this.page,
    required this.tool,
    required this.points,
    this.text = '',
    this.color = 0xFF1C2434,
    this.image,
    this.size = 14,
    this.width,
    this.height,
    this.rotation = 0,
    this.stroke,
  });

  /// 1-based page index.
  final int page;

  /// pen, highlight, underline, strike: [points] is the stroke (page fractions, top-left origin).
  /// text: [points].first is the baseline start of the first line; lines are split at '\n'.
  /// whiteout: [points] = top-left and bottom-right of a filled rectangle in [color].
  /// image: [points].first = top-left, [width] (default 0.35) as a fraction of the page width.
  /// stamp: [points].first = centre, [width] / [height] as fractions of the page width / height,
  /// turned by [rotation]; PNG transparency is kept.
  final String tool;
  final List<(double, double)> points;
  final String text;
  final int color;
  final Uint8List? image;

  /// Font size in points (text).
  final double size;
  final double? width;
  final double? height;

  /// Degrees, clockwise as seen on the page (text, stamp).
  final double rotation;

  /// Line width in points (pen, highlight, underline, strike).
  final double? stroke;
}

/// Rewrites text inside the PDF content streams and appends vector marks.
/// Returns null when the cross-reference table cannot be read, so the caller can fall back.
Uint8List? rewritePdf(
  Uint8List data, {
  List<PdfTextChange> changes = const [],
  List<PdfVectorMark> marks = const [],
}) {
  if (changes.isEmpty && marks.isEmpty) return data;
  final xref = _readXref(data);
  if (xref == null) return null;
  final objects = _loadObjects(data, xref);
  final pages = _pages(objects);
  if (pages.isEmpty) return null;

  final updated = <int, Uint8List>{};
  final fresh = <_Fresh>[];
  final dicts = <int, String>{};
  var nextId = objects.keys.fold<int>(0, (max, id) => id > max ? id : max) + 1;
  int? fontId;
  int? stateId;
  var anyChange = false;
  for (var index = 0; index < pages.length; index++) {
    final page = pages[index];
    final pageMarks = marks.where((mark) => mark.page == index + 1).toList();
    final streams = [for (final id in page.contents) objects[id]];
    final readable = streams.isNotEmpty && streams.every((stream) => stream != null && stream.decoded != null);
    if (!readable) {
      if (pageMarks.isNotEmpty) return null;
      continue;
    }
    final texts = [for (final stream in streams) latin1.decode(stream!.decoded!, allowInvalid: true)];
    final originals = List<String>.of(texts);
    if (changes.isNotEmpty) {
      for (var i = 0; i < texts.length; i++) {
        texts[i] = _replaceText(texts[i], changes);
      }
    }
    if (pageMarks.isNotEmpty) {
      final xobjects = <String, int>{};
      final fonts = <String, int>{};
      final states = <String, int>{};
      final needsFont = pageMarks.any((mark) => mark.tool == 'text' && mark.text.isNotEmpty);
      final needsState = pageMarks.any((mark) => mark.tool == 'highlight');
      if (needsFont && fontId == null) {
        fontId = nextId++;
        fresh.add(_Fresh(fontId, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>', Uint8List(0), stream: false));
      }
      if (needsState && stateId == null) {
        stateId = nextId++;
        fresh.add(_Fresh(stateId, '<< /Type /ExtGState /CA 0.4 /ca 0.4 /BM /Multiply >>', Uint8List(0), stream: false));
      }
      if (needsFont) fonts[_helvName] = fontId!;
      if (needsState) states[_stateName] = stateId!;
      final ops = StringBuffer();
      for (final mark in pageMarks) {
        if (mark.tool == 'image' || mark.tool == 'stamp') {
          if (mark.image == null || mark.points.isEmpty) continue;
          final picture = _pictureObjects(mark.image!, () => nextId++);
          if (picture == null) continue;
          fresh.addAll(picture.objects);
          final name = 'Im${picture.id}';
          xobjects[name] = picture.id;
          ops.writeln(_placement(mark, page.width, page.height, picture.width, picture.height, name));
        } else {
          ops.write(_operators(mark, page.width, page.height));
        }
      }
      final resources = _resourcesOf(page, objects, dicts);
      var fontName = _helvName;
      var stateOk = false;
      if (resources == null) {
        if (xobjects.isNotEmpty) return null;
        fontName = _fontName(texts.first, page.dict);
      } else {
        var (targetId, text, open) = resources;
        if (xobjects.isNotEmpty) {
          final next = _injectResource(text, open, 'XObject', xobjects, objects, dicts);
          if (next == null) return null;
          text = next;
        }
        if (fonts.isNotEmpty) {
          final next = _injectResource(text, open, 'Font', fonts, objects, dicts);
          if (next == null) {
            fontName = _fontName(texts.first, page.dict);
          } else {
            text = next;
          }
        }
        if (states.isNotEmpty) {
          final next = _injectResource(text, open, 'ExtGState', states, objects, dicts);
          if (next != null) {
            text = next;
            stateOk = true;
          }
        }
        dicts[targetId] = text;
      }
      var appended = ops.toString();
      if (fontName != _helvName) appended = appended.replaceAll('/$_helvName ', '/$fontName ');
      if (!stateOk) appended = appended.replaceAll('/$_stateName gs ', '');
      // the page's own drawing runs in its own q … Q, so the marks start from the default state
      texts[0] = 'q\n${texts[0]}';
      texts[texts.length - 1] = '${texts[texts.length - 1]}\nQ\n$appended';
    }
    for (var i = 0; i < texts.length; i++) {
      if (texts[i] == originals[i]) continue;
      final stream = streams[i]!;
      final encoded = stream.flate ? Uint8List.fromList(const ZLibEncoder().encode(latin1.encode(texts[i]))) : latin1.encode(texts[i]);
      updated[stream.id] = encoded;
      anyChange = true;
    }
  }
  if (!anyChange && fresh.isEmpty && dicts.isEmpty) return changes.isEmpty ? data : null;
  return _incremental(data, xref, objects, updated, fresh: fresh, dicts: dicts);
}

const _helvName = 'ADRHv';
const _stateName = 'ADRGs';

/// One string per page, including pages whose content stream has no text yet.
List<String>? readPdfPageTexts(Uint8List data) {
  final xref = _readXref(data);
  if (xref == null) return null;
  final objects = _loadObjects(data, xref);
  final pages = _pages(objects);
  if (pages.isEmpty) return null;
  return [
    for (final page in pages)
      page.contents
          .map((id) {
            final decoded = objects[id]?.decoded;
            return decoded == null ? '' : textFromDecodedStream(decoded);
          })
          .where((text) => text.isNotEmpty)
          .join('\n'),
  ];
}

class _Run {
  _Run(this.open, this.end, this.text);
  final int open;
  final int end;
  final String text;
}

List<_Run> _textRuns(String content) {
  final runs = <_Run>[];
  var index = 0;
  while (index < content.length) {
    if (content[index] != '(') {
      index++;
      continue;
    }
    final literal = _literal(content, index);
    if (literal == null) {
      index++;
      continue;
    }
    final follow = content.substring(literal.end, (literal.end + 16).clamp(0, content.length));
    if (RegExp(r'^[\s\]]*(Tj|TJ)').hasMatch(follow)) {
      runs.add(_Run(index, literal.end, literal.text));
    }
    index = literal.end;
  }
  return runs;
}

String _replaceText(String content, List<PdfTextChange> changes) {
  final runs = _textRuns(content);
  if (runs.isEmpty) return content;
  final texts = runs.map((run) => run.text).toList();
  for (final change in changes) {
    final needle = change.from.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (needle.isEmpty) continue;
    final joined = texts.join(' ');
    final at = joined.indexOf(needle);
    if (at < 0) continue;
    final covered = <int>[];
    var cursor = 0;
    for (var index = 0; index < texts.length; index++) {
      final start = cursor;
      final end = cursor + texts[index].length;
      if (end > at && start < at + needle.length && texts[index].isNotEmpty) covered.add(index);
      cursor = end + 1;
    }
    if (covered.isEmpty) continue;
    final fromTokens = needle.split(' ');
    final toTokens = change.to.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
    if (covered.length == fromTokens.length && covered.length == toTokens.length) {
      for (var index = 0; index < covered.length; index++) {
        texts[covered[index]] = toTokens[index];
      }
    } else {
      texts[covered.first] = change.to;
      for (final index in covered.skip(1)) {
        texts[index] = '';
      }
    }
  }
  final buffer = StringBuffer();
  var index = 0;
  for (var runIndex = 0; runIndex < runs.length; runIndex++) {
    final run = runs[runIndex];
    buffer.write(content.substring(index, run.open));
    buffer.write(texts[runIndex] == run.text ? content.substring(run.open, run.end) : '(${_escape(texts[runIndex])})');
    index = run.end;
  }
  buffer.write(content.substring(index));
  return buffer.toString();
}

String _operators(PdfVectorMark mark, double width, double height) {
  final buffer = StringBuffer();
  String point((double, double) value) {
    final x = (value.$1.clamp(0, 1) * width).toStringAsFixed(2);
    final y = ((1 - value.$2.clamp(0, 1)) * height).toStringAsFixed(2);
    return '$x $y';
  }

  String n(double value) => value.toStringAsFixed(3);

  if (mark.tool == 'whiteout') {
    if (mark.points.length < 2) return '';
    final (l, t) = mark.points[0];
    final (r, b) = mark.points[1];
    final x = l.clamp(0.0, 1.0) * width;
    final y = (1 - b.clamp(0.0, 1.0)) * height;
    final w = (r - l).abs() * width;
    final h = (b - t).abs() * height;
    return 'q ${_rgb(mark.color)} rg ${n(x)} ${n(y)} ${n(w)} ${n(h)} re f Q\n';
  }
  if (mark.tool == 'text') {
    if (mark.text.isEmpty || mark.points.isEmpty) return '';
    final (fx, fy) = mark.points.first;
    final x = fx * width;
    final y = (1 - fy) * height;
    final angle = mark.rotation * math.pi / 180;
    final a = math.cos(angle);
    final b = -math.sin(angle);
    final c = math.sin(angle);
    final d = math.cos(angle);
    final size = mark.size <= 0 ? 14.0 : mark.size;
    final lines = mark.text.split('\n');
    buffer.write('BT /$_helvName ${n(size)} Tf ${_rgb(mark.color)} rg ${n(a)} ${n(b)} ${n(c)} ${n(d)} ${n(x)} ${n(y)} Tm (${_escape(lines.first)}) Tj');
    for (final line in lines.skip(1)) {
      buffer.write(' 0 ${n(-size * 1.2)} Td (${_escape(line)}) Tj');
    }
    buffer.writeln(' ET');
    return buffer.toString();
  }
  if (mark.points.length < 2) return '';
  final highlight = mark.tool == 'highlight';
  final stroke = mark.stroke ?? (highlight ? 10.0 : 1.5);
  final color = highlight && mark.color == 0xFF1C2434 ? '1 0.86 0.2' : _rgb(mark.color);
  final state = highlight ? '/$_stateName gs ' : '';
  if (mark.tool == 'underline' || mark.tool == 'strike') {
    final xs = mark.points.map((p) => p.$1);
    final ys = mark.points.map((p) => p.$2);
    final minX = xs.reduce((a, b) => a < b ? a : b);
    final maxX = xs.reduce((a, b) => a > b ? a : b);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final y = mark.tool == 'underline' ? maxY : (minY + maxY) / 2;
    return 'q $color RG ${n(mark.stroke ?? 1.2)} w ${point((minX, y))} m ${point((maxX, y))} l S Q\n';
  }
  buffer.write('q $state$color RG ${n(stroke)} w 1 J 1 j ${point(mark.points.first)} m ');
  for (final value in mark.points.skip(1)) {
    buffer.write('${point(value)} l ');
  }
  buffer.writeln('S Q');
  return buffer.toString();
}

/// The cm … Do operators that draw picture [name] ([pw] × [ph] pixels) for [mark].
String _placement(PdfVectorMark mark, double width, double height, int pw, int ph, String name) {
  String n(double value) => value.toStringAsFixed(3);
  final (fx, fy) = mark.points.first;
  if (mark.tool == 'image') {
    final drawW = width * (mark.width ?? 0.35);
    final drawH = drawW * ph / pw;
    final x = fx.clamp(0.0, 1.0) * width;
    final y = (1 - fy.clamp(0.0, 1.0)) * height - drawH;
    return 'q ${n(drawW)} 0 0 ${n(drawH)} ${n(x)} ${n(y)} cm /$name Do Q';
  }
  final w = width * (mark.width ?? 0.35);
  final h = mark.height != null ? height * mark.height! : w * ph / pw;
  final cx = fx * width;
  final cy = (1 - fy) * height;
  final angle = mark.rotation * math.pi / 180;
  final a = w * math.cos(angle);
  final b = -w * math.sin(angle);
  final c = h * math.sin(angle);
  final d = h * math.cos(angle);
  final e = cx - 0.5 * (a + c);
  final f = cy - 0.5 * (b + d);
  return 'q ${n(a)} ${n(b)} ${n(c)} ${n(d)} ${n(e)} ${n(f)} cm /$name Do Q';
}

class _Picture {
  _Picture(this.id, this.width, this.height, this.objects);
  final int id;
  final int width;
  final int height;
  final List<_Fresh> objects;
}

/// Image XObject(s) for a JPEG / PNG: JPEGs go in as they are; pictures with transparency get
/// an /SMask so only the drawn part covers the page.
_Picture? _pictureObjects(Uint8List bytes, int Function() nextId) {
  final info = _jpegInfo(bytes);
  if (info != null && (info.$3 == 3 || info.$3 == 1)) {
    final id = nextId();
    final space = info.$3 == 1 ? '/DeviceGray' : '/DeviceRGB';
    return _Picture(id, info.$1, info.$2, [
      _Fresh(id, '<< /Type /XObject /Subtype /Image /Width ${info.$1} /Height ${info.$2} /ColorSpace $space /BitsPerComponent 8 /Filter /DCTDecode /Length ${bytes.length} >>', bytes),
    ]);
  }
  final decoded = img.decodeImage(bytes);
  if (decoded == null || decoded.width == 0 || decoded.height == 0) return null;
  final picture = img.bakeOrientation(decoded);
  final w = picture.width;
  final h = picture.height;
  if (!picture.hasAlpha) {
    final jpeg = Uint8List.fromList(img.encodeJpg(picture, quality: 88));
    final id = nextId();
    return _Picture(id, w, h, [
      _Fresh(id, '<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>', jpeg),
    ]);
  }
  final rgb = Uint8List(w * h * 3);
  final alpha = Uint8List(w * h);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = picture.getPixel(x, y);
      rgb[i * 3] = (p.rNormalized * 255).round().clamp(0, 255);
      rgb[i * 3 + 1] = (p.gNormalized * 255).round().clamp(0, 255);
      rgb[i * 3 + 2] = (p.bNormalized * 255).round().clamp(0, 255);
      alpha[i] = (p.aNormalized * 255).round().clamp(0, 255);
      i++;
    }
  }
  final color = Uint8List.fromList(const ZLibEncoder().encode(rgb));
  final mask = Uint8List.fromList(const ZLibEncoder().encode(alpha));
  final maskId = nextId();
  final id = nextId();
  return _Picture(id, w, h, [
    _Fresh(maskId, '<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length ${mask.length} >>', mask),
    _Fresh(id, '<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask $maskId 0 R /Filter /FlateDecode /Length ${color.length} >>', color),
  ]);
}

String _rgb(int color) {
  final red = ((color >> 16) & 255) / 255;
  final green = ((color >> 8) & 255) / 255;
  final blue = (color & 255) / 255;
  return '${red.toStringAsFixed(3)} ${green.toStringAsFixed(3)} ${blue.toStringAsFixed(3)}';
}

String _fontName(String content, String dict) {
  final fromStream = RegExp(r'/([A-Za-z][A-Za-z0-9]*)\s+[0-9.]+\s+Tf').firstMatch(content);
  if (fromStream != null) return fromStream.group(1)!;
  final fromPage = RegExp(r'/Font\s*<<\s*/([A-Za-z][A-Za-z0-9]*)').firstMatch(dict);
  if (fromPage != null) return fromPage.group(1)!;
  return 'F1';
}

String _escape(String text) {
  final buffer = StringBuffer();
  for (final code in text.codeUnits) {
    if (code == 0x28 || code == 0x29 || code == 0x5C) {
      buffer.write('\\${String.fromCharCode(code)}');
    } else if (code == 10) {
      buffer.write(r'\n');
    } else if (code < 32 || code > 126) {
      buffer.write('\\${code.toRadixString(8).padLeft(3, '0')}');
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer.toString();
}

class _Literal {
  _Literal(this.text, this.end);
  final String text;
  final int end;
}

_Literal? _literal(String source, int start) {
  if (source[start] != '(') return null;
  final buffer = StringBuffer();
  var index = start + 1;
  var depth = 1;
  while (index < source.length && depth > 0) {
    final char = source[index];
    if (char == r'\' && index + 1 < source.length) {
      final next = source[index + 1];
      if (next == 'n') {
        buffer.write('\n');
      } else if (next == '(' || next == ')' || next == r'\') {
        buffer.write(next);
      } else {
        buffer.write(next);
      }
      index += 2;
      continue;
    }
    if (char == '(') {
      depth++;
      buffer.write(char);
    } else if (char == ')') {
      depth--;
      if (depth > 0) buffer.write(char);
    } else {
      buffer.write(char);
    }
    index++;
  }
  return _Literal(buffer.toString(), index);
}

class _Xref {
  _Xref(this.entries, this.startxref, this.root);
  final List<_XrefEntry> entries;
  final int startxref;
  final String root;
}

class _XrefEntry {
  _XrefEntry(this.id, this.offset, this.generation, this.used, {this.streamObject = false});
  final int id;
  final int offset;
  final int generation;
  final bool used;
  final bool streamObject;
}

class _Fresh {
  _Fresh(this.id, this.dict, this.bytes, {this.stream = true});
  final int id;
  final String dict;
  final Uint8List bytes;
  final bool stream;
}

Map<int, _Obj> _loadObjects(Uint8List data, _Xref xref) {
  final objects = <int, _Obj>{};
  for (final entry in xref.entries) {
    if (!entry.used || entry.streamObject) continue;
    final object = _readObject(data, entry.offset, entry.id, entry.generation);
    if (object != null) objects[entry.id] = object;
  }
  final seen = <int>{};
  for (final entry in xref.entries.where((item) => item.streamObject)) {
    if (!seen.add(entry.offset)) continue;
    final container = objects[entry.offset];
    if (container?.decoded == null) continue;
    objects.addAll(_expandObjStm(container!));
  }
  return objects;
}

Map<int, _Obj> _expandObjStm(_Obj container) {
  final decoded = container.decoded;
  if (decoded == null) return const {};
  final count = int.tryParse(RegExp(r'/N\s+(\d+)').firstMatch(container.dict)?.group(1) ?? '');
  final first = int.tryParse(RegExp(r'/First\s+(\d+)').firstMatch(container.dict)?.group(1) ?? '');
  if (count == null || first == null || first <= 0 || first > decoded.length) return const {};
  final header = latin1.decode(decoded.sublist(0, first), allowInvalid: true);
  final nums = RegExp(r'\d+').allMatches(header).map((match) => int.parse(match.group(0)!)).toList();
  if (nums.length < count * 2) return const {};
  final objects = <int, _Obj>{};
  for (var index = 0; index < count; index++) {
    final id = nums[index * 2];
    final start = first + nums[index * 2 + 1];
    final end = index + 1 < count ? first + nums[(index + 1) * 2 + 1] : decoded.length;
    if (start < first || end > decoded.length || start >= end) continue;
    final body = latin1.decode(decoded.sublist(start, end), allowInvalid: true).trim();
    final dictStart = body.indexOf('<<');
    objects[id] = _Obj(id: id, generation: 0, dict: dictStart >= 0 ? body.substring(dictStart) : body, flate: false);
  }
  return objects;
}

/// Where the page's resource dictionary is written: (object id, its text, index of the
/// resource dictionary's "<<" in that text). Inherited resources are copied onto the page.
(int, String, int)? _resourcesOf(_PageRef page, Map<int, _Obj> objects, Map<int, String> dicts) {
  final pageText = dicts[page.id] ?? page.dict;
  (int, String, int)? indirect(String text) {
    final match = RegExp(r'/Resources\s+(\d+)\s+\d+\s+R').firstMatch(text);
    if (match == null) return null;
    final id = int.parse(match.group(1)!);
    final body = dicts[id] ?? objects[id]?.dict;
    if (body == null) return null;
    final open = body.indexOf('<<');
    return open < 0 ? null : (id, body, open);
  }

  final own = indirect(pageText);
  if (own != null) return own;
  if (RegExp(r'/Resources\s+\d+\s+\d+\s+R').hasMatch(pageText)) return null;
  final inline = RegExp(r'/Resources\s*<<').firstMatch(pageText);
  if (inline != null) return (page.id, pageText, inline.end - 2);
  final close = pageText.lastIndexOf('>>');
  if (close < 0) return null;
  // inherited from the page tree
  var parentText = pageText;
  for (var depth = 0; depth < 12; depth++) {
    final parent = RegExp(r'/Parent\s+(\d+)\s+\d+\s+R').firstMatch(parentText);
    if (parent == null) break;
    final next = objects[int.parse(parent.group(1)!)]?.dict;
    if (next == null) break;
    final shared = indirect(next);
    if (shared != null) return shared;
    final parentInline = RegExp(r'/Resources\s*<<').firstMatch(next);
    if (parentInline != null) {
      final open = parentInline.end - 2;
      final end = _dictEnd(next, open);
      if (end < 0) return null;
      final copied = next.substring(open, end);
      final text = '${pageText.substring(0, close)}/Resources $copied${pageText.substring(close)}';
      return (page.id, text, close + '/Resources '.length);
    }
    parentText = next;
  }
  final text = '${pageText.substring(0, close)}/Resources << >>${pageText.substring(close)}';
  return (page.id, text, close + '/Resources '.length);
}

/// Adds [entries] (name → object id) to the [category] sub-dictionary (XObject, Font, ExtGState)
/// of the resource dictionary that starts at [open] in [text]. Returns the new text, or null when
/// it can't be done.
String? _injectResource(String text, int open, String category, Map<String, int> entries, Map<int, _Obj> objects, Map<int, String> dicts) {
  final end = _dictEnd(text, open);
  if (end < 0) return null;
  final body = entries.entries.map((entry) => '/${entry.key} ${entry.value} 0 R').join(' ');
  final inner = text.substring(open, end);
  final direct = RegExp('/$category\\s*<<').firstMatch(inner);
  if (direct != null) {
    final at = open + direct.end;
    return '${text.substring(0, at)} $body ${text.substring(at)}';
  }
  final indirect = RegExp('/$category\\s+(\\d+)\\s+\\d+\\s+R').firstMatch(inner);
  if (indirect != null) {
    final id = int.parse(indirect.group(1)!);
    final sub = dicts[id] ?? objects[id]?.dict;
    if (sub == null) return null;
    final subOpen = sub.indexOf('<<');
    if (subOpen < 0) return null;
    dicts[id] = '${sub.substring(0, subOpen + 2)} $body ${sub.substring(subOpen + 2)}';
    return text;
  }
  final at = open + 2;
  return '${text.substring(0, at)}/$category<< $body >> ${text.substring(at)}';
}

/// Index just after the ">>" that closes the "<<" at [open].
int _dictEnd(String text, int open) {
  var depth = 0;
  var index = open;
  while (index + 1 < text.length) {
    final a = text.codeUnitAt(index);
    final b = text.codeUnitAt(index + 1);
    if (a == 0x3C && b == 0x3C) {
      depth++;
      index += 2;
      continue;
    }
    if (a == 0x3E && b == 0x3E) {
      depth--;
      index += 2;
      if (depth == 0) return index;
      continue;
    }
    index++;
  }
  return -1;
}

/// Width, height and colour components of a baseline / progressive JPEG.
(int, int, int)? _jpegInfo(Uint8List data) {
  if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) return null;
  var index = 2;
  while (index + 9 < data.length) {
    if (data[index] != 0xFF) {
      index++;
      continue;
    }
    final marker = data[index + 1];
    if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
      final height = (data[index + 5] << 8) | data[index + 6];
      final width = (data[index + 7] << 8) | data[index + 8];
      final components = data[index + 9];
      if (width == 0 || height == 0) return null;
      return (width, height, components);
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      index += 2;
      continue;
    }
    if (index + 3 >= data.length) break;
    final length = (data[index + 2] << 8) | data[index + 3];
    if (length < 2) break;
    index += 2 + length;
  }
  return null;
}

_Xref? _readXref(Uint8List data) {
  final tail = latin1.decode(data.length > 2048 ? data.sublist(data.length - 2048) : data, allowInvalid: true);
  final startMatch = RegExp(r'startxref\s+(\d+)').allMatches(tail).lastOrNull;
  if (startMatch == null) return _scanObjects(data);
  final startxref = int.parse(startMatch.group(1)!);
  if (startxref < 0 || startxref >= data.length) return _scanObjects(data);
  if (data[startxref] != 0x78) {
    final parsed = _readXrefStream(data, startxref);
    if (parsed != null && parsed.entries.isNotEmpty) return parsed;
    return _scanObjects(data);
  }
  final section = latin1.decode(data.sublist(startxref, (startxref + 65536).clamp(0, data.length)), allowInvalid: true);
  if (!section.startsWith('xref')) return _scanObjects(data);
  final trailer = RegExp(r'trailer\s*<<(.*?)>>', dotAll: true).firstMatch(section);
  final root = RegExp(r'/Root\s+(\d+\s+\d+\s+R)').firstMatch(trailer?.group(1) ?? '')?.group(1);
  if (root == null) return _scanObjects(data);
  final entries = <_XrefEntry>[];
  final lines = section.split(RegExp(r'\r?\n'));
  var id = 0;
  var expecting = 0;
  for (final line in lines.skip(1)) {
    if (line.startsWith('trailer')) break;
    final head = RegExp(r'^(\d+)\s+(\d+)$').firstMatch(line.trim());
    if (head != null) {
      id = int.parse(head.group(1)!);
      expecting = int.parse(head.group(2)!);
      continue;
    }
    final row = RegExp(r'^(\d{10}) (\d{5}) ([nf])').firstMatch(line);
    if (row == null || expecting <= 0) continue;
    entries.add(_XrefEntry(id, int.parse(row.group(1)!), int.parse(row.group(2)!), row.group(3) == 'n'));
    id++;
    expecting--;
  }
  if (entries.isEmpty) return _scanObjects(data);
  return _Xref(entries, startxref, root);
}

_Xref? _scanObjects(Uint8List data) {
  final text = latin1.decode(data, allowInvalid: true);
  final entries = <int, _XrefEntry>{};
  for (final match in RegExp(r'(?:^|[\n\r])(\d{1,7}) (\d{1,5}) obj(?:[\n\r ]|$)').allMatches(text)) {
    final id = int.parse(match.group(1)!);
    final generation = int.parse(match.group(2)!);
    final lead = text.codeUnitAt(match.start) == 10 || text.codeUnitAt(match.start) == 13 ? 1 : 0;
    entries[id] = _XrefEntry(id, match.start + lead, generation, true);
  }
  if (entries.isEmpty) return null;
  final root = RegExp(r'/Root\s+(\d+\s+\d+\s+R)').allMatches(text).map((match) => match.group(1)!).lastOrNull;
  if (root == null) return null;
  final start = int.tryParse(RegExp(r'startxref\s+(\d+)').allMatches(text).lastOrNull?.group(1) ?? '') ?? 0;
  final list = entries.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  return _Xref(list, start, root);
}

_Xref? _readXrefStream(Uint8List data, int startxref) {
  final head = latin1.decode(data.sublist(startxref, (startxref + 40).clamp(0, data.length)), allowInvalid: true);
  final idMatch = RegExp(r'^(\d+)\s+(\d+)\s+obj').firstMatch(head);
  if (idMatch == null) return null;
  final object = _readObject(data, startxref, int.parse(idMatch.group(1)!), int.parse(idMatch.group(2)!));
  final bytes = object?.decoded;
  if (object == null || bytes == null) return null;
  final root = RegExp(r'/Root\s+(\d+\s+\d+\s+R)').firstMatch(object.dict)?.group(1);
  final size = int.tryParse(RegExp(r'/Size\s+(\d+)').firstMatch(object.dict)?.group(1) ?? '');
  final widths = RegExp(r'/W\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s*\]').firstMatch(object.dict);
  if (root == null || size == null || widths == null) return null;
  final typeWidth = int.parse(widths.group(1)!);
  final offsetWidth = int.parse(widths.group(2)!);
  final genWidth = int.parse(widths.group(3)!);
  final stride = typeWidth + offsetWidth + genWidth;
  final entries = <_XrefEntry>[];
  for (var index = 0; index < size; index++) {
    final base = index * stride;
    if (base + stride > bytes.length) break;
    var type = typeWidth == 0 ? 1 : 0;
    for (var cursor = 0; cursor < typeWidth; cursor++) {
      type = (type << 8) | bytes[base + cursor];
    }
    var offset = 0;
    for (var cursor = 0; cursor < offsetWidth; cursor++) {
      offset = (offset << 8) | bytes[base + typeWidth + cursor];
    }
    var generation = 0;
    for (var cursor = 0; cursor < genWidth; cursor++) {
      generation = (generation << 8) | bytes[base + typeWidth + offsetWidth + cursor];
    }
    entries.add(_XrefEntry(index, offset, generation, type == 1 || type == 2, streamObject: type == 2));
  }
  if (entries.isEmpty) return null;
  return _Xref(entries, startxref, root);
}

class _Obj {
  _Obj({required this.id, required this.generation, required this.dict, this.decoded, required this.flate});
  final int id;
  final int generation;
  final String dict;
  final Uint8List? decoded;
  final bool flate;
}

_Obj? _readObject(Uint8List data, int offset, int id, int generation) {
  if (offset < 0 || offset >= data.length) return null;
  final head = latin1.decode(data.sublist(offset, (offset + 80).clamp(0, data.length)), allowInvalid: true);
  if (!head.contains('obj')) return null;
  final dictStart = _indexOfBytes(data, const [0x3C, 0x3C], offset);
  if (dictStart < 0 || dictStart > offset + 64) {
    return _Obj(id: id, generation: generation, dict: '', flate: false);
  }
  final dictEnd = _matchingDict(data, dictStart);
  if (dictEnd < 0) return null;
  final dict = latin1.decode(data.sublist(dictStart, dictEnd), allowInvalid: true);
  final streamAt = _indexOfBytes(data, latin1.encode('stream'), dictEnd);
  if (streamAt < 0 || streamAt > dictEnd + 16) {
    return _Obj(id: id, generation: generation, dict: dict, flate: false);
  }
  var content = streamAt + 6;
  if (content < data.length && data[content] == 13) content++;
  if (content < data.length && data[content] == 10) content++;
  var length = _length(dict);
  if (length == null) {
    final end = _indexOfBytes(data, latin1.encode('endstream'), content);
    if (end < 0) return null;
    var measured = end - content;
    while (measured > 0 && (data[content + measured - 1] == 10 || data[content + measured - 1] == 13)) {
      measured--;
    }
    length = measured;
  }
  if (content + length > data.length) return null;
  final raw = data.sublist(content, content + length);
  final flate = dict.contains('FlateDecode');
  Uint8List? decoded = raw;
  if (flate) {
    try {
      decoded = Uint8List.fromList(const ZLibDecoder().decodeBytes(raw));
    } catch (_) {
      decoded = null;
    }
  }
  return _Obj(id: id, generation: generation, dict: dict, decoded: decoded, flate: flate);
}

int? _length(String dict) {
  final indirect = RegExp(r'/Length\s+\d+\s+0\s+R');
  if (indirect.hasMatch(dict)) return null;
  final direct = RegExp(r'/Length\s+(\d+)').firstMatch(dict);
  if (direct == null) return null;
  return int.tryParse(direct.group(1)!);
}

class _PageRef {
  _PageRef(this.id, this.generation, this.dict, this.contents, this.width, this.height);
  final int id;
  final int generation;
  final String dict;
  final List<int> contents;
  final double width;
  final double height;
}

List<_PageRef> _pages(Map<int, _Obj> objects) {
  final pages = <_PageRef>[];
  final ordered = objects.keys.toList()..sort();
  for (final id in ordered) {
    final dict = objects[id]!.dict;
    if (!RegExp(r'/Type\s*/Page(?!s)').hasMatch(dict)) continue;
    final contents = <int>[];
    final single = RegExp(r'/Contents\s+(\d+)\s+0\s+R').firstMatch(dict);
    final array = RegExp(r'/Contents\s*\[(.*?)\]', dotAll: true).firstMatch(dict);
    if (array != null) {
      for (final match in RegExp(r'(\d+)\s+0\s+R').allMatches(array.group(1)!)) {
        contents.add(int.parse(match.group(1)!));
      }
    } else if (single != null) {
      contents.add(int.parse(single.group(1)!));
    }
    final box = RegExp(r'/MediaBox\s*\[\s*[\d.\-]+\s+[\d.\-]+\s+([\d.]+)\s+([\d.]+)\s*\]').firstMatch(dict);
    final width = double.tryParse(box?.group(1) ?? '') ?? 595;
    final height = double.tryParse(box?.group(2) ?? '') ?? 842;
    pages.add(_PageRef(id, objects[id]!.generation, dict, contents, width, height));
  }
  return pages;
}

Uint8List _incremental(
  Uint8List data,
  _Xref xref,
  Map<int, _Obj> objects,
  Map<int, Uint8List> updated, {
  List<_Fresh> fresh = const [],
  Map<int, String> dicts = const {},
}) {
  final buffer = BytesBuilder();
  buffer.add(data);
  if (data.isEmpty || data.last != 10) buffer.addByte(10);
  final offsets = <int, int>{};
  final ids = updated.keys.toList()..sort();
  for (final id in ids) {
    final object = objects[id];
    if (object == null) continue;
    offsets[id] = buffer.length;
    final body = updated[id]!;
    var dict = object.dict;
    dict = dict.replaceFirst(RegExp(r'/Length\s+\d+(\s+\d+\s+R)?'), '/Length ${body.length}');
    final header = '$id ${object.generation + 1} obj\n$dict\nstream\n';
    buffer.add(latin1.encode(header));
    buffer.add(body);
    buffer.add(latin1.encode('\nendstream\nendobj\n'));
  }
  for (final id in dicts.keys.toList()..sort()) {
    final object = objects[id];
    if (object == null) continue;
    offsets[id] = buffer.length;
    buffer.add(latin1.encode('$id ${object.generation + 1} obj\n${dicts[id]}\nendobj\n'));
  }
  for (final item in fresh) {
    offsets[item.id] = buffer.length;
    if (!item.stream) {
      buffer.add(latin1.encode('${item.id} 0 obj\n${item.dict}\nendobj\n'));
      continue;
    }
    buffer.add(latin1.encode('${item.id} 0 obj\n${item.dict}\nstream\n'));
    buffer.add(item.bytes);
    buffer.add(latin1.encode('\nendstream\nendobj\n'));
  }
  final xrefAt = buffer.length;
  final xrefText = StringBuffer('xref\n');
  final xrefIds = [...ids, ...dicts.keys, ...fresh.map((item) => item.id)]..sort();
  for (final id in xrefIds) {
    final generation = objects[id]?.generation ?? -1;
    xrefText.writeln('$id 1');
    xrefText.writeln('${offsets[id]!.toString().padLeft(10, '0')} ${(generation + 1).toString().padLeft(5, '0')} n ');
  }
  final size = xrefIds.fold<int>(0, (max, id) => id > max ? id : max) + 1;
  xrefText.writeln('trailer');
  xrefText.writeln('<< /Size $size /Prev ${xref.startxref} /Root ${xref.root} >>');
  xrefText.writeln('startxref');
  xrefText.writeln('$xrefAt');
  xrefText.writeln('%%EOF');
  buffer.add(latin1.encode(xrefText.toString()));
  return buffer.toBytes();
}

int _indexOfBytes(Uint8List data, List<int> pattern, int from) {
  final last = data.length - pattern.length;
  for (var index = from; index <= last; index++) {
    var matched = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[index + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return index;
  }
  return -1;
}

int _matchingDict(Uint8List data, int start) {
  var depth = 0;
  for (var index = start; index + 1 < data.length; index++) {
    if (data[index] == 0x3C && data[index + 1] == 0x3C) {
      depth++;
      index++;
      continue;
    }
    if (data[index] == 0x3E && data[index + 1] == 0x3E) {
      depth--;
      if (depth == 0) return index + 2;
      index++;
    }
  }
  return -1;
}

// ---------------------------------------------------------------------------------------------
// Text lines with their place on the page (Edit text: tap a line to retype it)
// ---------------------------------------------------------------------------------------------

/// One line of real text on a page. [left], [top], [right], [bottom] are fractions of the page
/// (top-left origin); [size] is the font size as a fraction of the page height.
class PdfTextLine {
  const PdfTextLine(this.text, this.left, this.top, this.right, this.bottom, this.size, {this.readable = true});

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double size;

  /// false when the font's codes are not plain characters (the text can't be shown as it is).
  final bool readable;
}

class _Run2 {
  _Run2(this.text, this.x0, this.x1, this.y, this.size, this.readable);
  final String text;
  double x0;
  double x1;
  final double y;
  final double size;
  final bool readable;
}

/// The lines of text on every page (index 0 = page 1), or null when the PDF can't be read.
List<List<PdfTextLine>>? readPdfTextLines(Uint8List data) {
  final xref = _readXref(data);
  if (xref == null) return null;
  final objects = _loadObjects(data, xref);
  final pages = _pages(objects);
  if (pages.isEmpty) return null;
  final result = <List<PdfTextLine>>[];
  for (final page in pages) {
    try {
      result.add(_pageLines(page, objects));
    } catch (_) {
      result.add(const []);
    }
  }
  return result;
}

List<PdfTextLine> _pageLines(_PageRef page, Map<int, _Obj> objects) {
  final buffer = StringBuffer();
  for (final id in page.contents) {
    final decoded = objects[id]?.decoded;
    if (decoded == null) continue;
    buffer.writeln(latin1.decode(decoded, allowInvalid: true));
  }
  final content = buffer.toString();
  if (content.isEmpty) return const [];
  final widths = _fontWidths(page, objects);
  final runs = _textRunsWithPlace(content, widths);
  if (runs.isEmpty) return const [];
  final w = page.width <= 0 ? 595.0 : page.width;
  final h = page.height <= 0 ? 842.0 : page.height;
  runs.sort((a, b) {
    final dy = b.y - a.y;
    if (dy.abs() > math.min(a.size, b.size) * 0.5) return dy > 0 ? 1 : -1;
    return a.x0.compareTo(b.x0);
  });
  final lines = <PdfTextLine>[];
  _Run2? current;
  final text = StringBuffer();
  var readable = true;
  var size = 0.0;
  void flush() {
    final run = current;
    if (run == null) return;
    final value = text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.isNotEmpty && run.x1 > run.x0) {
      lines.add(
        PdfTextLine(
          value,
          (run.x0 / w).clamp(0.0, 1.0),
          ((h - (run.y + size * 0.9)) / h).clamp(0.0, 1.0),
          (run.x1 / w).clamp(0.0, 1.0),
          ((h - (run.y - size * 0.25)) / h).clamp(0.0, 1.0),
          size / h,
          readable: readable,
        ),
      );
    }
    current = null;
    text.clear();
    readable = true;
    size = 0;
  }

  for (final run in runs) {
    final line = current;
    if (line != null) {
      final s = math.max(size, run.size);
      final sameLine = (run.y - line.y).abs() <= s * 0.5 && run.x0 - line.x1 <= s * 1.5 && run.x0 >= line.x0 - s;
      if (!sameLine) {
        flush();
      } else {
        if (run.x0 - line.x1 > s * 0.15) text.write(' ');
        text.write(run.text);
        line.x1 = math.max(line.x1, run.x1);
        size = s;
        readable = readable && run.readable;
        continue;
      }
    }
    current = _Run2(run.text, run.x0, run.x1, run.y, run.size, run.readable);
    text.write(run.text);
    size = run.size;
    readable = run.readable;
  }
  flush();
  return lines;
}

class _FontInfo {
  _FontInfo(this.first, this.widths, this.average, this.twoByte);
  final int first;
  final List<double> widths;
  final double average;
  final bool twoByte;
}

/// Glyph widths (1/1000 em) of the page's simple fonts, by resource name.
Map<String, _FontInfo> _fontWidths(_PageRef page, Map<int, _Obj> objects) {
  final out = <String, _FontInfo>{};
  String? resources;
  final indirect = RegExp(r'/Resources\s+(\d+)\s+\d+\s+R').firstMatch(page.dict);
  if (indirect != null) {
    resources = objects[int.parse(indirect.group(1)!)]?.dict;
  } else {
    final inline = RegExp(r'/Resources\s*<<').firstMatch(page.dict);
    if (inline != null) {
      final end = _dictEnd(page.dict, inline.end - 2);
      if (end > 0) resources = page.dict.substring(inline.end - 2, end);
    }
  }
  if (resources == null) return out;
  String? fontDict;
  final fontIndirect = RegExp(r'/Font\s+(\d+)\s+\d+\s+R').firstMatch(resources);
  if (fontIndirect != null) {
    fontDict = objects[int.parse(fontIndirect.group(1)!)]?.dict;
  } else {
    final inline = RegExp(r'/Font\s*<<').firstMatch(resources);
    if (inline != null) {
      final end = _dictEnd(resources, inline.end - 2);
      if (end > 0) fontDict = resources.substring(inline.end - 2, end);
    }
  }
  if (fontDict == null) return out;
  for (final match in RegExp(r'/([^\s/<>\[\]()]+)\s+(\d+)\s+\d+\s+R').allMatches(fontDict)) {
    final font = objects[int.parse(match.group(2)!)]?.dict;
    if (font == null) continue;
    final twoByte = font.contains('/Type0') || font.contains('Identity-H') || font.contains('Identity-V');
    final base = RegExp(r'/BaseFont\s*/([^\s/<>\[\]]+)').firstMatch(font)?.group(1) ?? '';
    final average = base.contains('Courier') ? 600.0 : (base.contains('Times') ? 480.0 : 520.0);
    final first = int.tryParse(RegExp(r'/FirstChar\s+(\d+)').firstMatch(font)?.group(1) ?? '') ?? 0;
    final widthsMatch = RegExp(r'/Widths\s*\[([^\]]*)\]').firstMatch(font);
    final widths = widthsMatch == null
        ? <double>[]
        : RegExp(r'-?[\d.]+').allMatches(widthsMatch.group(1)!).map((m) => double.tryParse(m.group(0)!) ?? average).toList();
    out[match.group(1)!] = _FontInfo(first, widths, average, twoByte);
  }
  return out;
}

class _Str {
  _Str(this.bytes, this.hex);
  final String bytes;
  final bool hex;
}

/// Every Tj / TJ string with its place (PDF points, bottom-left origin) and font size.
List<_Run2> _textRunsWithPlace(String s, Map<String, _FontInfo> fonts) {
  final runs = <_Run2>[];
  final operands = <Object>[];
  var ctm = <double>[1, 0, 0, 1, 0, 0];
  final stack = <List<double>>[];
  var tm = <double>[1, 0, 0, 1, 0, 0];
  var tlm = <double>[1, 0, 0, 1, 0, 0];
  var fontSize = 12.0;
  var leading = 0.0;
  var charSpace = 0.0;
  var wordSpace = 0.0;
  var scaleH = 1.0;
  _FontInfo? font;

  List<double> mul(List<double> a, List<double> b) => [
        a[0] * b[0] + a[1] * b[2],
        a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2],
        a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4],
        a[4] * b[1] + a[5] * b[3] + b[5],
      ];
  double arg(int fromEnd) {
    final index = operands.length - 1 - fromEnd;
    if (index < 0) return 0;
    final value = operands[index];
    return value is double ? value : 0;
  }

  void moveText(double tx, double ty) {
    tlm = mul([1, 0, 0, 1, tx, ty], tlm);
    tm = List<double>.of(tlm);
  }

  void show(_Str str) {
    final info = font;
    final twoByte = info?.twoByte ?? false;
    final codes = <int>[];
    if (twoByte) {
      for (var i = 0; i + 1 < str.bytes.length; i += 2) {
        codes.add((str.bytes.codeUnitAt(i) << 8) | str.bytes.codeUnitAt(i + 1));
      }
    } else {
      codes.addAll(str.bytes.codeUnits);
    }
    if (codes.isEmpty) return;
    var advance = 0.0;
    final chars = StringBuffer();
    var printable = 0;
    for (final code in codes) {
      var glyph = info?.average ?? 520.0;
      if (info != null && !twoByte && code >= info.first && code - info.first < info.widths.length) {
        final width = info.widths[code - info.first];
        if (width > 0) glyph = width;
      }
      advance += (glyph / 1000 * fontSize + charSpace + (code == 32 && !twoByte ? wordSpace : 0)) * scaleH;
      final char = code;
      if (char >= 32 && char != 127 && (char < 0xD800 || char > 0xDFFF)) {
        chars.writeCharCode(char);
        if ((char >= 0x30 && char <= 0x39) || (char >= 0x41 && char <= 0x5A) || (char >= 0x61 && char <= 0x7A) || char == 32 || char >= 0xC0) printable++;
      }
    }
    final m = mul(tm, ctm);
    final x0 = m[4];
    final y0 = m[5];
    final end = mul([1, 0, 0, 1, advance, 0], m);
    final size = fontSize * math.sqrt(m[2] * m[2] + m[3] * m[3]);
    final readable = !twoByte && codes.isNotEmpty && printable / codes.length >= 0.6;
    if (size > 0.5 && (m[1].abs() < 0.01 * (m[0].abs() + 1e-6))) {
      runs.add(_Run2(chars.toString(), math.min(x0, end[4]), math.max(x0, end[4]), y0, size, readable));
    }
    tm = mul([1, 0, 0, 1, advance / (scaleH == 0 ? 1 : scaleH), 0], tm);
  }

  var i = 0;
  final length = s.length;
  bool isWhite(int c) => c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0;
  bool isDelim(int c) => isWhite(c) || c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25;
  _Str hexString(int start, int stop) {
    final hex = s.substring(start, stop).replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final padded = hex.length.isOdd ? '${hex}0' : hex;
    final out = StringBuffer();
    for (var k = 0; k + 1 < padded.length; k += 2) {
      out.writeCharCode(int.parse(padded.substring(k, k + 2), radix: 16));
    }
    return _Str(out.toString(), true);
  }

  while (i < length) {
    final c = s.codeUnitAt(i);
    if (isWhite(c)) {
      i++;
      continue;
    }
    if (c == 0x25) {
      while (i < length && s.codeUnitAt(i) != 10 && s.codeUnitAt(i) != 13) {
        i++;
      }
      continue;
    }
    if (c == 0x28) {
      final literal = _literal(s, i);
      if (literal == null) {
        i++;
        continue;
      }
      operands.add(_Str(literal.text, false));
      i = literal.end;
      continue;
    }
    if (c == 0x3C) {
      if (i + 1 < length && s.codeUnitAt(i + 1) == 0x3C) {
        final end = _dictEnd(s, i);
        i = end < 0 ? length : end;
        operands.add(0.0);
        continue;
      }
      final close = s.indexOf('>', i + 1);
      if (close < 0) break;
      operands.add(hexString(i + 1, close));
      i = close + 1;
      continue;
    }
    if (c == 0x5B) {
      final items = <Object>[];
      i++;
      while (i < length && s.codeUnitAt(i) != 0x5D) {
        final d = s.codeUnitAt(i);
        if (isWhite(d)) {
          i++;
        } else if (d == 0x28) {
          final literal = _literal(s, i);
          if (literal == null) {
            i++;
            continue;
          }
          items.add(_Str(literal.text, false));
          i = literal.end;
        } else if (d == 0x3C) {
          final close = s.indexOf('>', i + 1);
          if (close < 0) {
            i = length;
            break;
          }
          items.add(hexString(i + 1, close));
          i = close + 1;
        } else {
          final start = i;
          while (i < length && !isDelim(s.codeUnitAt(i))) {
            i++;
          }
          if (i == start) i++;
          final value = double.tryParse(s.substring(start, i));
          if (value != null) items.add(value);
        }
      }
      i++;
      operands.add(items);
      continue;
    }
    if (c == 0x2F) {
      final start = ++i;
      while (i < length && !isDelim(s.codeUnitAt(i))) {
        i++;
      }
      operands.add(s.substring(start, i));
      continue;
    }
    final start = i;
    while (i < length && !isDelim(s.codeUnitAt(i))) {
      i++;
    }
    if (i == start) {
      i++;
      continue;
    }
    final token = s.substring(start, i);
    final number = double.tryParse(token);
    if (number != null) {
      operands.add(number);
      continue;
    }
    final last = operands.isEmpty ? null : operands.last;
    final fontName = operands.length >= 2 ? operands[operands.length - 2] : null;
    switch (token) {
      case 'q':
        stack.add(List<double>.of(ctm));
      case 'Q':
        if (stack.isNotEmpty) ctm = stack.removeLast();
      case 'cm':
        ctm = mul([arg(5), arg(4), arg(3), arg(2), arg(1), arg(0)], ctm);
      case 'BT':
        tm = [1, 0, 0, 1, 0, 0];
        tlm = [1, 0, 0, 1, 0, 0];
      case 'Tf':
        fontSize = arg(0);
        font = fontName is String ? fonts[fontName] : null;
      case 'TL':
        leading = arg(0);
      case 'Tc':
        charSpace = arg(0);
      case 'Tw':
        wordSpace = arg(0);
      case 'Tz':
        scaleH = arg(0) / 100;
      case 'Td':
        moveText(arg(1), arg(0));
      case 'TD':
        leading = -arg(0);
        moveText(arg(1), arg(0));
      case 'Tm':
        tm = [arg(5), arg(4), arg(3), arg(2), arg(1), arg(0)];
        tlm = List<double>.of(tm);
      case 'T*':
        moveText(0, -leading);
      case 'Tj':
        if (last is _Str) show(last);
      case "'":
        moveText(0, -leading);
        if (last is _Str) show(last);
      case '"':
        wordSpace = arg(2);
        charSpace = arg(1);
        moveText(0, -leading);
        if (last is _Str) show(last);
      case 'TJ':
        if (last is List<Object>) {
          for (final item in last) {
            if (item is _Str) {
              show(item);
            } else if (item is double) {
              tm = mul([1, 0, 0, 1, -item / 1000 * fontSize * scaleH, 0], tm);
            }
          }
        }
      case 'ID':
        // inline image data: skip to "EI"
        final stop = s.indexOf(RegExp(r'\sEI\s'), i);
        i = stop < 0 ? length : stop + 3;
    }
    operands.clear();
  }
  return runs;
}
