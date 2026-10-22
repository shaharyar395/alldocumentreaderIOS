import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

/// Converts a Word (.docx, also .doc / .rtf as text), PowerPoint (.pptx), Excel (.xlsx / .csv)
/// or text (.txt) file to a PDF, keeping the layout as well as possible:
/// * Word: page size and margins, paragraph styles, headings, lists, tables, pictures in place,
///   headers and footers, page breaks.
/// * PowerPoint: one page per slide, text boxes, shapes, pictures and tables where they are.
/// * Excel / CSV: table pages per sheet.
/// * TXT: paged text.
///
/// Runs in a background isolate; [onProgress] gets 0..1.
Future<Uint8List> officeFileToPdf(String path, {void Function(double progress)? onProgress}) async {
  final port = ReceivePort();
  final subscription = port.listen((message) {
    if (message is double) onProgress?.call(message);
  });
  try {
    final result = await _runConversion(path, port.sendPort);
    onProgress?.call(1);
    return result;
  } finally {
    await subscription.cancel();
    port.close();
  }
}

// Kept separate so the isolate closure only captures the path and the port.
Future<Uint8List> _runConversion(String path, SendPort port) => Isolate.run(() => _convertFile(path, port));

Future<Uint8List> _convertFile(String path, SendPort port) async {
  void progress(double value) => port.send(value.clamp(0.0, 1.0).toDouble());
  final bytes = await File(path).readAsBytes();
  progress(0.03);
  final lower = path.toLowerCase();
  final isZip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04;
  Archive? archive;
  if (isZip) {
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      archive = null;
    }
  }
  final fonts = _Fonts();
  _Job job;
  if (archive != null && archive.findFile('word/document.xml') != null) {
    job = _WordJob(archive);
  } else if (archive != null && archive.findFile('ppt/presentation.xml') != null) {
    job = _SlidesJob(archive);
  } else if (archive != null && archive.findFile('xl/workbook.xml') != null) {
    job = _SheetJob.xlsx(archive);
  } else if (lower.endsWith('.csv') || lower.endsWith('.tsv')) {
    job = _SheetJob.csv(_decodeText(bytes));
  } else if (_startsWith(bytes, '{\\rtf')) {
    job = _TextJob(_rtfToText(latin1.decode(bytes, allowInvalid: true)));
  } else if (lower.endsWith('.txt') || lower.endsWith('.text') || lower.endsWith('.log') || lower.endsWith('.md')) {
    job = _TextJob(_decodeText(bytes));
  } else {
    // older binary formats (.doc / .ppt / .xls): the readable text, paged
    job = _TextJob(_binaryText(bytes));
  }
  job.parse((value) => progress(0.05 + value * 0.35));
  progress(0.4);
  await fonts.load(job.allText());
  progress(0.45);
  // 1. full layout with every font; 2. without the extra fonts (text limited to Latin);
  // 3. plain text pages.
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      fonts.sanitize = attempt > 0 || fonts.fallback.isEmpty;
      final doc = pw.Document(compress: true);
      if (attempt < 2) {
        job.build(doc, fonts, (value) => progress(0.45 + value * 0.25));
      } else {
        _TextJob(job.allText()).build(doc, fonts, (_) {});
      }
      progress(0.72);
      final saved = await doc.save();
      progress(0.99);
      return saved;
    } catch (_) {
      if (attempt == 2) rethrow;
    }
  }
  throw StateError('conversion failed');
}

bool _startsWith(Uint8List bytes, String text) {
  if (bytes.length < text.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

String _decodeText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final little = bytes[0] == 0xFF;
    final codes = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      codes.add(little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(codes);
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// Readable text of an old binary Office file: runs of UTF-16 and 8-bit printable characters.
String _binaryText(Uint8List bytes) {
  final out = StringBuffer();
  final run = StringBuffer();
  void flush(int minimum) {
    if (run.length >= minimum) out.writeln(run.toString().trim());
    run.clear();
  }

  // UTF-16LE text (Word 97+ stores most text this way)
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final code = bytes[i] | (bytes[i + 1] << 8);
    if ((code >= 0x20 && code < 0xD800 && code != 0x7F) || code == 0x09) {
      run.writeCharCode(code);
    } else if (code == 0x0D || code == 0x0A || code == 0x0B) {
      flush(1);
    } else {
      flush(6);
    }
  }
  flush(6);
  if (out.length < 40) {
    out.clear();
    for (final byte in bytes) {
      if ((byte >= 0x20 && byte < 0x7F) || byte == 0x09) {
        run.writeCharCode(byte);
      } else if (byte == 0x0D || byte == 0x0A) {
        flush(1);
      } else {
        flush(6);
      }
    }
    flush(6);
  }
  return out.toString();
}

String _rtfToText(String rtf) {
  final out = StringBuffer();
  var depth = 0;
  final skipDepth = <int>[];
  var i = 0;
  while (i < rtf.length) {
    final c = rtf[i];
    if (c == '{') {
      depth++;
      if (i + 2 < rtf.length && rtf[i + 1] == r'\' && rtf[i + 2] == '*') skipDepth.add(depth);
      i++;
      continue;
    }
    if (c == '}') {
      if (skipDepth.isNotEmpty && skipDepth.last == depth) skipDepth.removeLast();
      depth--;
      i++;
      continue;
    }
    final skipping = skipDepth.isNotEmpty;
    if (c == r'\') {
      if (i + 1 >= rtf.length) break;
      final next = rtf[i + 1];
      if (next == '\\' || next == '{' || next == '}') {
        if (!skipping) out.write(next);
        i += 2;
        continue;
      }
      if (next == "'") {
        if (i + 3 < rtf.length && !skipping) {
          final code = int.tryParse(rtf.substring(i + 2, i + 4), radix: 16);
          if (code != null) out.writeCharCode(code);
        }
        i += 4;
        continue;
      }
      final match = RegExp(r'^\\([a-zA-Z]+)(-?\d+)? ?').firstMatch(rtf.substring(i, math.min(rtf.length, i + 40)));
      if (match == null) {
        i += 2;
        continue;
      }
      final word = match.group(1)!;
      if (!skipping) {
        if (word == 'par' || word == 'line') out.writeln();
        if (word == 'tab') out.write('\t');
        if (word == 'u') {
          final code = int.tryParse(match.group(2) ?? '');
          if (code != null) out.writeCharCode(code < 0 ? code + 65536 : code);
          // the next character is the ANSI stand-in
          i += match.end;
          if (i < rtf.length && rtf[i] != r'\' && rtf[i] != '{' && rtf[i] != '}') i++;
          continue;
        }
      }
      if (const {'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'header', 'footer', 'object'}.contains(word)) {
        skipDepth.add(depth);
      }
      i += match.end;
      continue;
    }
    if (!skipping && c != '\r' && c != '\n') out.write(c);
    i++;
  }
  return out.toString();
}

// ---------------------------------------------------------------------------------------------
// fonts
// ---------------------------------------------------------------------------------------------

class _Fonts {
  final List<pw.Font> fallback = [];
  bool sanitize = true;

  final pw.Font helvetica = pw.Font.helvetica();
  final pw.Font helveticaBold = pw.Font.helveticaBold();
  final pw.Font helveticaItalic = pw.Font.helveticaOblique();
  final pw.Font helveticaBoldItalic = pw.Font.helveticaBoldOblique();
  final pw.Font times = pw.Font.times();
  final pw.Font timesBold = pw.Font.timesBold();
  final pw.Font timesItalic = pw.Font.timesItalic();
  final pw.Font timesBoldItalic = pw.Font.timesBoldItalic();
  final pw.Font courier = pw.Font.courier();
  final pw.Font courierBold = pw.Font.courierBold();
  final pw.Font courierItalic = pw.Font.courierOblique();
  final pw.Font courierBoldItalic = pw.Font.courierBoldOblique();

  /// System fonts for characters the standard PDF fonts don't have (Android keeps them in
  /// /system/fonts; elsewhere nothing is found and such characters are left out).
  Future<void> load(String text) async {
    var needsLatinExt = false;
    var arabic = false;
    var hebrew = false;
    var thai = false;
    var devanagari = false;
    var cjk = false;
    for (final rune in text.runes) {
      if (rune < 0x100 || _winAnsiExtra.contains(rune)) continue;
      if (rune >= 0x0590 && rune <= 0x05FF) {
        hebrew = true;
      } else if ((rune >= 0x0600 && rune <= 0x06FF) || (rune >= 0xFB50 && rune <= 0xFEFF)) {
        arabic = true;
      } else if (rune >= 0x0E00 && rune <= 0x0E7F) {
        thai = true;
      } else if (rune >= 0x0900 && rune <= 0x097F) {
        devanagari = true;
      } else if ((rune >= 0x2E80 && rune <= 0x9FFF) || (rune >= 0xAC00 && rune <= 0xD7AF) || (rune >= 0xF900 && rune <= 0xFAFF) || (rune >= 0xFF00 && rune <= 0xFFEF)) {
        cjk = true;
      } else {
        needsLatinExt = true;
      }
    }
    const dir = '/system/fonts/';
    Future<void> add(List<String> names) async {
      for (final name in names) {
        final file = File('$dir$name');
        try {
          if (!await file.exists()) continue;
          final data = await file.readAsBytes();
          fallback.add(pw.Font.ttf(data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes)));
          return;
        } catch (_) {
          continue;
        }
      }
    }

    if (needsLatinExt || arabic || hebrew || thai || devanagari || cjk) {
      await add(['Roboto-Regular.ttf', 'RobotoStatic-Regular.ttf', 'NotoSans-Regular.ttf', 'DroidSans.ttf']);
    }
    if (arabic) await add(['NotoNaskhArabic-Regular.ttf', 'NotoSansArabic-Regular.ttf', 'DroidNaskh-Regular.ttf']);
    if (hebrew) await add(['NotoSansHebrew-Regular.ttf', 'DroidSansHebrew-Regular.ttf']);
    if (thai) await add(['NotoSansThai-Regular.ttf', 'NotoSerifThai-Regular.ttf', 'DroidSansThai.ttf']);
    if (devanagari) await add(['NotoSansDevanagari-Regular.ttf', 'NotoSansDevanagariUI-Regular.ttf']);
    if (cjk) await add(['DroidSansFallbackFull.ttf', 'DroidSansFallback.ttf', 'NotoSansSC-Regular.ttf']);
  }

  pw.Font pick(String? family, bool bold, bool italic) {
    final name = (family ?? '').toLowerCase();
    if (name.contains('courier') || name.contains('mono') || name.contains('consol')) {
      return bold ? (italic ? courierBoldItalic : courierBold) : (italic ? courierItalic : courier);
    }
    final serif = (name.contains('times') || name.contains('georgia') || name.contains('cambria') || name.contains('garamond') || name.contains('book') || name.contains('serif')) &&
        !name.contains('sans');
    if (serif) return bold ? (italic ? timesBoldItalic : timesBold) : (italic ? timesItalic : times);
    return bold ? (italic ? helveticaBoldItalic : helveticaBold) : (italic ? helveticaItalic : helvetica);
  }

  pw.ThemeData theme() => pw.ThemeData.withFont(
        base: helvetica,
        bold: helveticaBold,
        italic: helveticaItalic,
        boldItalic: helveticaBoldItalic,
        fontFallback: sanitize ? const [] : fallback,
      );

  /// The text the fonts can draw (when no extra fonts are used, other characters become '?').
  String clean(String text) {
    if (!sanitize) return text;
    final out = StringBuffer();
    for (final rune in text.runes) {
      if (rune == 0x09) {
        out.write('    ');
      } else if (rune < 0x20) {
        continue;
      } else if (rune < 0x100 || _winAnsiExtra.contains(rune)) {
        out.writeCharCode(rune);
      } else if (rune == 0x2010 || rune == 0x2011 || rune == 0x2212) {
        out.write('-');
      } else if (rune == 0x00A0 || rune == 0x2002 || rune == 0x2003 || rune == 0x2009) {
        out.write(' ');
      } else if (rune >= 0x25A0 && rune <= 0x25FF) {
        out.write('•');
      } else {
        out.write('?');
      }
    }
    return out.toString();
  }

  pw.TextStyle style({
    String? family,
    bool bold = false,
    bool italic = false,
    double size = 11,
    int? color,
    bool underline = false,
    bool strike = false,
    int? highlight,
    double lineSpacing = 0,
  }) {
    final decorations = <pw.TextDecoration>[
      if (underline) pw.TextDecoration.underline,
      if (strike) pw.TextDecoration.lineThrough,
    ];
    return pw.TextStyle(
      font: pick(family, bold, italic),
      fontSize: size,
      color: PdfColor.fromInt(0xFF000000 | (color ?? 0x000000)),
      decoration: decorations.isEmpty ? null : pw.TextDecoration.combine(decorations),
      background: highlight == null ? null : pw.BoxDecoration(color: PdfColor.fromInt(0xFF000000 | highlight)),
      lineSpacing: lineSpacing,
      fontFallback: sanitize ? const [] : fallback,
    );
  }
}

const _winAnsiExtra = <int>{
  0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x017D, //
  0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x017E, 0x0178,
};

// ---------------------------------------------------------------------------------------------
// jobs
// ---------------------------------------------------------------------------------------------

abstract class _Job {
  void parse(void Function(double progress) progress);
  String allText();
  void build(pw.Document doc, _Fonts fonts, void Function(double progress) progress);
}

/// Splits [text] into pieces of at most [limit] characters at spaces (very long paragraphs
/// would not fit on one page as one piece).
List<String> _chunks(String text, int limit) {
  if (text.length <= limit) return [text];
  final out = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = math.min(text.length, start + limit);
    if (end < text.length) {
      final space = text.lastIndexOf(' ', end);
      if (space > start + limit ~/ 2) end = space + 1;
    }
    out.add(text.substring(start, end));
    start = end;
  }
  return out;
}

// ------------------------------------------------------------------ text

class _TextJob extends _Job {
  _TextJob(this.text);

  final String text;

  @override
  void parse(void Function(double progress) progress) => progress(1);

  @override
  String allText() => text;

  @override
  void build(pw.Document doc, _Fonts fonts, void Function(double progress) progress) {
    final style = fonts.style(size: 11, lineSpacing: 2);
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(48, 48, 48, 48),
        theme: fonts.theme(),
        maxPages: 5000,
        build: (context) => [
          for (final line in lines)
            if (line.trim().isEmpty)
              pw.SizedBox(height: 13)
            else
              for (final piece in _chunks(fonts.clean(line), 1500)) pw.Text(piece, style: style),
        ],
      ),
    );
    progress(1);
  }
}

// ------------------------------------------------------------------ helpers for OOXML

Iterable<XmlElement> _kids(XmlElement? node, String local) =>
    node == null ? const <XmlElement>[] : node.childElements.where((element) => element.name.local == local);

XmlElement? _kid(XmlElement? node, String local) {
  if (node == null) return null;
  for (final element in node.childElements) {
    if (element.name.local == local) return element;
  }
  return null;
}

Iterable<XmlElement> _desc(XmlElement? node, String local) =>
    node == null ? const <XmlElement>[] : node.descendants.whereType<XmlElement>().where((element) => element.name.local == local);

String? _att(XmlElement? node, String local) {
  if (node == null) return null;
  for (final attribute in node.attributes) {
    if (attribute.name.local == local) return attribute.value;
  }
  return null;
}

double? _attNum(XmlElement? node, String local) => double.tryParse(_att(node, local) ?? '');

/// w:b, w:i …: present = on unless val is 0 / false / off / none.
bool? _onOff(XmlElement? node) {
  if (node == null) return null;
  final value = _att(node, 'val');
  if (value == null) return true;
  return !(value == '0' || value == 'false' || value == 'off' || value == 'none');
}

XmlDocument? _xml(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file == null) return null;
  try {
    return XmlDocument.parse(utf8.decode(file.content as List<int>, allowMalformed: true));
  } catch (_) {
    return null;
  }
}

Uint8List? _bytes(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file == null) return null;
  return Uint8List.fromList(file.content as List<int>);
}

Map<String, String> _rels(Archive archive, String name) {
  final xml = _xml(archive, name);
  final map = <String, String>{};
  if (xml == null) return map;
  for (final rel in xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'Relationship')) {
    final id = rel.getAttribute('Id');
    final target = rel.getAttribute('Target');
    if (id != null && target != null && rel.getAttribute('TargetMode') != 'External') map[id] = target;
  }
  return map;
}

String _resolvePath(String baseDir, String target) {
  final cleaned = target.replaceAll('\\', '/');
  if (cleaned.startsWith('/')) return cleaned.substring(1);
  final parts = <String>[];
  for (final part in '$baseDir/$cleaned'.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return parts.join('/');
}

String _relsPathOf(String part) {
  final slash = part.lastIndexOf('/');
  final dir = slash < 0 ? '' : part.substring(0, slash);
  final file = slash < 0 ? part : part.substring(slash + 1);
  return dir.isEmpty ? '_rels/$file.rels' : '$dir/_rels/$file.rels';
}

String _dirOf(String part) {
  final slash = part.lastIndexOf('/');
  return slash < 0 ? '' : part.substring(0, slash);
}

int? _hexColor(String? value) {
  if (value == null || value == 'auto' || value.length != 6) return null;
  return int.tryParse(value, radix: 16);
}

const _highlightColors = <String, int>{
  'yellow': 0xFFFF00,
  'green': 0x00FF00,
  'cyan': 0x00FFFF,
  'magenta': 0xFF00FF,
  'blue': 0x0000FF,
  'red': 0xFF0000,
  'darkBlue': 0x000080,
  'darkCyan': 0x008080,
  'darkGreen': 0x008000,
  'darkMagenta': 0x800080,
  'darkRed': 0x800000,
  'darkYellow': 0x808000,
  'darkGray': 0x808080,
  'lightGray': 0xC0C0C0,
  'black': 0x000000,
  'white': 0xFFFFFF,
};

pw.ImageProvider? _imageProvider(Uint8List? bytes) {
  if (bytes == null || bytes.length < 8) return null;
  try {
    final image = pw.MemoryImage(bytes);
    if ((image.width ?? 0) <= 0 || (image.height ?? 0) <= 0) return null;
    return image;
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------ Word

class _RunStyle {
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? caps;
  double? size;
  int? color;
  String? family;
  int? highlight;
  int? vert;

  _RunStyle merged(_RunStyle? other) {
    if (other == null) return this;
    return _RunStyle()
      ..bold = other.bold ?? bold
      ..italic = other.italic ?? italic
      ..underline = other.underline ?? underline
      ..strike = other.strike ?? strike
      ..caps = other.caps ?? caps
      ..size = other.size ?? size
      ..color = other.color ?? color
      ..family = other.family ?? family
      ..highlight = other.highlight ?? highlight
      ..vert = other.vert ?? vert;
  }

  static _RunStyle parse(XmlElement? rPr) {
    final style = _RunStyle();
    if (rPr == null) return style;
    style.bold = _onOff(_kid(rPr, 'b'));
    style.italic = _onOff(_kid(rPr, 'i'));
    final u = _kid(rPr, 'u');
    if (u != null) style.underline = _att(u, 'val') != 'none';
    style.strike = _onOff(_kid(rPr, 'strike')) ?? _onOff(_kid(rPr, 'dstrike'));
    style.caps = _onOff(_kid(rPr, 'caps'));
    final sz = _attNum(_kid(rPr, 'sz'), 'val');
    if (sz != null) style.size = sz / 2;
    style.color = _hexColor(_att(_kid(rPr, 'color'), 'val'));
    final fonts = _kid(rPr, 'rFonts');
    style.family = _att(fonts, 'ascii') ?? _att(fonts, 'hAnsi') ?? _att(fonts, 'cs');
    final highlight = _att(_kid(rPr, 'highlight'), 'val');
    if (highlight != null && highlight != 'none') style.highlight = _highlightColors[highlight];
    final shade = _hexColor(_att(_kid(rPr, 'shd'), 'fill'));
    if (shade != null && style.highlight == null && shade != 0xFFFFFF) style.highlight = shade;
    final vert = _att(_kid(rPr, 'vertAlign'), 'val');
    if (vert == 'superscript') style.vert = 1;
    if (vert == 'subscript') style.vert = -1;
    return style;
  }
}

class _ParaStyle {
  String? align;
  double? before;
  double? after;
  double? left;
  double? right;
  double? firstLine;
  double? hanging;
  double? line;
  String? lineRule;
  int? shade;
  bool? pageBreakBefore;
  String? numId;
  int? ilvl;

  _ParaStyle merged(_ParaStyle? other) {
    if (other == null) return this;
    return _ParaStyle()
      ..align = other.align ?? align
      ..before = other.before ?? before
      ..after = other.after ?? after
      ..left = other.left ?? left
      ..right = other.right ?? right
      ..firstLine = other.firstLine ?? (other.hanging != null ? null : firstLine)
      ..hanging = other.hanging ?? (other.firstLine != null ? null : hanging)
      ..line = other.line ?? line
      ..lineRule = other.lineRule ?? lineRule
      ..shade = other.shade ?? shade
      ..pageBreakBefore = other.pageBreakBefore ?? pageBreakBefore
      ..numId = other.numId ?? numId
      ..ilvl = other.ilvl ?? ilvl;
  }

  static _ParaStyle parse(XmlElement? pPr) {
    final style = _ParaStyle();
    if (pPr == null) return style;
    style.align = _att(_kid(pPr, 'jc'), 'val');
    final spacing = _kid(pPr, 'spacing');
    if (spacing != null) {
      final before = _attNum(spacing, 'before');
      final after = _attNum(spacing, 'after');
      if (before != null) style.before = before / 20;
      if (after != null) style.after = after / 20;
      if (_att(spacing, 'beforeAutospacing') == '1') style.before = 14;
      if (_att(spacing, 'afterAutospacing') == '1') style.after = 14;
      final line = _attNum(spacing, 'line');
      if (line != null) {
        style.line = line;
        style.lineRule = _att(spacing, 'lineRule') ?? 'auto';
      }
    }
    final ind = _kid(pPr, 'ind');
    if (ind != null) {
      final left = _attNum(ind, 'left') ?? _attNum(ind, 'start');
      final right = _attNum(ind, 'right') ?? _attNum(ind, 'end');
      final first = _attNum(ind, 'firstLine');
      final hanging = _attNum(ind, 'hanging');
      if (left != null) style.left = left / 20;
      if (right != null) style.right = right / 20;
      if (first != null) style.firstLine = first / 20;
      if (hanging != null) style.hanging = hanging / 20;
    }
    final shade = _hexColor(_att(_kid(pPr, 'shd'), 'fill'));
    if (shade != null && shade != 0xFFFFFF) style.shade = shade;
    style.pageBreakBefore = _onOff(_kid(pPr, 'pageBreakBefore'));
    final numPr = _kid(pPr, 'numPr');
    if (numPr != null) {
      style.numId = _att(_kid(numPr, 'numId'), 'val');
      style.ilvl = int.tryParse(_att(_kid(numPr, 'ilvl'), 'val') ?? '');
    }
    return style;
  }
}

class _StyleDef {
  _StyleDef(this.basedOn, this.run, this.para, this.borders);
  final String? basedOn;
  final _RunStyle run;
  final _ParaStyle para;
  final bool borders;
}

class _Level {
  _Level(this.format, this.text, this.start, this.left, this.hanging);
  final String format;
  final String text;
  final int start;
  final double? left;
  final double? hanging;
}

/// A piece of a paragraph: text in a style, a picture, or a page break.
class _Seg {
  _Seg.text(this.text, this.style)
      : image = null,
        width = 0,
        height = 0,
        pageBreak = false;
  _Seg.image(this.image, this.width, this.height)
      : text = '',
        style = null,
        pageBreak = false;
  _Seg.pageBreak()
      : text = '',
        style = null,
        image = null,
        width = 0,
        height = 0,
        pageBreak = true;

  final String text;
  final _RunStyle? style;
  final Uint8List? image;
  final double width;
  final double height;
  final bool pageBreak;
}

class _WPara {
  _WPara(this.segs, this.style, this.prefix, this.size);
  final List<_Seg> segs;
  final _ParaStyle style;
  final String? prefix;
  final double size;

  String get plain => segs.map((seg) => seg.text).join();
}

class _WCell {
  _WCell(this.blocks, this.span, this.fill, this.merged);
  final List<Object> blocks;
  final int span;
  final int? fill;
  final bool merged;
}

class _WTable {
  _WTable(this.grid, this.rows, this.borders, this.indent);
  final List<double> grid;
  final List<List<_WCell>> rows;
  final bool borders;
  final double indent;
}

class _PageBreak {
  const _PageBreak();
}

class _WordJob extends _Job {
  _WordJob(this.archive);

  final Archive archive;
  final Map<String, _StyleDef> _styles = {};
  final Map<String, _RunStyle> _resolvedRun = {};
  final Map<String, _ParaStyle> _resolvedPara = {};
  _RunStyle _defaultRun = _RunStyle();
  _ParaStyle _defaultPara = _ParaStyle();
  String? _defaultParaStyle;
  final Map<String, List<_Level?>> _abstract = {};
  final Map<String, String> _numToAbstract = {};
  final Map<String, List<int>> _counters = {};
  Map<String, String> _docRels = {};

  final List<Object> blocks = [];
  final List<Object> header = [];
  final List<Object> footer = [];
  double pageWidth = 595;
  double pageHeight = 842;
  double marginTop = 72;
  double marginBottom = 72;
  double marginLeft = 72;
  double marginRight = 72;
  double headerDistance = 36;
  double footerDistance = 36;
  final StringBuffer _text = StringBuffer();

  @override
  String allText() => _text.toString();

  @override
  void parse(void Function(double progress) progress) {
    _readStyles();
    _readNumbering();
    _docRels = _rels(archive, 'word/_rels/document.xml.rels');
    final document = _xml(archive, 'word/document.xml');
    final body = document == null ? null : _desc(document.rootElement, 'body').firstOrNull;
    if (body == null) return;
    final sect = _kid(body, 'sectPr');
    _readSection(sect);
    final children = body.childElements.toList();
    for (var i = 0; i < children.length; i++) {
      _block(children[i], blocks, _docRels, 'word');
      if (i % 20 == 0) progress(i / children.length);
    }
    // header / footer of the main section
    for (final kind in const ['headerReference', 'footerReference']) {
      final refs = _kids(sect, kind).toList();
      final ref = refs.where((r) => _att(r, 'type') == 'default').firstOrNull ?? refs.firstOrNull;
      final id = _att(ref, 'id');
      final target = id == null ? null : _docRels[id];
      if (target == null) continue;
      final part = _resolvePath('word', target);
      final xml = _xml(archive, part);
      if (xml == null) continue;
      final partRels = _rels(archive, _relsPathOf(part));
      final into = kind == 'headerReference' ? header : footer;
      for (final child in xml.rootElement.childElements) {
        _block(child, into, partRels, _dirOf(part));
      }
    }
  }

  void _readSection(XmlElement? sect) {
    final size = _kid(sect, 'pgSz');
    final w = _attNum(size, 'w');
    final h = _attNum(size, 'h');
    if (w != null && h != null && w > 1000 && h > 1000) {
      pageWidth = w / 20;
      pageHeight = h / 20;
    } else {
      pageWidth = PdfPageFormat.a4.width;
      pageHeight = PdfPageFormat.a4.height;
    }
    final margins = _kid(sect, 'pgMar');
    if (margins != null) {
      marginTop = ((_attNum(margins, 'top') ?? 1440).abs() / 20).clamp(0.0, pageHeight / 3);
      marginBottom = ((_attNum(margins, 'bottom') ?? 1440).abs() / 20).clamp(0.0, pageHeight / 3);
      marginLeft = ((_attNum(margins, 'left') ?? 1440) / 20).clamp(0.0, pageWidth / 3);
      marginRight = ((_attNum(margins, 'right') ?? 1440) / 20).clamp(0.0, pageWidth / 3);
      headerDistance = ((_attNum(margins, 'header') ?? 720) / 20).clamp(0.0, marginTop);
      footerDistance = ((_attNum(margins, 'footer') ?? 720) / 20).clamp(0.0, marginBottom);
    }
  }

  void _readStyles() {
    final xml = _xml(archive, 'word/styles.xml');
    if (xml == null) {
      _defaultRun = _RunStyle()..size = 11;
      _defaultPara = _ParaStyle();
      return;
    }
    final defaults = _desc(xml.rootElement, 'docDefaults').firstOrNull;
    _defaultRun = _RunStyle()..size = 11;
    _defaultRun = _defaultRun.merged(_RunStyle.parse(_kid(_desc(defaults, 'rPrDefault').firstOrNull, 'rPr')));
    _defaultPara = _ParaStyle.parse(_kid(_desc(defaults, 'pPrDefault').firstOrNull, 'pPr'));
    for (final style in _kids(xml.rootElement, 'style')) {
      final id = _att(style, 'styleId');
      if (id == null) continue;
      if (_att(style, 'type') == 'paragraph' && (_att(style, 'default') == '1' || _att(style, 'default') == 'true')) {
        _defaultParaStyle = id;
      }
      final tblPr = _kid(style, 'tblPr');
      final borders = _kid(tblPr, 'tblBorders');
      final hasBorders = borders != null && borders.childElements.any((b) => _att(b, 'val') != 'nil' && _att(b, 'val') != 'none');
      final run = _RunStyle.parse(_kid(style, 'rPr'));
      final name = (_att(_kid(style, 'name'), 'val') ?? id).toLowerCase();
      final heading = RegExp(r'^heading ?(\d)').firstMatch(name);
      if (heading != null || name == 'title') {
        final level = heading == null ? 0 : (int.tryParse(heading.group(1) ?? '') ?? 0);
        run.size ??= switch (level) { 0 => 26.0, 1 => 20.0, 2 => 16.0, 3 => 14.0, _ => 12.0 };
        run.bold ??= true;
      }
      _styles[id] = _StyleDef(_att(_kid(style, 'basedOn'), 'val'), run, _ParaStyle.parse(_kid(style, 'pPr')), hasBorders);
    }
  }

  _RunStyle _styleRun(String? id, [int depth = 0]) {
    if (id == null || depth > 12) return _RunStyle();
    final cached = _resolvedRun[id];
    if (cached != null) return cached;
    final def = _styles[id];
    if (def == null) return _RunStyle();
    final resolved = _styleRun(def.basedOn, depth + 1).merged(def.run);
    _resolvedRun[id] = resolved;
    return resolved;
  }

  _ParaStyle _stylePara(String? id, [int depth = 0]) {
    if (id == null || depth > 12) return _ParaStyle();
    final cached = _resolvedPara[id];
    if (cached != null) return cached;
    final def = _styles[id];
    if (def == null) return _ParaStyle();
    final resolved = _stylePara(def.basedOn, depth + 1).merged(def.para);
    _resolvedPara[id] = resolved;
    return resolved;
  }

  bool _styleBorders(String? id, [int depth = 0]) {
    if (id == null || depth > 12) return false;
    final def = _styles[id];
    if (def == null) return false;
    return def.borders || _styleBorders(def.basedOn, depth + 1);
  }

  void _readNumbering() {
    final xml = _xml(archive, 'word/numbering.xml');
    if (xml == null) return;
    for (final node in _kids(xml.rootElement, 'abstractNum')) {
      final id = _att(node, 'abstractNumId');
      if (id == null) continue;
      final levels = List<_Level?>.filled(9, null);
      for (final level in _kids(node, 'lvl')) {
        final index = int.tryParse(_att(level, 'ilvl') ?? '') ?? 0;
        if (index < 0 || index > 8) continue;
        final ind = _kid(_kid(level, 'pPr'), 'ind');
        levels[index] = _Level(
          _att(_kid(level, 'numFmt'), 'val') ?? 'decimal',
          _att(_kid(level, 'lvlText'), 'val') ?? '%${index + 1}.',
          int.tryParse(_att(_kid(level, 'start'), 'val') ?? '') ?? 1,
          _attNum(ind, 'left') == null ? (_attNum(ind, 'start') == null ? null : _attNum(ind, 'start')! / 20) : _attNum(ind, 'left')! / 20,
          _attNum(ind, 'hanging') == null ? null : _attNum(ind, 'hanging')! / 20,
        );
      }
      _abstract[id] = levels;
    }
    for (final node in _kids(xml.rootElement, 'num')) {
      final id = _att(node, 'numId');
      final abstractId = _att(_kid(node, 'abstractNumId'), 'val');
      if (id != null && abstractId != null) _numToAbstract[id] = abstractId;
    }
  }

  /// The list marker for a paragraph in list [numId] at level [ilvl] (counting as it goes).
  (String, _Level?)? _listPrefix(String? numId, int ilvl) {
    if (numId == null || numId == '0') return null;
    final abstractId = _numToAbstract[numId];
    final levels = abstractId == null ? null : _abstract[abstractId];
    final level = levels == null ? null : levels[ilvl.clamp(0, 8)];
    if (level == null) return ('•', null);
    final counters = _counters.putIfAbsent(abstractId!, () => List<int>.filled(9, 0));
    final index = ilvl.clamp(0, 8);
    counters[index] = counters[index] == 0 ? level.start : counters[index] + 1;
    for (var deeper = index + 1; deeper < 9; deeper++) {
      counters[deeper] = 0;
    }
    if (level.format == 'none') return ('', level);
    if (level.format == 'bullet') {
      final raw = level.text;
      final code = raw.isEmpty ? 0x2022 : raw.runes.first;
      final bullet = code >= 0xF000 || code == 0x6F || code == 0xA7 || code == 0xFC || code == 0xD8 ? '•' : String.fromCharCode(code);
      return (bullet, level);
    }
    var text = level.text;
    for (var k = 0; k < 9; k++) {
      if (!text.contains('%${k + 1}')) continue;
      final lvl = levels![k];
      final value = counters[k] == 0 ? (lvl?.start ?? 1) : counters[k];
      text = text.replaceAll('%${k + 1}', _formatNumber(value, lvl?.format ?? 'decimal'));
    }
    return (text, level);
  }

  void _block(XmlElement node, List<Object> into, Map<String, String> rels, String baseDir) {
    switch (node.name.local) {
      case 'p':
        _paragraph(node, into, rels, baseDir);
      case 'tbl':
        final table = _table(node, rels, baseDir);
        if (table != null) into.add(table);
      case 'sdt':
        for (final child in _kid(node, 'sdtContent')?.childElements ?? const <XmlElement>[]) {
          _block(child, into, rels, baseDir);
        }
      case 'customXml':
      case 'smartTag':
        for (final child in node.childElements) {
          _block(child, into, rels, baseDir);
        }
    }
  }

  void _paragraph(XmlElement node, List<Object> into, Map<String, String> rels, String baseDir) {
    final pPr = _kid(node, 'pPr');
    final styleId = _att(_kid(pPr, 'pStyle'), 'val') ?? _defaultParaStyle;
    final paraStyle = _defaultPara.merged(_stylePara(styleId)).merged(_ParaStyle.parse(pPr));
    final baseRun = _defaultRun.merged(_styleRun(styleId)).merged(_RunStyle.parse(_kid(pPr, 'rPr')).._clearLayoutOnly());
    final segs = <_Seg>[];
    final extra = <Object>[];
    _runs(node, segs, extra, _defaultRun.merged(_styleRun(styleId)), rels, baseDir, styleId);
    final listed = _listPrefix(paraStyle.numId, paraStyle.ilvl ?? 0);
    var style = paraStyle;
    if (listed != null && listed.$2 != null) {
      final level = listed.$2!;
      final direct = _ParaStyle.parse(pPr);
      style = style.merged(_ParaStyle()
        ..left = direct.left ?? level.left ?? style.left
        ..hanging = direct.hanging ?? level.hanging ?? style.hanging);
    }
    var size = baseRun.size ?? 11.0;
    for (final seg in segs) {
      final s = seg.style?.size;
      if (s != null && seg.text.trim().isNotEmpty) {
        size = s;
        break;
      }
    }
    if (style.pageBreakBefore == true) into.add(const _PageBreak());
    // split at page breaks
    var current = <_Seg>[];
    void emit() {
      final para = _WPara(current, style, listed?.$1, size);
      into.add(para);
      _text.writeln(para.plain);
      current = <_Seg>[];
    }

    for (final seg in segs) {
      if (seg.pageBreak) {
        emit();
        into.add(const _PageBreak());
        continue;
      }
      current.add(seg);
    }
    emit();
    into.addAll(extra);
    if (pPr != null && _kid(pPr, 'sectPr') != null) {
      final type = _att(_kid(_kid(pPr, 'sectPr'), 'type'), 'val');
      if (type != 'continuous') into.add(const _PageBreak());
    }
  }

  void _runs(XmlElement node, List<_Seg> segs, List<Object> extra, _RunStyle paraRun, Map<String, String> rels, String baseDir, String? styleId) {
    var inField = false;
    for (final child in node.childElements) {
      switch (child.name.local) {
        case 'r':
          inField = _run(child, segs, extra, paraRun, rels, baseDir, inField);
        case 'hyperlink':
        case 'ins':
        case 'smartTag':
        case 'fldSimple':
        case 'customXml':
        case 'bdo':
        case 'dir':
          _runs(child, segs, extra, paraRun, rels, baseDir, styleId);
        case 'sdt':
          final content = _kid(child, 'sdtContent');
          if (content != null) _runs(content, segs, extra, paraRun, rels, baseDir, styleId);
        case 'AlternateContent':
          final choice = _kid(child, 'Choice') ?? _kid(child, 'Fallback');
          if (choice != null) _runs(choice, segs, extra, paraRun, rels, baseDir, styleId);
      }
    }
  }

  /// Returns whether a field's instructions are still running (their text is not shown).
  bool _run(XmlElement run, List<_Seg> segs, List<Object> extra, _RunStyle paraRun, Map<String, String> rels, String baseDir, bool inField) {
    final rPr = _kid(run, 'rPr');
    final charStyle = _att(_kid(rPr, 'rStyle'), 'val');
    final style = paraRun.merged(_styleRun(charStyle)).merged(_RunStyle.parse(rPr));
    var field = inField;
    final text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      segs.add(_Seg.text(style.caps == true ? text.toString().toUpperCase() : text.toString(), style));
      text.clear();
    }

    for (final child in run.childElements) {
      switch (child.name.local) {
        case 'fldChar':
          final type = _att(child, 'fldCharType');
          if (type == 'begin') field = true;
          if (type == 'separate' || type == 'end') field = false;
        case 't':
          if (!field) text.write(child.innerText);
        case 'tab':
        case 'ptab':
          text.write('    ');
        case 'br':
          if (_att(child, 'type') == 'page') {
            flushText();
            segs.add(_Seg.pageBreak());
          } else {
            text.write('\n');
          }
        case 'cr':
          text.write('\n');
        case 'noBreakHyphen':
          text.write('-');
        case 'sym':
          final code = int.tryParse(_att(child, 'char') ?? '', radix: 16);
          if (code != null) text.write(code >= 0xF000 ? '•' : String.fromCharCode(code));
        case 'drawing':
          flushText();
          _drawing(child, segs, extra, rels, baseDir);
        case 'pict':
        case 'object':
          flushText();
          _vml(child, segs, extra, rels, baseDir);
        case 'AlternateContent':
          flushText();
          final choice = _kid(child, 'Choice');
          final fallback = _kid(child, 'Fallback');
          final drawing = _desc(choice, 'drawing').firstOrNull;
          if (drawing != null) {
            _drawing(drawing, segs, extra, rels, baseDir);
          } else if (fallback != null) {
            _vml(fallback, segs, extra, rels, baseDir);
          }
      }
    }
    flushText();
    return field;
  }

  void _drawing(XmlElement drawing, List<_Seg> segs, List<Object> extra, Map<String, String> rels, String baseDir) {
    final extent = _desc(drawing, 'extent').firstOrNull;
    final cx = _attNum(extent, 'cx') ?? 0;
    final cy = _attNum(extent, 'cy') ?? 0;
    final blip = _desc(drawing, 'blip').firstOrNull;
    final id = _att(blip, 'embed');
    if (id != null) {
      final target = rels[id];
      final bytes = target == null ? null : _bytes(archive, _resolvePath(baseDir, target));
      if (bytes != null && cx > 0 && cy > 0) segs.add(_Seg.image(bytes, cx / 12700, cy / 12700));
    }
    for (final box in _desc(drawing, 'txbxContent')) {
      for (final child in box.childElements) {
        _block(child, extra, rels, baseDir);
      }
    }
  }

  void _vml(XmlElement node, List<_Seg> segs, List<Object> extra, Map<String, String> rels, String baseDir) {
    final data = _desc(node, 'imagedata').firstOrNull;
    final id = _att(data, 'id');
    if (id != null) {
      final target = rels[id];
      final bytes = target == null ? null : _bytes(archive, _resolvePath(baseDir, target));
      final shape = data!.parentElement;
      final css = _att(shape, 'style') ?? '';
      double? measure(String key) {
        final match = RegExp('$key:([0-9.]+)(pt|in|px|cm|mm)?').firstMatch(css);
        if (match == null) return null;
        final value = double.tryParse(match.group(1)!) ?? 0.0;
        return switch (match.group(2)) {
          'in' => value * 72,
          'cm' => value * 72 / 2.54,
          'mm' => value * 72 / 25.4,
          'px' => value * 0.75,
          _ => value,
        };
      }

      final width = measure('width') ?? 200.0;
      final height = measure('height') ?? 150.0;
      if (bytes != null) segs.add(_Seg.image(bytes, width, height));
    }
    for (final box in _desc(node, 'txbxContent')) {
      for (final child in box.childElements) {
        _block(child, extra, rels, baseDir);
      }
    }
  }

  _WTable? _table(XmlElement node, Map<String, String> rels, String baseDir) {
    final tblPr = _kid(node, 'tblPr');
    final grid = [for (final col in _kids(_kid(node, 'tblGrid'), 'gridCol')) (_attNum(col, 'w') ?? 0) / 20];
    final styleId = _att(_kid(tblPr, 'tblStyle'), 'val');
    final borders = _kid(tblPr, 'tblBorders');
    bool bordered;
    if (borders != null) {
      bordered = borders.childElements.any((b) => _att(b, 'val') != 'nil' && _att(b, 'val') != 'none');
    } else {
      bordered = _styleBorders(styleId);
    }
    final indent = (_attNum(_kid(tblPr, 'tblInd'), 'w') ?? 0) / 20;
    final rows = <List<_WCell>>[];
    for (final row in _kids(node, 'tr')) {
      final cells = <_WCell>[];
      for (final cell in _kids(row, 'tc')) {
        final tcPr = _kid(cell, 'tcPr');
        final span = int.tryParse(_att(_kid(tcPr, 'gridSpan'), 'val') ?? '') ?? 1;
        final vMerge = _kid(tcPr, 'vMerge');
        final merged = vMerge != null && _att(vMerge, 'val') != 'restart';
        final fill = _hexColor(_att(_kid(tcPr, 'shd'), 'fill'));
        final content = <Object>[];
        if (!merged) {
          for (final child in cell.childElements) {
            _block(child, content, rels, baseDir);
          }
        }
        cells.add(_WCell(content, span < 1 ? 1 : span, fill == 0xFFFFFF ? null : fill, merged));
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    var columns = grid.length;
    for (final row in rows) {
      columns = math.max(columns, row.fold<int>(0, (sum, cell) => sum + cell.span));
    }
    final widths = List<double>.generate(columns, (i) => i < grid.length && grid[i] > 0 ? grid[i] : 0);
    if (widths.every((w) => w == 0)) {
      for (var i = 0; i < columns; i++) {
        widths[i] = 1;
      }
    } else {
      final known = widths.where((w) => w > 0);
      final average = known.isEmpty ? 1.0 : known.reduce((a, b) => a + b) / known.length;
      for (var i = 0; i < columns; i++) {
        if (widths[i] == 0) widths[i] = average;
      }
    }
    return _WTable(widths, rows, bordered, indent);
  }

  // -------------------------------------------------------------- layout

  @override
  void build(pw.Document doc, _Fonts fonts, void Function(double progress) progress) {
    final contentWidth = math.max(100.0, pageWidth - marginLeft - marginRight);
    final widgets = <pw.Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      widgets.addAll(_widgets(blocks[i], fonts, contentWidth));
      if (i % 25 == 0) progress(i / math.max(1, blocks.length));
    }
    if (widgets.isEmpty) widgets.add(pw.SizedBox(height: 1));
    // header / footer widgets are made again for every page (a widget is laid out once per page)
    List<pw.Widget> headerWidgetsNow() => <pw.Widget>[for (final block in header) ..._widgets(block, fonts, contentWidth).where((w) => w is! pw.NewPage)];
    List<pw.Widget> footerWidgetsNow() => <pw.Widget>[for (final block in footer) ..._widgets(block, fonts, contentWidth).where((w) => w is! pw.NewPage)];
    final headerWidgets = headerWidgetsNow();
    final footerWidgets = footerWidgetsNow();
    final top = headerWidgets.isEmpty ? marginTop : math.min(headerDistance, marginTop);
    final bottom = footerWidgets.isEmpty ? marginBottom : math.min(footerDistance, marginBottom);
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat(pageWidth, pageHeight),
        margin: pw.EdgeInsets.fromLTRB(marginLeft, top, marginRight, bottom),
        theme: fonts.theme(),
        maxPages: 5000,
        header: headerWidgets.isEmpty
            ? null
            : (context) => pw.Container(
                  constraints: pw.BoxConstraints(minHeight: math.max(0.0, marginTop - top)),
                  alignment: pw.Alignment.topLeft,
                  child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: headerWidgetsNow()),
                ),
        footer: footerWidgets.isEmpty
            ? null
            : (context) => pw.Container(
                  constraints: pw.BoxConstraints(minHeight: math.max(0.0, marginBottom - bottom)),
                  alignment: pw.Alignment.bottomLeft,
                  child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, mainAxisSize: pw.MainAxisSize.min, children: footerWidgetsNow()),
                ),
        build: (context) => widgets,
      ),
    );
    progress(1);
  }

  List<pw.Widget> _widgets(Object block, _Fonts fonts, double width) {
    if (block is _PageBreak) return [pw.NewPage()];
    if (block is _WPara) return _paraWidgets(block, fonts, width);
    if (block is _WTable) return _tableWidgets(block, fonts, width);
    return const [];
  }

  List<pw.Widget> _paraWidgets(_WPara para, _Fonts fonts, double width) {
    final style = para.style;
    final before = (style.before ?? 0.0).clamp(0.0, 200.0);
    final after = (style.after ?? 0.0).clamp(0.0, 200.0);
    final left = (style.left ?? 0.0).clamp(-72.0, width * 0.8);
    final right = (style.right ?? 0.0).clamp(-72.0, width * 0.8);
    final hanging = style.hanging ?? 0.0;
    final firstLine = style.firstLine ?? 0.0;
    final size = para.size;
    var lineSpacing = 0.0;
    final line = style.line;
    if (line != null) {
      if ((style.lineRule ?? 'auto') == 'auto') {
        lineSpacing = math.max(0.0, line / 240 - 1) * size * 1.15;
      } else {
        lineSpacing = math.max(0.0, line / 20 - size * 1.17);
      }
    }
    final align = switch (style.align) {
      'center' => pw.TextAlign.center,
      'right' || 'end' => pw.TextAlign.right,
      'both' || 'distribute' => pw.TextAlign.justify,
      _ => pw.TextAlign.left,
    };
    final textWidth = math.max(40.0, width - math.max(0.0, left) - math.max(0.0, right));
    final hasContent = para.segs.any((seg) => seg.image != null || seg.text.trim().isNotEmpty);
    if (!hasContent && (para.prefix == null || para.prefix!.isEmpty)) {
      return [pw.SizedBox(height: before + size * 1.17 + lineSpacing + after)];
    }
    // spans, split in pieces when the paragraph is very long
    final pieces = <List<pw.InlineSpan>>[[]];
    var count = 0;
    for (final seg in para.segs) {
      if (seg.image != null) {
        final provider = _imageProvider(seg.image);
        if (provider == null) continue;
        var w = seg.width;
        var h = seg.height;
        if (w > textWidth) {
          h = h * textWidth / w;
          w = textWidth;
        }
        if (h > 600) {
          w = w * 600 / h;
          h = 600;
        }
        pieces.last.add(pw.WidgetSpan(child: pw.Image(provider, width: w, height: h, fit: pw.BoxFit.fill), baseline: 0));
        count += 200;
        continue;
      }
      final run = seg.style ?? _RunStyle();
      var runSize = run.size ?? size;
      double? baseline;
      if (run.vert != null) {
        baseline = run.vert! > 0 ? runSize * 0.33 : -runSize * 0.15;
        runSize *= 0.66;
      }
      final textStyle = fonts.style(
        family: run.family,
        bold: run.bold ?? false,
        italic: run.italic ?? false,
        size: runSize,
        color: run.color,
        underline: run.underline ?? false,
        strike: run.strike ?? false,
        highlight: run.highlight,
        lineSpacing: lineSpacing,
      );
      final text = fonts.clean(seg.text.replaceAll('\t', '    '));
      for (final chunk in _chunks(text, 1400)) {
        if (count > 1400) {
          pieces.add([]);
          count = 0;
        }
        pieces.last.add(pw.TextSpan(text: chunk, style: textStyle, baseline: baseline ?? 0));
        count += chunk.length;
      }
    }
    final out = <pw.Widget>[];
    for (var index = 0; index < pieces.length; index++) {
      final spans = pieces[index];
      if (spans.isEmpty) continue;
      final first = index == 0;
      final children = <pw.InlineSpan>[
        if (first && firstLine > 0 && para.prefix == null) pw.WidgetSpan(child: pw.SizedBox(width: firstLine, height: 1)),
        ...spans,
      ];
      pw.Widget body = pw.RichText(
        text: pw.TextSpan(children: children, style: fonts.style(size: size, lineSpacing: lineSpacing)),
        textAlign: align,
      );
      var padLeft = math.max(0.0, left);
      if (first && para.prefix != null && para.prefix!.isNotEmpty) {
        final markerWidth = hanging > 0 ? hanging : 18.0;
        padLeft = math.max(0.0, left - markerWidth);
        final firstStyle = para.segs.where((seg) => seg.style != null).firstOrNull?.style ?? _RunStyle();
        body = pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: markerWidth,
              child: pw.Text(
                fonts.clean(para.prefix!),
                style: fonts.style(
                  family: firstStyle.family,
                  bold: firstStyle.bold ?? false,
                  size: firstStyle.size ?? size,
                  color: firstStyle.color,
                ),
              ),
            ),
            pw.Expanded(child: body),
          ],
        );
      } else if (!first && para.prefix != null) {
        padLeft = math.max(0.0, left);
      } else if (first && firstLine < 0) {
        padLeft = math.max(0.0, left + firstLine);
      } else if (hanging > 0 && para.prefix == null && first) {
        padLeft = math.max(0.0, left - hanging);
      }
      pw.Widget box = pw.Padding(
        padding: pw.EdgeInsets.only(
          left: padLeft,
          right: math.max(0.0, right),
          top: first ? before : 0,
          bottom: index == pieces.length - 1 ? after : 0,
        ),
        child: body,
      );
      if (style.shade != null) box = pw.Container(color: PdfColor.fromInt(0xFF000000 | style.shade!), child: box);
      out.add(box);
    }
    return out;
  }

  List<pw.Widget> _tableWidgets(_WTable table, _Fonts fonts, double width) {
    final available = math.max(60.0, width - math.max(0.0, table.indent));
    final total = table.grid.fold<double>(0, (sum, w) => sum + w);
    final scale = total > available || total <= 0 ? available / math.max(1, total) : 1.0;
    final grid = [for (final w in table.grid) w * scale];
    final border = table.borders ? pw.TableBorder.all(color: PdfColors.grey600, width: 0.5) : null;
    final out = <pw.Widget>[];
    for (final row in table.rows) {
      final widths = <int, pw.TableColumnWidth>{};
      final cells = <pw.Widget>[];
      var column = 0;
      for (var i = 0; i < row.length; i++) {
        final cell = row[i];
        var w = 0.0;
        for (var k = 0; k < cell.span && column + k < grid.length; k++) {
          w += grid[column + k];
        }
        if (w <= 0) w = available / math.max(1, row.length);
        column += cell.span;
        widths[i] = pw.FixedColumnWidth(w);
        final inner = <pw.Widget>[];
        for (final block in cell.blocks) {
          inner.addAll(_widgets(block, fonts, math.max(20.0, w - 8)).where((widget) => widget is! pw.NewPage));
        }
        cells.add(
          pw.Container(
            color: cell.fill == null ? null : PdfColor.fromInt(0xFF000000 | cell.fill!),
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: inner.isEmpty ? [pw.SizedBox(height: 4)] : inner),
          ),
        );
      }
      out.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(left: math.max(0.0, table.indent)),
          child: pw.Table(
            border: border,
            columnWidths: widths,
            children: [pw.TableRow(verticalAlignment: pw.TableCellVerticalAlignment.full, children: cells)],
          ),
        ),
      );
    }
    out.add(pw.SizedBox(height: 4));
    return out;
  }
}

extension on _RunStyle {
  /// Paragraph-mark run properties only size the empty line; colours etc. stay with the runs.
  void _clearLayoutOnly() {
    underline = null;
    strike = null;
    highlight = null;
  }
}

String _formatNumber(int value, String format) {
  switch (format) {
    case 'lowerLetter':
      return _letters(value).toLowerCase();
    case 'upperLetter':
      return _letters(value);
    case 'lowerRoman':
      return _roman(value).toLowerCase();
    case 'upperRoman':
      return _roman(value);
    case 'decimalZero':
      return value.toString().padLeft(2, '0');
    default:
      return '$value';
  }
}

String _letters(int value) {
  if (value <= 0) return '$value';
  final letter = String.fromCharCode(0x41 + (value - 1) % 26);
  return letter * ((value - 1) ~/ 26 + 1);
}

String _roman(int value) {
  if (value <= 0 || value > 3999) return '$value';
  const numerals = [(1000, 'M'), (900, 'CM'), (500, 'D'), (400, 'CD'), (100, 'C'), (90, 'XC'), (50, 'L'), (40, 'XL'), (10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I')];
  var rest = value;
  final out = StringBuffer();
  for (final (number, text) in numerals) {
    while (rest >= number) {
      out.write(text);
      rest -= number;
    }
  }
  return out.toString();
}

// ------------------------------------------------------------------ PowerPoint

class _Xfrm {
  _Xfrm(this.x, this.y, this.w, this.h, {this.rotation = 0, this.flipH = false, this.flipV = false});
  final double x;
  final double y;
  final double w;
  final double h;
  final double rotation;
  final bool flipH;
  final bool flipV;
}

/// Maps a group's child coordinates (EMU) to slide coordinates.
class _GroupMap {
  const _GroupMap(this.offX, this.offY, this.scaleX, this.scaleY, this.childX, this.childY);
  const _GroupMap.identity()
      : offX = 0,
        offY = 0,
        scaleX = 1,
        scaleY = 1,
        childX = 0,
        childY = 0;
  final double offX;
  final double offY;
  final double scaleX;
  final double scaleY;
  final double childX;
  final double childY;

  _Xfrm map(_Xfrm f) => _Xfrm(
        offX + (f.x - childX) * scaleX,
        offY + (f.y - childY) * scaleY,
        f.w * scaleX,
        f.h * scaleY,
        rotation: f.rotation,
        flipH: f.flipH,
        flipV: f.flipV,
      );
}

class _SRun {
  _SRun(this.text, this.size, this.bold, this.italic, this.underline, this.strike, this.color, this.family);
  final String text;
  final double size;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int color;
  final String? family;
}

class _SPara {
  _SPara(this.runs, this.align, this.bullet, this.level);
  final List<_SRun> runs;
  final String align;
  final String? bullet;
  final int level;
}

class _SItem {
  _SItem.shape(this.frame, {this.fill, this.line, this.lineWidth = 0, this.geometry = 'rect', this.paras = const [], this.anchor = 't', this.insets = const [7.2, 3.6, 7.2, 3.6]})
      : image = null,
        table = null,
        columns = const [],
        isLine = false;
  _SItem.picture(this.frame, this.image)
      : fill = null,
        line = null,
        lineWidth = 0,
        geometry = 'rect',
        paras = const [],
        anchor = 't',
        insets = const [0, 0, 0, 0],
        table = null,
        columns = const [],
        isLine = false;
  _SItem.table(this.frame, this.table, this.columns)
      : fill = null,
        line = null,
        lineWidth = 0,
        geometry = 'rect',
        paras = const [],
        anchor = 't',
        insets = const [0, 0, 0, 0],
        image = null,
        isLine = false;
  _SItem.connector(this.frame, this.line, this.lineWidth)
      : fill = null,
        geometry = 'line',
        paras = const [],
        anchor = 't',
        insets = const [0, 0, 0, 0],
        image = null,
        table = null,
        columns = const [],
        isLine = true;

  final _Xfrm frame;
  final int? fill;
  final int? line;
  final double lineWidth;
  final String geometry;
  final List<_SPara> paras;
  final String anchor;
  final List<double> insets;
  final Uint8List? image;
  final List<List<(List<_SPara>, int?)>>? table;
  final List<double> columns;
  final bool isLine;
}

class _Slide {
  _Slide(this.background, this.backgroundImage, this.items);
  final int background;
  final Uint8List? backgroundImage;
  final List<_SItem> items;
}

class _SlidesJob extends _Job {
  _SlidesJob(this.archive);

  final Archive archive;
  double slideWidth = 960;
  double slideHeight = 540;
  final Map<String, int> _scheme = {};
  final List<_Slide> slides = [];
  final StringBuffer _text = StringBuffer();

  @override
  String allText() => _text.toString();

  @override
  void parse(void Function(double progress) progress) {
    final presentation = _xml(archive, 'ppt/presentation.xml');
    final size = _desc(presentation?.rootElement, 'sldSz').firstOrNull;
    final cx = _attNum(size, 'cx');
    final cy = _attNum(size, 'cy');
    if (cx != null && cy != null && cx > 0 && cy > 0) {
      slideWidth = cx / 12700;
      slideHeight = cy / 12700;
    }
    _readTheme();
    final rels = _rels(archive, 'ppt/_rels/presentation.xml.rels');
    final paths = <String>[];
    for (final id in _desc(presentation?.rootElement, 'sldId')) {
      final rid = _att(id, 'id');
      final target = rid == null ? null : rels[rid];
      if (target != null) paths.add(_resolvePath('ppt', target));
    }
    if (paths.isEmpty) {
      final names = archive.files.map((f) => f.name).where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n)).toList();
      int number(String n) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(n)?.group(1) ?? '') ?? 0;
      names.sort((a, b) => number(a).compareTo(number(b)));
      paths.addAll(names);
    }
    for (var i = 0; i < paths.length; i++) {
      final slide = _slide(paths[i]);
      if (slide != null) slides.add(slide);
      progress((i + 1) / paths.length);
    }
  }

  void _readTheme() {
    final theme = _xml(archive, 'ppt/theme/theme1.xml');
    final scheme = _desc(theme?.rootElement, 'clrScheme').firstOrNull;
    if (scheme == null) return;
    for (final entry in scheme.childElements) {
      final srgb = _kid(entry, 'srgbClr');
      final sys = _kid(entry, 'sysClr');
      final value = _hexColor(_att(srgb, 'val')) ?? _hexColor(_att(sys, 'lastClr'));
      if (value != null) _scheme[entry.name.local] = value;
    }
  }

  int? _color(XmlElement? holder) {
    if (holder == null) return null;
    final srgb = _kid(holder, 'srgbClr');
    if (srgb != null) return _hexColor(_att(srgb, 'val'));
    final scheme = _kid(holder, 'schemeClr');
    if (scheme != null) {
      final name = _att(scheme, 'val') ?? '';
      final key = switch (name) {
        'tx1' => 'dk1',
        'bg1' => 'lt1',
        'tx2' => 'dk2',
        'bg2' => 'lt2',
        _ => name,
      };
      var base = _scheme[key];
      if (base == null) return null;
      final lumMod = _attNum(_kid(scheme, 'lumMod'), 'val');
      final lumOff = _attNum(_kid(scheme, 'lumOff'), 'val');
      if (lumMod != null || lumOff != null) {
        int ch(int v) => ((v * (lumMod ?? 100000) / 100000) + 255 * (lumOff ?? 0) / 100000).round().clamp(0, 255);
        base = (ch((base >> 16) & 255) << 16) | (ch((base >> 8) & 255) << 8) | ch(base & 255);
      }
      return base;
    }
    final sys = _kid(holder, 'sysClr');
    if (sys != null) return _hexColor(_att(sys, 'lastClr'));
    final preset = _att(_kid(holder, 'prstClr'), 'val');
    if (preset != null) {
      return const {'black': 0x000000, 'white': 0xFFFFFF, 'red': 0xFF0000, 'blue': 0x0000FF, 'green': 0x00FF00, 'yellow': 0xFFFF00}[preset];
    }
    return null;
  }

  int? _fillOf(XmlElement? spPr) {
    if (spPr == null || _kid(spPr, 'noFill') != null) return null;
    final solid = _kid(spPr, 'solidFill');
    if (solid != null) return _color(solid);
    final gradient = _kid(spPr, 'gradFill');
    final stop = _desc(gradient, 'gs').firstOrNull;
    if (stop != null) return _color(stop);
    return null;
  }

  _Xfrm? _xfrm(XmlElement? holder) {
    final xfrm = holder == null ? null : (_kid(holder, 'xfrm') ?? _desc(holder, 'xfrm').firstOrNull);
    if (xfrm == null) return null;
    final off = _kid(xfrm, 'off');
    final ext = _kid(xfrm, 'ext');
    if (off == null || ext == null) return null;
    return _Xfrm(
      _attNum(off, 'x') ?? 0.0,
      _attNum(off, 'y') ?? 0.0,
      _attNum(ext, 'cx') ?? 0.0,
      _attNum(ext, 'cy') ?? 0.0,
      rotation: (_attNum(xfrm, 'rot') ?? 0) / 60000,
      flipH: _att(xfrm, 'flipH') == '1',
      flipV: _att(xfrm, 'flipV') == '1',
    );
  }

  /// Placeholder shapes (type / idx) of a layout or master part.
  Map<String, XmlElement> _placeholders(XmlDocument? xml) {
    final map = <String, XmlElement>{};
    if (xml == null) return map;
    for (final shape in _desc(xml.rootElement, 'sp')) {
      final ph = _desc(_kid(shape, 'nvSpPr'), 'ph').firstOrNull;
      if (ph == null) continue;
      final type = _att(ph, 'type') ?? 'body';
      final idx = _att(ph, 'idx');
      map['t:$type'] ??= shape;
      if (idx != null) map['i:$idx'] ??= shape;
    }
    return map;
  }

  _Slide? _slide(String path) {
    final xml = _xml(archive, path);
    if (xml == null) return null;
    final rels = _rels(archive, _relsPathOf(path));
    final dir = _dirOf(path);
    String? layoutPath;
    for (final target in rels.values) {
      if (target.contains('slideLayout')) layoutPath = _resolvePath(dir, target);
    }
    final layout = layoutPath == null ? null : _xml(archive, layoutPath);
    String? masterPath;
    if (layoutPath != null) {
      final layoutRels = _rels(archive, _relsPathOf(layoutPath));
      for (final target in layoutRels.values) {
        if (target.contains('slideMaster')) masterPath = _resolvePath(_dirOf(layoutPath), target);
      }
    }
    final master = masterPath == null ? null : _xml(archive, masterPath);
    final layoutPh = _placeholders(layout);
    final masterPh = _placeholders(master);

    var background = 0xFFFFFF;
    Uint8List? backgroundImage;
    for (final (part, partPath) in [(xml, path), (layout, layoutPath), (master, masterPath)]) {
      final bg = _desc(part?.rootElement, 'bg').firstOrNull;
      if (bg == null || partPath == null) continue;
      final bgPr = _kid(bg, 'bgPr');
      final fill = _fillOf(bgPr);
      if (fill != null) {
        background = fill;
        break;
      }
      final ref = _kid(bg, 'bgRef');
      final refColor = _color(ref);
      if (refColor != null) {
        background = refColor;
        break;
      }
      final blip = _desc(bgPr, 'blip').firstOrNull;
      final id = _att(blip, 'embed');
      if (id != null) {
        final partRels = _rels(archive, _relsPathOf(partPath));
        final target = partRels[id];
        if (target != null) {
          backgroundImage = _bytes(archive, _resolvePath(_dirOf(partPath), target));
          break;
        }
      }
    }
    final items = <_SItem>[];
    final tree = _desc(xml.rootElement, 'spTree').firstOrNull;
    if (tree != null) _shapes(tree, items, rels, dir, layoutPh, masterPh, const _GroupMap.identity());
    return _Slide(background, backgroundImage, items);
  }

  void _shapes(XmlElement tree, List<_SItem> items, Map<String, String> rels, String dir, Map<String, XmlElement> layoutPh, Map<String, XmlElement> masterPh, _GroupMap group) {
    for (final node in tree.childElements) {
      switch (node.name.local) {
        case 'sp':
          _shape(node, items, layoutPh, masterPh, group);
        case 'pic':
          final picFrame = _xfrm(_kid(node, 'spPr'));
          final blip = _desc(node, 'blip').firstOrNull;
          final id = _att(blip, 'embed');
          final target = id == null ? null : rels[id];
          final bytes = target == null ? null : _bytes(archive, _resolvePath(dir, target));
          if (picFrame != null && bytes != null) items.add(_SItem.picture(group.map(picFrame), bytes));
        case 'graphicFrame':
          final tableFrame = _xfrm(node);
          final table = _desc(node, 'tbl').firstOrNull;
          if (tableFrame != null && table != null) {
            final columns = [for (final col in _desc(_kid(table, 'tblGrid'), 'gridCol')) (_attNum(col, 'w') ?? 0) / 12700];
            final rows = <List<(List<_SPara>, int?)>>[];
            for (final row in _kids(table, 'tr')) {
              rows.add([
                for (final cell in _kids(row, 'tc'))
                  (_paragraphs(_kid(cell, 'txBody'), null, null, null, 14), _fillOf(_kid(cell, 'tcPr'))),
              ]);
            }
            items.add(_SItem.table(group.map(tableFrame), rows, columns));
          }
        case 'grpSp':
          final xfrm = _desc(_kid(node, 'grpSpPr'), 'xfrm').firstOrNull;
          final off = _kid(xfrm, 'off');
          final ext = _kid(xfrm, 'ext');
          final chOff = _kid(xfrm, 'chOff');
          final chExt = _kid(xfrm, 'chExt');
          var inner = group;
          if (off != null && ext != null && chOff != null && chExt != null) {
            final cw = _attNum(chExt, 'cx') ?? 1.0;
            final ch = _attNum(chExt, 'cy') ?? 1.0;
            final outer = group.map(_Xfrm(_attNum(off, 'x') ?? 0.0, _attNum(off, 'y') ?? 0.0, _attNum(ext, 'cx') ?? 0.0, _attNum(ext, 'cy') ?? 0.0));
            inner = _GroupMap(
              outer.x,
              outer.y,
              cw == 0 ? 1.0 : outer.w / cw,
              ch == 0 ? 1.0 : outer.h / ch,
              _attNum(chOff, 'x') ?? 0.0,
              _attNum(chOff, 'y') ?? 0.0,
            );
          }
          _shapes(node, items, rels, dir, layoutPh, masterPh, inner);
        case 'cxnSp':
          final lineProps = _kid(node, 'spPr');
          final lineFrame = _xfrm(lineProps);
          final ln = _kid(lineProps, 'ln');
          final color = _color(_kid(ln, 'solidFill')) ?? _color(_kid(_kid(node, 'style'), 'lnRef')) ?? 0x404040;
          final width = (_attNum(ln, 'w') ?? 12700) / 12700;
          if (lineFrame != null) items.add(_SItem.connector(group.map(lineFrame), color, width));
        case 'AlternateContent':
          final choice = _kid(node, 'Choice') ?? _kid(node, 'Fallback');
          if (choice != null) _shapes(choice, items, rels, dir, layoutPh, masterPh, group);
      }
    }
  }

  void _shape(XmlElement node, List<_SItem> items, Map<String, XmlElement> layoutPh, Map<String, XmlElement> masterPh, _GroupMap group) {
    final spPr = _kid(node, 'spPr');
    final ph = _desc(_kid(node, 'nvSpPr'), 'ph').firstOrNull;
    final type = ph == null ? null : (_att(ph, 'type') ?? 'body');
    final idx = _att(ph, 'idx');
    XmlElement? inherited;
    if (ph != null) {
      inherited = (idx != null ? layoutPh['i:$idx'] : null) ?? layoutPh['t:$type'] ?? (idx != null ? masterPh['i:$idx'] : null) ?? masterPh['t:$type'];
      if (inherited == null && type == 'ctrTitle') inherited = layoutPh['t:title'] ?? masterPh['t:title'];
      if (inherited == null && type == 'subTitle') inherited = layoutPh['t:body'] ?? masterPh['t:body'];
    }
    final frame = _xfrm(spPr) ?? _xfrm(_kid(inherited, 'spPr')) ?? (type != null ? _xfrm(_kid(masterPh['t:$type'], 'spPr')) : null);
    if (frame == null) return;
    // date / slide number / footer placeholders stay empty unless they have text
    final fill = _fillOf(spPr) ?? (spPr == null || _kid(spPr, 'noFill') == null ? _color(_kid(_kid(node, 'style'), 'fillRef')) : null);
    final ln = _kid(spPr, 'ln');
    int? line;
    var lineWidth = 0.0;
    if (ln != null && _kid(ln, 'noFill') == null) {
      line = _color(_kid(ln, 'solidFill'));
      lineWidth = (_attNum(ln, 'w') ?? 9525) / 12700;
    } else if (ln == null && ph == null) {
      final lnRef = _kid(_kid(node, 'style'), 'lnRef');
      if (lnRef != null && (_att(lnRef, 'idx') ?? '0') != '0') {
        line = _color(lnRef);
        lineWidth = 0.75;
      }
    }
    final geometry = _att(_kid(spPr, 'prstGeom'), 'prst') ?? 'rect';
    final body = _kid(node, 'txBody');
    final bodyPr = _kid(body, 'bodyPr') ?? _kid(_kid(inherited, 'txBody'), 'bodyPr');
    final anchor = _att(bodyPr, 'anchor') ?? (type == 'ctrTitle' || type == 'title' ? 'ctr' : 't');
    final insets = [
      (_attNum(bodyPr, 'lIns') ?? 91440) / 12700,
      (_attNum(bodyPr, 'tIns') ?? 45720) / 12700,
      (_attNum(bodyPr, 'rIns') ?? 91440) / 12700,
      (_attNum(bodyPr, 'bIns') ?? 45720) / 12700,
    ];
    final fontScale = (_attNum(_kid(bodyPr, 'normAutofit'), 'fontScale') ?? 100000) / 100000;
    final defaultSize = switch (type) {
      'title' || 'ctrTitle' => 40.0,
      'subTitle' => 24.0,
      'body' || 'obj' => 24.0,
      _ => 18.0,
    };
    final paras = _paragraphs(body, type, inherited, masterPh['t:$type'], defaultSize * fontScale, scale: fontScale);
    if (fill == null && line == null && paras.every((p) => p.runs.every((r) => r.text.trim().isEmpty))) return;
    for (final para in paras) {
      _text.writeln(para.runs.map((r) => r.text).join());
    }
    items.add(_SItem.shape(group.map(frame), fill: fill, line: line, lineWidth: lineWidth, geometry: geometry, paras: paras, anchor: anchor, insets: insets));
  }

  List<_SPara> _paragraphs(XmlElement? body, String? type, XmlElement? inherited, XmlElement? masterShape, double defaultSize, {double scale = 1}) {
    if (body == null) return const [];
    final out = <_SPara>[];
    final list = _kid(body, 'lstStyle');
    final inheritedList = _kid(_kid(inherited, 'txBody'), 'lstStyle');
    final bodyType = type == 'body' || type == 'obj' || (type != null && type != 'title' && type != 'ctrTitle' && type != 'subTitle' && type != 'dt' && type != 'ftr' && type != 'sldNum');
    for (final paragraph in _kids(body, 'p')) {
      final pPr = _kid(paragraph, 'pPr');
      final level = int.tryParse(_att(pPr, 'lvl') ?? '') ?? 0;
      final levelKey = 'lvl${level + 1}pPr';
      final levelStyle = _kid(list, levelKey) ?? _kid(inheritedList, levelKey);
      final align = _att(pPr, 'algn') ?? _att(levelStyle, 'algn') ?? (type == 'ctrTitle' || type == 'subTitle' ? 'ctr' : 'l');
      String? bullet;
      if (_kid(pPr, 'buNone') != null || _kid(levelStyle, 'buNone') != null) {
        bullet = null;
      } else if (_kid(pPr, 'buChar') != null || _kid(levelStyle, 'buChar') != null) {
        final char = _att(_kid(pPr, 'buChar') ?? _kid(levelStyle, 'buChar'), 'char') ?? '•';
        final code = char.isEmpty ? 0x2022 : char.runes.first;
        bullet = code >= 0xF000 || code == 0xA7 || code == 0xD8 || code == 0xFC ? '•' : char;
      } else if (_kid(pPr, 'buAutoNum') != null) {
        bullet = '${out.where((p) => p.level == level).length + 1}.';
      } else if (bodyType && type != null) {
        bullet = '•';
      }
      final defaults = _kid(pPr, 'defRPr') ?? _kid(levelStyle, 'defRPr');
      final levelSize = defaults == null ? null : _attNum(defaults, 'sz');
      final baseSize = levelSize != null ? levelSize / 100 * scale : math.max(10.0, defaultSize - level * 2 * scale);
      final runs = <_SRun>[];
      for (final run in paragraph.childElements) {
        if (run.name.local != 'r' && run.name.local != 'fld' && run.name.local != 'br') continue;
        if (run.name.local == 'br') {
          runs.add(_SRun('\n', baseSize, false, false, false, false, 0x000000, null));
          continue;
        }
        final rPr = _kid(run, 'rPr');
        final text = _desc(run, 't').map((t) => t.innerText).join();
        if (text.isEmpty) continue;
        final size = _attNum(rPr, 'sz') != null ? _attNum(rPr, 'sz')! / 100 * scale : baseSize;
        final color = _color(_kid(rPr, 'solidFill')) ?? _color(_kid(defaults, 'solidFill')) ?? _scheme['dk1'] ?? 0x000000;
        runs.add(
          _SRun(
            text,
            size.clamp(4.0, 200.0),
            _att(rPr, 'b') == '1' || (_att(rPr, 'b') == null && _att(defaults, 'b') == '1'),
            _att(rPr, 'i') == '1' || (_att(rPr, 'i') == null && _att(defaults, 'i') == '1'),
            (_att(rPr, 'u') ?? 'none') != 'none',
            (_att(rPr, 'strike') ?? 'noStrike') != 'noStrike',
            color,
            _att(_kid(rPr, 'latin'), 'typeface'),
          ),
        );
      }
      out.add(_SPara(runs, align, runs.isEmpty ? null : bullet, level));
    }
    return out;
  }

  @override
  void build(pw.Document doc, _Fonts fonts, void Function(double progress) progress) {
    final format = PdfPageFormat(slideWidth, slideHeight);
    if (slides.isEmpty) {
      doc.addPage(pw.Page(pageFormat: format, build: (context) => pw.SizedBox()));
      return;
    }
    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      final background = _imageProvider(slide.backgroundImage);
      final children = <pw.Widget>[
        pw.Positioned(left: 0, top: 0, right: 0, bottom: 0, child: pw.Container(color: PdfColor.fromInt(0xFF000000 | slide.background))),
        if (background != null) pw.Positioned(left: 0, top: 0, right: 0, bottom: 0, child: pw.Image(background, fit: pw.BoxFit.cover)),
        ...slide.items.map((item) => _item(item, fonts)).whereType<pw.Widget>(),
      ];
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          theme: fonts.theme(),
          build: (context) => pw.FullPage(ignoreMargins: true, child: pw.Stack(children: children)),
        ),
      );
      progress((i + 1) / slides.length);
    }
  }

  pw.Widget? _item(_SItem item, _Fonts fonts) {
    final f = item.frame;
    final x = f.x / 12700;
    final y = f.y / 12700;
    final w = math.max(1.0, f.w / 12700);
    final h = math.max(1.0, f.h / 12700);
    pw.Widget? child;
    if (item.isLine) {
      final color = PdfColor.fromInt(0xFF000000 | (item.line ?? 0x404040));
      final flipH = f.flipH;
      final flipV = f.flipV;
      final lineWidth = math.max(0.5, item.lineWidth);
      child = pw.CustomPaint(
        size: PdfPoint(w, h),
        painter: (canvas, size) {
          final x1 = flipH ? size.x : 0.0;
          final x2 = flipH ? 0.0 : size.x;
          final y1 = flipV ? 0.0 : size.y;
          final y2 = flipV ? size.y : 0.0;
          canvas
            ..setStrokeColor(color)
            ..setLineWidth(lineWidth)
            ..drawLine(x1, y1, x2, y2)
            ..strokePath();
        },
      );
      return pw.Positioned(left: x, top: y, child: pw.SizedBox(width: math.max(w, lineWidth), height: math.max(h, lineWidth), child: child));
    }
    if (item.image != null) {
      final provider = _imageProvider(item.image);
      if (provider == null) return null;
      child = pw.Image(provider, width: w, height: h, fit: pw.BoxFit.fill);
    } else if (item.table != null) {
      child = _slideTable(item, fonts, w);
    } else {
      final radius = item.geometry == 'roundRect' ? math.min(w, h) * 0.16 : (item.geometry == 'ellipse' ? math.min(w, h) / 2 : 0.0);
      final decoration = pw.BoxDecoration(
        color: item.fill == null ? null : PdfColor.fromInt(0xFF000000 | item.fill!),
        border: item.line == null ? null : pw.Border.all(color: PdfColor.fromInt(0xFF000000 | item.line!), width: math.max(0.3, item.lineWidth)),
        borderRadius: radius > 0 ? pw.BorderRadius.circular(radius) : null,
      );
      pw.Widget? text;
      if (item.paras.isNotEmpty) {
        final innerWidth = math.max(4.0, w - item.insets[0] - item.insets[2]);
        final innerHeight = math.max(4.0, h - item.insets[1] - item.insets[3]);
        final alignment = switch (item.anchor) {
          'ctr' => pw.Alignment.center,
          'b' => pw.Alignment.bottomCenter,
          _ => pw.Alignment.topCenter,
        };
        text = pw.Padding(
          padding: pw.EdgeInsets.fromLTRB(item.insets[0], item.insets[1], item.insets[2], item.insets[3]),
          child: pw.SizedBox(
            width: innerWidth,
            height: innerHeight,
            child: pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: alignment,
              child: pw.SizedBox(width: innerWidth, child: _slideParagraphs(item.paras, fonts)),
            ),
          ),
        );
      }
      child = pw.Container(width: w, height: h, decoration: decoration, child: text);
    }
    if (f.rotation != 0) {
      child = pw.Transform.rotate(angle: -f.rotation * math.pi / 180, child: child);
    }
    return pw.Positioned(left: x, top: y, child: pw.SizedBox(width: w, height: h, child: child));
  }

  pw.Widget _slideParagraphs(List<_SPara> paras, _Fonts fonts) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        for (final para in paras)
          if (para.runs.isEmpty)
            pw.SizedBox(height: 8)
          else
            pw.Padding(
              padding: pw.EdgeInsets.only(left: para.level * 18.0, bottom: 2),
              child: pw.RichText(
                textAlign: switch (para.align) {
                  'ctr' => pw.TextAlign.center,
                  'r' => pw.TextAlign.right,
                  'just' || 'dist' => pw.TextAlign.justify,
                  _ => pw.TextAlign.left,
                },
                text: pw.TextSpan(
                  children: [
                    if (para.bullet != null)
                      pw.TextSpan(
                        text: '${fonts.clean(para.bullet!)}  ',
                        style: fonts.style(size: para.runs.first.size, color: para.runs.first.color),
                      ),
                    for (final run in para.runs)
                      pw.TextSpan(
                        text: fonts.clean(run.text),
                        style: fonts.style(
                          family: run.family,
                          bold: run.bold,
                          italic: run.italic,
                          size: run.size,
                          color: run.color,
                          underline: run.underline,
                          strike: run.strike,
                        ),
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  pw.Widget _slideTable(_SItem item, _Fonts fonts, double width) {
    final rows = item.table!;
    var columns = item.columns;
    final count = rows.fold<int>(0, (max, row) => math.max(max, row.length));
    if (columns.length < count || columns.every((c) => c <= 0)) {
      columns = List<double>.filled(count, width / math.max(1, count));
    }
    final total = columns.fold<double>(0, (sum, c) => sum + c);
    final scale = total > 0 ? width / total : 1.0;
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
      columnWidths: {for (var i = 0; i < columns.length; i++) i: pw.FixedColumnWidth(columns[i] * scale)},
      children: [
        for (final row in rows)
          pw.TableRow(
            verticalAlignment: pw.TableCellVerticalAlignment.full,
            children: [
              for (final (paras, fill) in row)
                pw.Container(
                  color: fill == null ? null : PdfColor.fromInt(0xFF000000 | fill),
                  padding: const pw.EdgeInsets.all(4),
                  child: _slideParagraphs(paras, fonts),
                ),
            ],
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Excel / CSV

class _Sheet {
  _Sheet(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

class _SheetJob extends _Job {
  _SheetJob.xlsx(Archive this.archive) : csvText = null;
  _SheetJob.csv(String this.csvText) : archive = null;

  final Archive? archive;
  final String? csvText;
  final List<_Sheet> sheets = [];

  static const _maxRows = 5000;
  static const _maxColumns = 60;

  @override
  String allText() => [for (final sheet in sheets) for (final row in sheet.rows) row.join(' ')].join('\n');

  @override
  void parse(void Function(double progress) progress) {
    final csv = csvText;
    if (csv != null) {
      sheets.add(_Sheet('', _parseCsv(csv)));
      progress(1);
      return;
    }
    final archive = this.archive!;
    final shared = <String>[];
    final strings = _xml(archive, 'xl/sharedStrings.xml');
    for (final si in _kids(strings?.rootElement, 'si')) {
      shared.add(_desc(si, 't').where((t) => t.parentElement?.name.local != 'rPh').map((t) => t.innerText).join());
    }
    final workbook = _xml(archive, 'xl/workbook.xml');
    final rels = _rels(archive, 'xl/_rels/workbook.xml.rels');
    final entries = _desc(workbook?.rootElement, 'sheet').toList();
    for (var i = 0; i < entries.length; i++) {
      final sheet = entries[i];
      final id = _att(sheet, 'id');
      final target = id == null ? null : rels[id];
      if (target == null || _att(sheet, 'state') == 'hidden') continue;
      final xml = _xml(archive, _resolvePath('xl', target));
      if (xml == null) continue;
      final grid = <int, Map<int, String>>{};
      var maxColumn = 0;
      for (final row in _desc(xml.rootElement, 'row')) {
        final rowIndex = (int.tryParse(_att(row, 'r') ?? '') ?? (grid.length + 1)) - 1;
        if (rowIndex >= _maxRows) break;
        var columnCursor = 0;
        for (final cell in _kids(row, 'c')) {
          final ref = _att(cell, 'r');
          final column = ref == null ? columnCursor : _columnIndex(ref);
          columnCursor = column + 1;
          if (column >= _maxColumns) continue;
          final type = _att(cell, 't');
          final raw = _kid(cell, 'v')?.innerText;
          String value;
          if (type == 's') {
            final index = int.tryParse(raw ?? '');
            value = index != null && index >= 0 && index < shared.length ? shared[index] : '';
          } else if (type == 'inlineStr') {
            value = _desc(cell, 't').map((t) => t.innerText).join();
          } else if (type == 'b') {
            value = raw == '1' ? 'TRUE' : 'FALSE';
          } else {
            value = raw ?? '';
            final number = double.tryParse(value);
            if (number != null && type != 'str' && type != 'e') {
              value = number == number.roundToDouble() && number.abs() < 1e15 ? number.toInt().toString() : _trimNumber(number);
            }
          }
          if (value.isEmpty) continue;
          grid.putIfAbsent(rowIndex, () => {})[column] = value;
          maxColumn = math.max(maxColumn, column + 1);
        }
      }
      final rowCount = grid.isEmpty ? 0 : grid.keys.reduce(math.max) + 1;
      final rows = <List<String>>[
        for (var r = 0; r < rowCount; r++) [for (var c = 0; c < maxColumn; c++) grid[r]?[c] ?? ''],
      ];
      sheets.add(_Sheet(_att(sheet, 'name') ?? 'Sheet${i + 1}', rows));
      progress((i + 1) / entries.length);
    }
  }

  @override
  void build(pw.Document doc, _Fonts fonts, void Function(double progress) progress) {
    final format = PdfPageFormat.a4.landscape;
    const margin = 28.0;
    final usable = format.width - margin * 2;
    if (sheets.isEmpty) {
      doc.addPage(pw.Page(pageFormat: format, build: (context) => pw.SizedBox()));
      return;
    }
    for (var s = 0; s < sheets.length; s++) {
      final sheet = sheets[s];
      final columns = sheet.rows.fold<int>(0, (max, row) => math.max(max, row.length));
      final widgets = <pw.Widget>[];
      if (sheet.name.isNotEmpty) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(bottom: 8), child: pw.Text(fonts.clean(sheet.name), style: fonts.style(size: 14, bold: true))));
      }
      if (columns == 0 || sheet.rows.isEmpty) {
        widgets.add(pw.SizedBox(height: 10));
      } else {
        // column widths from the longest text, then split into chunks that fit the page width
        final widths = List<double>.generate(columns, (c) {
          var longest = 1;
          for (final row in sheet.rows.take(400)) {
            if (c < row.length) longest = math.max(longest, row[c].length);
          }
          return (longest * 4.6 + 10).clamp(34.0, 220.0);
        });
        final numberWidth = math.max(26.0, '${sheet.rows.length}'.length * 6.0 + 8);
        var start = 0;
        while (start < columns) {
          var end = start;
          var sum = numberWidth;
          while (end < columns && (sum + widths[end] <= usable || end == start)) {
            sum += widths[end];
            end++;
          }
          final header = fonts.style(size: 8, bold: true, color: 0x444444);
          final cellStyle = fonts.style(size: 8);
          widgets.add(
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
              columnWidths: {
                0: pw.FixedColumnWidth(numberWidth),
                for (var c = start; c < end; c++) c - start + 1: pw.FixedColumnWidth(widths[c]),
              },
              children: [
                pw.TableRow(
                  repeat: true,
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    pw.SizedBox(),
                    for (var c = start; c < end; c++)
                      pw.Padding(padding: const pw.EdgeInsets.all(2), child: pw.Text(_columnName(c), style: header, textAlign: pw.TextAlign.center)),
                  ],
                ),
                for (var r = 0; r < sheet.rows.length; r++)
                  pw.TableRow(
                    children: [
                      pw.Container(
                        color: PdfColors.grey100,
                        padding: const pw.EdgeInsets.all(2),
                        child: pw.Text('${r + 1}', style: header, textAlign: pw.TextAlign.center),
                      ),
                      for (var c = start; c < end; c++)
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(2),
                          child: pw.Text(
                            fonts.clean(c < sheet.rows[r].length ? _shorten(sheet.rows[r][c]) : ''),
                            style: cellStyle,
                            textAlign: double.tryParse(c < sheet.rows[r].length ? sheet.rows[r][c] : '') != null ? pw.TextAlign.right : pw.TextAlign.left,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          );
          widgets.add(pw.SizedBox(height: 12));
          start = end;
        }
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(margin),
          theme: fonts.theme(),
          maxPages: 5000,
          build: (context) => widgets,
        ),
      );
      progress((s + 1) / sheets.length);
    }
  }
}

String _shorten(String value) => value.length > 400 ? '${value.substring(0, 400)}…' : value;

String _trimNumber(double value) {
  var text = value.toStringAsFixed(6);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

int _columnIndex(String ref) {
  var value = 0;
  for (final code in ref.codeUnits) {
    if (code >= 0x41 && code <= 0x5A) {
      value = value * 26 + (code - 0x40);
    } else if (code >= 0x61 && code <= 0x7A) {
      value = value * 26 + (code - 0x60);
    } else {
      break;
    }
  }
  return math.max(0, value - 1);
}

String _columnName(int index) {
  var n = index + 1;
  final out = StringBuffer();
  final chars = <String>[];
  while (n > 0) {
    final rest = (n - 1) % 26;
    chars.insert(0, String.fromCharCode(0x41 + rest));
    n = (n - 1) ~/ 26;
  }
  out.writeAll(chars);
  return out.toString();
}

List<List<String>> _parseCsv(String text) {
  final rows = <List<String>>[];
  final sample = text.length > 2000 ? text.substring(0, 2000) : text;
  final separator = ';'.allMatches(sample).length > ','.allMatches(sample).length
      ? ';'
      : ('\t'.allMatches(sample).length > ','.allMatches(sample).length ? '\t' : ',');
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
      continue;
    }
    if (c == '"') {
      quoted = true;
    } else if (c == separator) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
      if (rows.length >= _SheetJob._maxRows) return rows;
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return [for (final r in rows) r.length > _SheetJob._maxColumns ? r.sublist(0, _SheetJob._maxColumns) : r];
}
