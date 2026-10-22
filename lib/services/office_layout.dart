import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

enum RunAlign { start, center, end }

class OfficeRun {
  const OfficeRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.size = 14,
    this.color,
    this.underline = false,
    this.strike = false,
    this.highlight,
  });

  final String text;
  final bool bold;
  final bool italic;

  /// Font size in points.
  final double size;

  /// RGB (0xRRGGBB) or null for the default text colour.
  final int? color;
  final bool underline;
  final bool strike;

  /// RGB background (Word highlight / run shading) or null.
  final int? highlight;

  OfficeRun withText(String next) => OfficeRun(
        next,
        bold: bold,
        italic: italic,
        size: size,
        color: color,
        underline: underline,
        strike: strike,
        highlight: highlight,
      );
}

class OfficeParagraph {
  const OfficeParagraph(
    this.runs, {
    this.align = RunAlign.start,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.indent = 0,
    this.firstLineIndent = 0,
    this.lineSpacing = 1.0,
    this.rtl = false,
    this.shading,
  });

  final List<OfficeRun> runs;
  final RunAlign align;

  /// Spacing and indents in points.
  final double spaceBefore;
  final double spaceAfter;
  final double indent;
  final double firstLineIndent;

  /// Line spacing multiplier (1 = single).
  final double lineSpacing;
  final bool rtl;

  /// RGB paragraph shading or null.
  final int? shading;

  String get plain => runs.map((run) => run.text).join();
}

class OfficeBox {
  const OfficeBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.paragraphs,
    this.fill,
    this.image,
    this.table = const [],
    this.vAlign = 0,
  });

  /// Position and size as fractions (0..1) of the slide.
  final double left;
  final double top;
  final double width;
  final double height;
  final List<OfficeParagraph> paragraphs;
  final int? fill;
  final Uint8List? image;
  final List<List<String>> table;

  /// Vertical text anchor: 0 top, 1 middle, 2 bottom.
  final int vAlign;
}

class OfficeBlock {
  const OfficeBlock.paragraph(this.paragraph)
      : rows = const [],
        image = null,
        width = null,
        height = null,
        align = RunAlign.start,
        cellWidths = const [],
        cellFills = const [],
        pageBreak = false;

  const OfficeBlock.table(this.rows, {this.cellWidths = const [], this.cellFills = const []})
      : paragraph = null,
        image = null,
        width = null,
        height = null,
        align = RunAlign.start,
        pageBreak = false;

  const OfficeBlock.image(this.image, {this.width, this.height, this.align = RunAlign.start})
      : paragraph = null,
        rows = const [],
        cellWidths = const [],
        cellFills = const [],
        pageBreak = false;

  const OfficeBlock.pageBreak()
      : paragraph = null,
        rows = const [],
        image = null,
        width = null,
        height = null,
        align = RunAlign.start,
        cellWidths = const [],
        cellFills = const [],
        pageBreak = true;

  final OfficeParagraph? paragraph;
  final List<List<List<OfficeParagraph>>> rows;
  final Uint8List? image;

  /// Picture size in points (null when the file does not say).
  final double? width;
  final double? height;
  final RunAlign align;

  /// Table cell widths as fractions of the table width, per row (may be empty).
  final List<List<double>> cellWidths;

  /// Table cell shading (RGB) per row (may be empty).
  final List<List<int?>> cellFills;

  /// A hard page break (Word "page break", "page break before", next-page section).
  final bool pageBreak;
}

class OfficeSlide {
  const OfficeSlide({required this.boxes, this.background = 0xFFFFFFFF});

  final List<OfficeBox> boxes;
  final int background;
}

class OfficeLayout {
  const OfficeLayout.word(
    this.paragraphs, {
    this.images = const [],
    this.blocks = const [],
    this.header = const [],
    this.footer = const [],
    this.columns = 1,
    this.pageWidth = 595,
    this.pageHeight = 842,
    this.marginLeft = 72,
    this.marginTop = 72,
    this.marginRight = 72,
    this.marginBottom = 72,
    this.headerDistance = 36,
    this.footerDistance = 36,
  })  : slides = const [],
        slideWidth = 960,
        slideHeight = 540;

  const OfficeLayout.slides(this.slides, {this.slideWidth = 960, this.slideHeight = 540})
      : paragraphs = const [],
        images = const [],
        blocks = const [],
        header = const [],
        footer = const [],
        columns = 1,
        pageWidth = 595,
        pageHeight = 842,
        marginLeft = 72,
        marginTop = 72,
        marginRight = 72,
        marginBottom = 72,
        headerDistance = 36,
        footerDistance = 36;

  final List<OfficeParagraph> paragraphs;
  final List<OfficeSlide> slides;

  /// Pictures in the file that are not placed in the text (Word only).
  final List<Uint8List> images;
  final List<OfficeBlock> blocks;
  final List<OfficeParagraph> header;
  final List<OfficeParagraph> footer;
  final int columns;

  /// Word page size and margins in points.
  final double pageWidth;
  final double pageHeight;
  final double marginLeft;
  final double marginTop;
  final double marginRight;
  final double marginBottom;
  final double headerDistance;
  final double footerDistance;

  /// PowerPoint slide size in points.
  final double slideWidth;
  final double slideHeight;

  bool get isSlides => slides.isNotEmpty;
}

OfficeLayout? readOfficeLayout(Uint8List bytes, {required bool slides}) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (slides) return _slides(archive);
    return _word(archive);
  } catch (_) {
    return null;
  }
}

String utf8Of(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

// ---------------------------------------------------------------------------------------------
// shared helpers

XmlElement? _child(XmlElement? node, String local) {
  if (node == null) return null;
  for (final child in node.childElements) {
    if (child.name.local == local) return child;
  }
  return null;
}

Iterable<XmlElement> _children(XmlElement? node, String local) {
  if (node == null) return const [];
  return node.childElements.where((e) => e.name.local == local);
}

String? _attr(XmlElement? node, String local) {
  if (node == null) return null;
  for (final attr in node.attributes) {
    if (attr.name.local == local) return attr.value;
  }
  return null;
}

/// Word on/off property: present without a value means on.
bool? _onOff(XmlElement? node) {
  if (node == null) return null;
  final value = _attr(node, 'val');
  if (value == null) return true;
  return !(value == '0' || value == 'false' || value == 'none' || value == 'off');
}

double? _twips(String? raw) {
  final value = double.tryParse(raw ?? '');
  return value == null ? null : value / 20;
}

int? _hex(String? raw) {
  if (raw == null || raw == 'auto' || raw.length != 6) return null;
  return int.tryParse(raw, radix: 16);
}

int? _srgb(XmlElement? node) {
  if (node == null) return null;
  final color = node.descendants.whereType<XmlElement>().where((e) => e.name.local == 'srgbClr').firstOrNull;
  final raw = color?.getAttribute('val');
  if (raw == null) return null;
  return int.tryParse(raw, radix: 16);
}

XmlDocument? _xml(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file == null) return null;
  try {
    return XmlDocument.parse(utf8Of(file.content as List<int>));
  } catch (_) {
    return null;
  }
}

Map<String, String> _rels(Archive archive, String name) {
  final xml = _xml(archive, name);
  if (xml == null) return const {};
  final map = <String, String>{};
  for (final rel in xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'Relationship')) {
    final id = rel.getAttribute('Id');
    final target = rel.getAttribute('Target');
    if (id != null && target != null && rel.getAttribute('TargetMode') != 'External') map[id] = target;
  }
  return map;
}

String _resolve(String baseDir, String target) {
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

String _dirOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

/// True for pictures Flutter can decode (PNG, JPEG, GIF, BMP, WebP).
bool isRasterImage(List<int> bytes) {
  if (bytes.length < 12) return false;
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45) {
    return true;
  }
  return false;
}

/// Pixel size of a PNG / JPEG / GIF / BMP / WebP picture without decoding it, or null.
(int, int)? imagePixelSize(List<int> b) {
  try {
    if (b.length < 24) return null;
    if (b[0] == 0x89 && b[1] == 0x50) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return w > 0 && h > 0 ? (w, h) : null;
    }
    if (b[0] == 0x47 && b[1] == 0x49) {
      return (b[6] | (b[7] << 8), b[8] | (b[9] << 8));
    }
    if (b[0] == 0x42 && b[1] == 0x4D) {
      final w = b[18] | (b[19] << 8) | (b[20] << 16) | (b[21] << 24);
      var h = b[22] | (b[23] << 8) | (b[24] << 16) | (b[25] << 24);
      if (h > 0x7FFFFFFF) h = 0x100000000 - h;
      return w > 0 && h > 0 ? (w, h.abs()) : null;
    }
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        final restart = marker >= 0xD0 && marker <= 0xD7;
        if (marker == 0xD8 || marker == 0x01 || restart) {
          i += 2;
          continue;
        }
        final length = (b[i + 2] << 8) | b[i + 3];
        final isFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (isFrame) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return w > 0 && h > 0 ? (w, h) : null;
        }
        i += 2 + length;
      }
      return null;
    }
    if (b[0] == 0x52 && b[8] == 0x57 && b.length > 30) {
      final chunk = String.fromCharCodes(b.sublist(12, 16));
      if (chunk == 'VP8X') {
        final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
        return (w, h);
      }
      if (chunk == 'VP8 ') {
        return (((b[27] << 8) | b[26]) & 0x3FFF, ((b[29] << 8) | b[28]) & 0x3FFF);
      }
      if (chunk == 'VP8L') {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Word

class _Look {
  _Look({
    this.size,
    this.bold,
    this.italic,
    this.color,
    this.align,
    this.before,
    this.after,
    this.underline,
    this.line,
    this.basedOn,
  });

  final double? size;
  final bool? bold;
  final bool? italic;
  final int? color;
  final RunAlign? align;
  final double? before;
  final double? after;
  final bool? underline;
  final double? line;
  final String? basedOn;

  _Look over(_Look? top) {
    if (top == null) return this;
    return _Look(
      size: top.size ?? size,
      bold: top.bold ?? bold,
      italic: top.italic ?? italic,
      color: top.color ?? color,
      align: top.align ?? align,
      before: top.before ?? before,
      after: top.after ?? after,
      underline: top.underline ?? underline,
      line: top.line ?? line,
    );
  }
}

class _Level {
  const _Level(this.format, this.text, this.start, this.indent);
  final String format;
  final String text;
  final int start;
  final double? indent;
}

class _WordCtx {
  _WordCtx(this.archive, this.rels, this.styles, this.defaults, this.defaultParagraph, this.numbering);

  final Archive archive;
  final Map<String, String> rels;
  final Map<String, _Look> styles;
  final _Look defaults;
  final String? defaultParagraph;
  final Map<String, Map<int, _Level>> numbering;
  final Map<String, List<int>> counters = {};
  final Set<String> used = {};
  final Map<String, _Look> _resolved = {};

  _Look look(String? id) {
    final key = id ?? defaultParagraph;
    if (key == null) return defaults;
    final cached = _resolved[key];
    if (cached != null) return cached;
    final chain = <_Look>[];
    var current = styles[key];
    var guard = 0;
    while (current != null && guard < 12) {
      chain.add(current);
      current = current.basedOn == null ? null : styles[current.basedOn];
      guard++;
    }
    var result = defaults;
    for (final style in chain.reversed) {
      result = result.over(style);
    }
    _resolved[key] = result;
    return result;
  }

  _Look? runStyle(String? id) {
    if (id == null) return null;
    final style = styles[id];
    if (style == null) return null;
    final base = style.basedOn == null ? null : styles[style.basedOn];
    return base == null ? style : base.over(style);
  }
}

_Look _lookFrom(XmlElement? pPr, XmlElement? rPr, {String? basedOn}) {
  final spacing = _child(pPr, 'spacing');
  final lineRaw = double.tryParse(_attr(spacing, 'line') ?? '');
  final lineRule = _attr(spacing, 'lineRule');
  final half = double.tryParse(_attr(_child(rPr, 'sz'), 'val') ?? '');
  final u = _attr(_child(rPr, 'u'), 'val');
  return _Look(
    size: half == null ? null : half / 2,
    bold: _onOff(_child(rPr, 'b')),
    italic: _onOff(_child(rPr, 'i')),
    color: _hex(_attr(_child(rPr, 'color'), 'val')),
    align: _wordAlign(_attr(_child(pPr, 'jc'), 'val')),
    before: _twips(_attr(spacing, 'before')),
    after: _twips(_attr(spacing, 'after')),
    underline: _child(rPr, 'u') == null ? null : (u != 'none'),
    line: lineRaw == null || !(lineRule == null || lineRule == 'auto') ? null : lineRaw / 240,
    basedOn: basedOn,
  );
}

RunAlign? _wordAlign(String? value) {
  return switch (value) {
    'center' => RunAlign.center,
    'right' || 'end' => RunAlign.end,
    'left' || 'start' || 'both' || 'distribute' => RunAlign.start,
    _ => null,
  };
}

(Map<String, _Look>, _Look, String?) _wordStyles(Archive archive) {
  final xml = _xml(archive, 'word/styles.xml');
  var defaults = _Look(size: 11, after: 0, line: 1);
  if (xml == null) return (const {}, defaults, null);
  final root = xml.rootElement;
  final docDefaults = _child(root, 'docDefaults');
  final rPr = _child(_child(docDefaults, 'rPrDefault'), 'rPr');
  final pPr = _child(_child(docDefaults, 'pPrDefault'), 'pPr');
  defaults = defaults.over(_lookFrom(pPr, rPr));
  final map = <String, _Look>{};
  String? defaultParagraph;
  for (final style in _children(root, 'style')) {
    final id = _attr(style, 'styleId');
    if (id == null) continue;
    if (_attr(style, 'type') == 'paragraph' && (_attr(style, 'default') == '1' || _attr(style, 'default') == 'true')) {
      defaultParagraph = id;
    }
    map[id] = _lookFrom(_child(style, 'pPr'), _child(style, 'rPr'), basedOn: _attr(_child(style, 'basedOn'), 'val'));
  }
  return (map, defaults, defaultParagraph);
}

Map<String, Map<int, _Level>> _wordNumbering(Archive archive) {
  final xml = _xml(archive, 'word/numbering.xml');
  if (xml == null) return const {};
  final abstract = <String, Map<int, _Level>>{};
  for (final node in xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'abstractNum')) {
    final id = _attr(node, 'abstractNumId');
    if (id == null) continue;
    final levels = <int, _Level>{};
    for (final level in _children(node, 'lvl')) {
      final ilvl = int.tryParse(_attr(level, 'ilvl') ?? '') ?? 0;
      levels[ilvl] = _Level(
        _attr(_child(level, 'numFmt'), 'val') ?? 'bullet',
        _attr(_child(level, 'lvlText'), 'val') ?? '',
        int.tryParse(_attr(_child(level, 'start'), 'val') ?? '') ?? 1,
        _twips(_attr(_child(_child(level, 'pPr'), 'ind'), 'left') ?? _attr(_child(_child(level, 'pPr'), 'ind'), 'start')),
      );
    }
    abstract[id] = levels;
  }
  final map = <String, Map<int, _Level>>{};
  for (final node in xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'num')) {
    final id = _attr(node, 'numId');
    final abstractId = _attr(_child(node, 'abstractNumId'), 'val');
    if (id != null && abstractId != null) map[id] = abstract[abstractId] ?? const {};
  }
  return map;
}

String _roman(int value) {
  if (value <= 0 || value > 3999) return '$value';
  const numbers = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const letters = ['m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i'];
  final buffer = StringBuffer();
  var rest = value;
  for (var i = 0; i < numbers.length; i++) {
    while (rest >= numbers[i]) {
      buffer.write(letters[i]);
      rest -= numbers[i];
    }
  }
  return buffer.toString();
}

String _letters(int value) {
  if (value <= 0) return '$value';
  final buffer = StringBuffer();
  var n = value;
  while (n > 0) {
    final m = (n - 1) % 26;
    buffer.write(String.fromCharCode(97 + m));
    n = (n - 1) ~/ 26;
  }
  return buffer.toString().split('').reversed.join();
}

String _formatNumber(int value, String format) {
  return switch (format) {
    'lowerLetter' => _letters(value),
    'upperLetter' => _letters(value).toUpperCase(),
    'lowerRoman' => _roman(value),
    'upperRoman' => _roman(value).toUpperCase(),
    'decimalZero' => value < 10 ? '0$value' : '$value',
    _ => '$value',
  };
}

/// List label ("1. ", "a) ", "• ") and its indent for a numbered paragraph, or null.
(String, double?)? _listPrefix(XmlElement? pPr, _WordCtx ctx, _Look look) {
  final numPr = _child(pPr, 'numPr');
  if (numPr == null) return null;
  final numId = _attr(_child(numPr, 'numId'), 'val');
  if (numId == null || numId == '0') return null;
  final ilvl = (int.tryParse(_attr(_child(numPr, 'ilvl'), 'val') ?? '') ?? 0).clamp(0, 8);
  final levels = ctx.numbering[numId] ?? const <int, _Level>{};
  final level = levels[ilvl] ?? const _Level('bullet', '•', 1, null);
  if (level.format == 'none') return ('', level.indent);
  if (level.format == 'bullet') {
    final char = level.text.isEmpty || level.text.codeUnitAt(0) >= 0xF000 ? const ['•', '◦', '▪'][ilvl % 3] : level.text;
    return ('$char ', level.indent);
  }
  final counters = ctx.counters.putIfAbsent(numId, () => List<int>.filled(9, 0));
  for (var deeper = ilvl + 1; deeper < 9; deeper++) {
    counters[deeper] = 0;
  }
  counters[ilvl] = counters[ilvl] == 0 ? level.start : counters[ilvl] + 1;
  var text = level.text.isEmpty ? '%${ilvl + 1}.' : level.text;
  for (var l = 0; l <= ilvl; l++) {
    final lvl = levels[l] ?? const _Level('decimal', '', 1, null);
    final value = counters[l] == 0 ? lvl.start : counters[l];
    text = text.replaceAll('%${l + 1}', _formatNumber(value, lvl.format));
  }
  return ('$text ', level.indent);
}

int? _highlightColor(String? value) {
  return switch (value) {
    'yellow' => 0xFFFF00,
    'green' => 0x00FF00,
    'cyan' => 0x00FFFF,
    'magenta' => 0xFF00FF,
    'blue' => 0x0000FF,
    'red' => 0xFF0000,
    'darkBlue' => 0x000080,
    'darkCyan' => 0x008080,
    'darkGreen' => 0x008000,
    'darkMagenta' => 0x800080,
    'darkRed' => 0x800000,
    'darkYellow' => 0x808000,
    'darkGray' => 0x808080,
    'lightGray' => 0xC0C0C0,
    'black' => 0x000000,
    _ => null,
  };
}

bool _underFallback(XmlElement node) {
  return node.ancestors.whereType<XmlElement>().any((e) => e.name.local == 'Fallback');
}

/// Pictures inside a drawing / VML shape, in order, as image blocks.
List<OfficeBlock> _wordImages(XmlElement container, _WordCtx ctx, String baseDir) {
  if (container.name.local == 'AlternateContent') {
    final choice = _child(container, 'Choice');
    final fromChoice = choice == null ? const <OfficeBlock>[] : _wordImages(choice, ctx, baseDir);
    if (fromChoice.isNotEmpty) return fromChoice;
    final fallback = _child(container, 'Fallback');
    return fallback == null ? const [] : _wordImages(fallback, ctx, baseDir);
  }
  final out = <OfficeBlock>[];
  for (final node in container.descendants.whereType<XmlElement>()) {
    final local = node.name.local;
    String? id;
    if (local == 'blip') {
      id = _attr(node, 'embed');
    } else if (local == 'imagedata') {
      id = _attr(node, 'id');
    } else {
      continue;
    }
    if (id == null || (_underFallback(node) && container.name.local != 'Fallback')) continue;
    final target = ctx.rels[id];
    if (target == null) continue;
    final path = _resolve(baseDir, target);
    final file = ctx.archive.findFile(path);
    if (file == null) continue;
    final bytes = Uint8List.fromList(file.content as List<int>);
    ctx.used.add(path);
    if (!isRasterImage(bytes)) continue;
    double? width;
    double? height;
    var align = RunAlign.start;
    final frame = node.ancestors.whereType<XmlElement>().where((e) => e.name.local == 'inline' || e.name.local == 'anchor').firstOrNull;
    if (frame != null) {
      final extent = _child(frame, 'extent');
      final cx = double.tryParse(_attr(extent, 'cx') ?? '');
      final cy = double.tryParse(_attr(extent, 'cy') ?? '');
      if (cx != null && cy != null && cx > 0 && cy > 0) {
        width = cx / 12700;
        height = cy / 12700;
      }
      final alignH = _child(_child(frame, 'positionH'), 'align')?.innerText.trim();
      if (alignH == 'center') align = RunAlign.center;
      if (alignH == 'right') align = RunAlign.end;
    } else {
      final shape = node.ancestors.whereType<XmlElement>().where((e) => e.name.local == 'shape' || e.name.local == 'rect').firstOrNull;
      final style = shape?.getAttribute('style') ?? '';
      width = _cssLength(style, 'width');
      height = _cssLength(style, 'height');
    }
    out.add(OfficeBlock.image(bytes, width: width, height: height, align: align));
  }
  return out;
}

double? _cssLength(String style, String name) {
  final match = RegExp('(?:^|;)\\s*$name\\s*:\\s*([0-9.]+)\\s*(pt|px|in|cm|mm)?').firstMatch(style);
  if (match == null) return null;
  final value = double.tryParse(match.group(1) ?? '');
  if (value == null) return null;
  return switch (match.group(2)) {
    'px' => value * 0.75,
    'in' => value * 72,
    'cm' => value * 72 / 2.54,
    'mm' => value * 72 / 25.4,
    _ => value,
  };
}

/// One Word paragraph as blocks: text pieces and pictures in the order they occur,
/// page breaks, then text-box contents.
List<OfficeBlock> _wordParagraphBlocks(
  XmlElement node,
  _WordCtx ctx,
  List<OfficeParagraph> all, {
  String baseDir = 'word',
  bool textBoxes = true,
}) {
  final pPr = _child(node, 'pPr');
  final look = ctx.look(_attr(_child(pPr, 'pStyle'), 'val'));
  final own = _lookFrom(pPr, null);
  final align = own.align ?? look.align ?? RunAlign.start;
  final before = own.before ?? look.before ?? 0.0;
  final after = own.after ?? look.after ?? 0.0;
  final line = (own.line ?? look.line ?? 1.0).clamp(0.8, 3.0).toDouble();
  final ind = _child(pPr, 'ind');
  final list = _listPrefix(pPr, ctx, look);
  var indent = _twips(_attr(ind, 'left') ?? _attr(ind, 'start')) ?? list?.$2 ?? 0.0;
  if (indent < 0) indent = 0.0;
  final hanging = _twips(_attr(ind, 'hanging'));
  final firstLine = _twips(_attr(ind, 'firstLine')) ?? (hanging == null ? 0.0 : -hanging);
  final rtl = _onOff(_child(pPr, 'bidi')) ?? false;
  final shading = _hex(_attr(_child(pPr, 'shd'), 'fill'));
  final breakBefore = _onOff(_child(pPr, 'pageBreakBefore')) ?? false;
  final sectBreak = _child(pPr, 'sectPr');
  final sectType = _attr(_child(sectBreak, 'type'), 'val');
  final prefix = list?.$1;

  final blocks = <OfficeBlock>[];
  if (breakBefore) blocks.add(const OfficeBlock.pageBreak());
  var runs = <OfficeRun>[];
  var prefixDone = false;
  var hadContent = false;

  void flush() {
    if (runs.isEmpty) return;
    if (!prefixDone && prefix != null && prefix.isNotEmpty) {
      runs[0] = runs[0].withText('$prefix${runs[0].text}');
    }
    prefixDone = true;
    final paragraph = OfficeParagraph(
      List<OfficeRun>.of(runs),
      align: align,
      spaceBefore: before,
      spaceAfter: after,
      indent: indent,
      firstLineIndent: firstLine,
      lineSpacing: line,
      rtl: rtl,
      shading: shading,
    );
    all.add(paragraph);
    blocks.add(OfficeBlock.paragraph(paragraph));
    runs = <OfficeRun>[];
  }

  void addRun(XmlElement run) {
    final rPr = _child(run, 'rPr');
    if (_onOff(_child(rPr, 'vanish')) ?? false) return;
    final runLook = look.over(ctx.runStyle(_attr(_child(rPr, 'rStyle'), 'val'))).over(_lookFrom(null, rPr));
    final shd = _hex(_attr(_child(rPr, 'shd'), 'fill'));
    final highlight = _highlightColor(_attr(_child(rPr, 'highlight'), 'val')) ?? shd;
    final vertAlign = _attr(_child(rPr, 'vertAlign'), 'val');
    var size = runLook.size ?? 11.0;
    if (vertAlign == 'superscript' || vertAlign == 'subscript') size *= 0.65;
    final strike = (_onOff(_child(rPr, 'strike')) ?? false) || (_onOff(_child(rPr, 'dstrike')) ?? false);
    final caps = _onOff(_child(rPr, 'caps')) ?? false;
    final text = StringBuffer();

    void emitText() {
      if (text.isEmpty) return;
      final value = caps ? text.toString().toUpperCase() : text.toString();
      runs.add(OfficeRun(
        value,
        bold: runLook.bold ?? false,
        italic: runLook.italic ?? false,
        size: size,
        color: runLook.color,
        underline: runLook.underline ?? false,
        strike: strike,
        highlight: highlight,
      ));
      text.clear();
      hadContent = true;
    }

    for (final child in run.childElements) {
      switch (child.name.local) {
        case 't':
          text.write(child.innerText);
        case 'tab':
          text.write('\t');
        case 'br':
          if (_attr(child, 'type') == 'page') {
            emitText();
            flush();
            blocks.add(const OfficeBlock.pageBreak());
            hadContent = true;
          } else if (_attr(child, 'type') != 'column') {
            text.write('\n');
          }
        case 'cr':
          text.write('\n');
        case 'noBreakHyphen':
          text.write('-');
        case 'sym':
          final char = int.tryParse(_attr(child, 'char') ?? '', radix: 16);
          if (char != null && char < 0xF000) text.writeCharCode(char);
        case 'drawing' || 'pict' || 'object' || 'AlternateContent':
          final images = _wordImages(child, ctx, baseDir);
          if (images.isNotEmpty) {
            emitText();
            flush();
            blocks.addAll(images);
            hadContent = true;
          }
        default:
          break;
      }
    }
    emitText();
  }

  void visit(XmlElement parent) {
    for (final child in parent.childElements) {
      final local = child.name.local;
      if (local == 'r') {
        addRun(child);
      } else if (local == 'hyperlink' ||
          local == 'ins' ||
          local == 'smartTag' ||
          local == 'fldSimple' ||
          local == 'sdt' ||
          local == 'sdtContent' ||
          local == 'customXml' ||
          local == 'bdo' ||
          local == 'dir' ||
          local == 'moveTo') {
        visit(child);
      }
    }
  }

  visit(node);
  if (runs.isEmpty && !hadContent) {
    // empty paragraph: keeps its vertical space like in Word
    runs.add(OfficeRun('', size: look.size ?? 11.0));
  }
  flush();

  if (textBoxes) {
    for (final box in node.descendants.whereType<XmlElement>().where((e) => e.name.local == 'txbxContent')) {
      if (_underFallback(box)) continue;
      for (final inner in box.childElements.where((e) => e.name.local == 'p')) {
        final innerBlocks = _wordParagraphBlocks(inner, ctx, all, baseDir: baseDir, textBoxes: false);
        for (final block in innerBlocks) {
          final paragraph = block.paragraph;
          if (paragraph != null && paragraph.plain.trim().isEmpty) continue;
          if (block.pageBreak) continue;
          blocks.add(block);
        }
      }
    }
  }
  if (sectBreak != null && sectType != 'continuous') blocks.add(const OfficeBlock.pageBreak());
  return blocks;
}

OfficeBlock? _wordTable(XmlElement table, _WordCtx ctx, List<OfficeParagraph> all, List<OfficeBlock> pictures) {
  final grid = [
    for (final col in _children(_child(table, 'tblGrid'), 'gridCol')) (double.tryParse(_attr(col, 'w') ?? '') ?? 0.0).abs(),
  ];
  final gridTotal = grid.fold<double>(0, (sum, w) => sum + w);
  final rows = <List<List<OfficeParagraph>>>[];
  final widths = <List<double>>[];
  final fills = <List<int?>>[];
  for (final row in _children(table, 'tr')) {
    final cells = <List<OfficeParagraph>>[];
    final rowWidths = <double>[];
    final rowFills = <int?>[];
    var gridIndex = 0;
    final rowCells = row.childElements.where((e) => e.name.local == 'tc' || e.name.local == 'sdt').expand((e) {
      if (e.name.local == 'tc') return [e];
      return e.descendants.whereType<XmlElement>().where((d) => d.name.local == 'tc');
    }).toList();
    for (final cell in rowCells) {
      final tcPr = _child(cell, 'tcPr');
      final span = (int.tryParse(_attr(_child(tcPr, 'gridSpan'), 'val') ?? '') ?? 1).clamp(1, 64);
      final vMerge = _child(tcPr, 'vMerge');
      final continued = vMerge != null && _attr(vMerge, 'val') != 'restart';
      final paragraphs = <OfficeParagraph>[];
      if (!continued) {
        for (final child in cell.childElements) {
          if (child.name.local == 'p') {
            for (final block in _wordParagraphBlocks(child, ctx, all)) {
              final paragraph = block.paragraph;
              if (paragraph != null) {
                paragraphs.add(paragraph);
              } else if (block.image != null) {
                pictures.add(block);
              }
            }
          } else if (child.name.local == 'tbl') {
            // nested table: its text, row by row
            for (final nested in child.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
              for (final block in _wordParagraphBlocks(nested, ctx, all, textBoxes: false)) {
                final paragraph = block.paragraph;
                if (paragraph != null && paragraph.plain.trim().isNotEmpty) paragraphs.add(paragraph);
              }
            }
          }
        }
      }
      cells.add(paragraphs.isEmpty ? const [OfficeParagraph([OfficeRun('', size: 11)])] : paragraphs);
      var width = 0.0;
      if (gridTotal > 0 && gridIndex < grid.length) {
        for (var k = gridIndex; k < gridIndex + span && k < grid.length; k++) {
          width += grid[k];
        }
        width = width / gridTotal;
      }
      rowWidths.add(width);
      rowFills.add(_hex(_attr(_child(tcPr, 'shd'), 'fill')));
      gridIndex += span;
    }
    if (cells.isEmpty) continue;
    // cells without grid information share the row equally
    if (rowWidths.any((w) => w <= 0)) {
      for (var i = 0; i < rowWidths.length; i++) {
        rowWidths[i] = 1 / rowWidths.length;
      }
    }
    rows.add(cells);
    widths.add(rowWidths);
    fills.add(rowFills);
  }
  if (rows.isEmpty) return null;
  return OfficeBlock.table(rows, cellWidths: widths, cellFills: fills);
}

void _wordBody(XmlElement parent, _WordCtx ctx, List<OfficeBlock> blocks, List<OfficeParagraph> paragraphs) {
  for (final node in parent.childElements) {
    final local = node.name.local;
    if (local == 'p') {
      blocks.addAll(_wordParagraphBlocks(node, ctx, paragraphs));
    } else if (local == 'tbl') {
      final pictures = <OfficeBlock>[];
      final table = _wordTable(node, ctx, paragraphs, pictures);
      if (table != null) blocks.add(table);
      blocks.addAll(pictures);
    } else if (local == 'sdt') {
      final content = _child(node, 'sdtContent');
      if (content != null) _wordBody(content, ctx, blocks, paragraphs);
    } else if (local == 'customXml' || local == 'ins') {
      _wordBody(node, ctx, blocks, paragraphs);
    }
  }
}

OfficeLayout _word(Archive archive) {
  final document = _xml(archive, 'word/document.xml');
  if (document == null) return const OfficeLayout.word([]);
  final rels = _rels(archive, 'word/_rels/document.xml.rels');
  final (styles, defaults, defaultParagraph) = _wordStyles(archive);
  final ctx = _WordCtx(archive, rels, styles, defaults, defaultParagraph, _wordNumbering(archive));
  final body = document.descendants.whereType<XmlElement>().where((e) => e.name.local == 'body').firstOrNull;
  final blocks = <OfficeBlock>[];
  final paragraphs = <OfficeParagraph>[];
  if (body != null) {
    _wordBody(body, ctx, blocks, paragraphs);
  } else {
    for (final node in document.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
      blocks.addAll(_wordParagraphBlocks(node, ctx, paragraphs, textBoxes: false));
    }
  }
  // no trailing break / empty paragraphs after the last content
  while (blocks.isNotEmpty && (blocks.last.pageBreak || (blocks.last.paragraph?.plain.trim().isEmpty ?? false))) {
    blocks.removeLast();
  }

  final sect = _child(body, 'sectPr') ??
      document.descendants.whereType<XmlElement>().where((e) => e.name.local == 'sectPr').lastOrNull;
  final pgSz = _child(sect, 'pgSz');
  final pgMar = _child(sect, 'pgMar');
  var pageWidth = _twips(_attr(pgSz, 'w')) ?? 595.0;
  var pageHeight = _twips(_attr(pgSz, 'h')) ?? 842.0;
  if (pageWidth < 144 || pageWidth > 4000) pageWidth = 595.0;
  if (pageHeight < 144 || pageHeight > 6000) pageHeight = 842.0;
  double margin(String name, double fallback) => (_twips(_attr(pgMar, name)) ?? fallback).abs();
  final cols = _child(sect, 'cols');
  final columnCount = int.tryParse(_attr(cols, 'num') ?? '') ?? 1;

  final images = <Uint8List>[];
  for (final media in archive.files) {
    final name = media.name.replaceAll('\\', '/');
    if (name.toLowerCase().startsWith('word/media/') && !ctx.used.contains(name)) {
      final bytes = Uint8List.fromList(media.content as List<int>);
      if (isRasterImage(bytes)) images.add(bytes);
    }
  }
  return OfficeLayout.word(
    paragraphs,
    images: images,
    blocks: blocks,
    header: _story(archive, ctx, sect, 'header'),
    footer: _story(archive, ctx, sect, 'footer'),
    columns: columnCount < 1 ? 1 : columnCount,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
    marginLeft: margin('left', 72),
    marginTop: margin('top', 72),
    marginRight: margin('right', 72),
    marginBottom: margin('bottom', 72),
    headerDistance: margin('header', 36),
    footerDistance: margin('footer', 36),
  );
}

/// The default header or footer of the document's section (text only).
List<OfficeParagraph> _story(Archive archive, _WordCtx ctx, XmlElement? sect, String kind) {
  final refs = _children(sect, '${kind}Reference').toList();
  final ref = refs.where((e) => _attr(e, 'type') == 'default').firstOrNull ?? refs.firstOrNull;
  String? path;
  final id = _attr(ref, 'id');
  if (id != null && ctx.rels[id] != null) path = _resolve('word', ctx.rels[id]!);
  if (path == null) {
    if (refs.isNotEmpty) return const [];
    final names = archive.files.map((f) => f.name.replaceAll('\\', '/')).where((n) => n.startsWith('word/$kind') && n.endsWith('.xml')).toList()
      ..sort();
    if (names.isEmpty) return const [];
    path = names.first;
  }
  final xml = _xml(archive, path);
  if (xml == null) return const [];
  final paragraphs = <OfficeParagraph>[];
  final storyCtx = _WordCtx(archive, _rels(archive, '${_dirOf(path)}/_rels/${path.split('/').last}.rels'), ctx.styles, ctx.defaults, ctx.defaultParagraph, ctx.numbering);
  for (final node in xml.rootElement.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
    if (node.ancestors.whereType<XmlElement>().any((e) => e.name.local == 'txbxContent' || e.name.local == 'tc')) continue;
    for (final block in _wordParagraphBlocks(node, storyCtx, <OfficeParagraph>[], baseDir: _dirOf(path), textBoxes: true)) {
      final paragraph = block.paragraph;
      if (paragraph != null && paragraph.plain.trim().isNotEmpty) paragraphs.add(paragraph);
    }
  }
  return paragraphs;
}

// ---------------------------------------------------------------------------------------------
// PowerPoint

class _Frame {
  const _Frame(this.x, this.y, this.cx, this.cy);
  final double x;
  final double y;
  final double cx;
  final double cy;
}

/// Maps child coordinates of a group shape onto the slide.
class _Xf {
  const _Xf(this.dx, this.dy, this.sx, this.sy);
  static const identity = _Xf(0, 0, 1, 1);
  final double dx;
  final double dy;
  final double sx;
  final double sy;

  _Frame map(_Frame f) => _Frame(dx + f.x * sx, dy + f.y * sy, f.cx * sx, f.cy * sy);
}

_Frame? _frameOf(XmlElement? xfrm) {
  if (xfrm == null) return null;
  final off = _child(xfrm, 'off');
  final ext = _child(xfrm, 'ext');
  if (off == null && ext == null) return null;
  return _Frame(
    double.tryParse(off?.getAttribute('x') ?? '') ?? 0.0,
    double.tryParse(off?.getAttribute('y') ?? '') ?? 0.0,
    double.tryParse(ext?.getAttribute('cx') ?? '') ?? 0.0,
    double.tryParse(ext?.getAttribute('cy') ?? '') ?? 0.0,
  );
}

String _phKey(XmlElement shape) {
  final ph = shape.descendants.whereType<XmlElement>().where((e) => e.name.local == 'ph').firstOrNull;
  if (ph == null) return '';
  var type = ph.getAttribute('type') ?? 'body';
  if (type == 'ctrTitle') type = 'title';
  final idx = ph.getAttribute('idx');
  return idx == null ? type : '$type|$idx';
}

/// Placeholder positions from a slide layout and its master ("title", "body|1" …).
Map<String, _Frame> _placeholderFrames(Archive archive, String slidePath, Map<String, Map<String, _Frame>> cache) {
  final slideRels = _rels(archive, '${_dirOf(slidePath)}/_rels/${slidePath.split('/').last}.rels');
  String? layoutPath;
  for (final target in slideRels.values) {
    if (target.contains('slideLayout')) layoutPath = _resolve(_dirOf(slidePath), target);
  }
  final cached = cache[layoutPath ?? ''];
  if (cached != null) return cached;
  final frames = <String, _Frame>{};
  cache[layoutPath ?? ''] = frames;
  void collect(String path) {
    final xml = _xml(archive, path);
    if (xml == null) return;
    for (final shape in xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'sp')) {
      final key = _phKey(shape);
      if (key.isEmpty) continue;
      final frame = _frameOf(_child(_child(shape, 'spPr'), 'xfrm'));
      if (frame == null || frame.cx <= 0) continue;
      frames.putIfAbsent(key, () => frame);
      frames.putIfAbsent(key.split('|').first, () => frame);
    }
  }

  if (layoutPath != null) {
    collect(layoutPath);
    final layoutRels = _rels(archive, '${_dirOf(layoutPath)}/_rels/${layoutPath.split('/').last}.rels');
    for (final target in layoutRels.values) {
      if (target.contains('slideMaster')) collect(_resolve(_dirOf(layoutPath), target));
    }
  }
  return frames;
}

OfficeLayout _slides(Archive archive) {
  var slideWidth = 12192000.0;
  var slideHeight = 6858000.0;
  final presentation = _xml(archive, 'ppt/presentation.xml');
  var order = <String>[];
  if (presentation != null) {
    final size = presentation.descendants.whereType<XmlElement>().where((e) => e.name.local == 'sldSz').firstOrNull;
    slideWidth = double.tryParse(size?.getAttribute('cx') ?? '') ?? slideWidth;
    slideHeight = double.tryParse(size?.getAttribute('cy') ?? '') ?? slideHeight;
    final rels = _rels(archive, 'ppt/_rels/presentation.xml.rels');
    for (final id in presentation.descendants.whereType<XmlElement>().where((e) => e.name.local == 'sldId')) {
      final rid = _attr(id, 'id');
      final target = rid == null ? null : rels[rid];
      if (target != null) order.add(_resolve('ppt', target));
    }
  }
  if (order.isEmpty || order.any((name) => archive.findFile(name) == null)) {
    int number(String name) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(name)?.group(1) ?? '') ?? 0;
    order = archive.files
        .map((file) => file.name)
        .where((name) => name.startsWith('ppt/slides/slide') && name.endsWith('.xml'))
        .toList()
      ..sort((a, b) => number(a).compareTo(number(b)));
  }
  final slides = <OfficeSlide>[];
  final frameCache = <String, Map<String, _Frame>>{};
  for (final name in order) {
    final xml = _xml(archive, name);
    if (xml == null) continue;
    final rels = _rels(archive, '${_dirOf(name)}/_rels/${name.split('/').last}.rels');
    var background = 0xFFFFFFFF;
    final bg = xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'bg').firstOrNull;
    final bgColor = _srgb(bg);
    if (bgColor != null) background = 0xFF000000 | bgColor;
    final dark = _luminance(background) < 0.4;
    final frames = _placeholderFrames(archive, name, frameCache);
    final boxes = <OfficeBox>[];
    final tree = xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'spTree').firstOrNull;
    if (tree != null) {
      _spTree(tree, _Xf.identity, archive, rels, name, slideWidth, slideHeight, frames, dark, boxes);
    }
    slides.add(OfficeSlide(boxes: boxes, background: background));
  }
  return OfficeLayout.slides(slides, slideWidth: slideWidth / 12700, slideHeight: slideHeight / 12700);
}

double _luminance(int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
}

void _spTree(
  XmlElement tree,
  _Xf xf,
  Archive archive,
  Map<String, String> rels,
  String slidePath,
  double slideWidth,
  double slideHeight,
  Map<String, _Frame> frames,
  bool dark,
  List<OfficeBox> boxes,
) {
  OfficeBox box(_Frame f, {List<OfficeParagraph> paragraphs = const [], int? fill, Uint8List? image, List<List<String>> table = const [], int vAlign = 0}) {
    return OfficeBox(
      left: (f.x / slideWidth).clamp(0.0, 1.0),
      top: (f.y / slideHeight).clamp(0.0, 1.0),
      width: (f.cx / slideWidth).clamp(0.02, 1.0),
      height: (f.cy / slideHeight).clamp(0.02, 1.0),
      paragraphs: paragraphs,
      fill: fill,
      image: image,
      table: table,
      vAlign: vAlign,
    );
  }

  for (final child in tree.childElements) {
    switch (child.name.local) {
      case 'sp':
        final spPr = _child(child, 'spPr');
        final key = _phKey(child);
        var frame = _frameOf(_child(spPr, 'xfrm'));
        if (frame == null || frame.cx <= 0) {
          final inherited = frames[key] ?? frames[key.split('|').first];
          if (inherited != null) {
            frame = inherited;
          } else if (key.startsWith('title')) {
            frame = _Frame(slideWidth * 0.06, slideHeight * 0.05, slideWidth * 0.88, slideHeight * 0.18);
          } else {
            frame = _Frame(slideWidth * 0.06, slideHeight * 0.26, slideWidth * 0.88, slideHeight * 0.64);
          }
        } else {
          frame = xf.map(frame);
        }
        final defaultSize = key.startsWith('title') ? 40.0 : (key.startsWith('subTitle') ? 24.0 : 18.0);
        final bodyPr = child.descendants.whereType<XmlElement>().where((e) => e.name.local == 'bodyPr').firstOrNull;
        final fontScale = (double.tryParse(_attr(_child(bodyPr, 'normAutofit'), 'fontScale') ?? '') ?? 100000) / 100000;
        final paragraphs = _txParagraphs(child, defaultSize * fontScale.clamp(0.3, 1.0), dark, fontScale.clamp(0.3, 1.0));
        final fillNode = _child(spPr, 'solidFill');
        final fill = _srgb(fillNode);
        final anchor = bodyPr?.getAttribute('anchor');
        final vAlign = anchor == 'ctr' ? 1 : (anchor == 'b' ? 2 : (anchor == null && key.startsWith('title') ? 1 : 0));
        if (paragraphs.every((p) => p.plain.trim().isEmpty) && fill == null) continue;
        boxes.add(box(frame, paragraphs: paragraphs, fill: fill, vAlign: vAlign));
      case 'pic':
        final picFrame = _frameOf(_child(_child(child, 'spPr'), 'xfrm'));
        final bytes = _slideImage(child, archive, rels, slidePath);
        if (bytes == null) continue;
        final picBox = picFrame == null || picFrame.cx <= 0
            ? _Frame(slideWidth * 0.3, slideHeight * 0.3, slideWidth * 0.4, slideHeight * 0.4)
            : xf.map(picFrame);
        boxes.add(box(picBox, image: bytes));
      case 'graphicFrame':
        final tableFrame = _frameOf(_child(child, 'xfrm'));
        final rows = <List<String>>[];
        for (final row in child.descendants.whereType<XmlElement>().where((e) => e.name.local == 'tr')) {
          final cells = <String>[];
          for (final cell in row.childElements.where((e) => e.name.local == 'tc')) {
            final paragraphs = cell.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p').map(
                  (p) => p.descendants.whereType<XmlElement>().where((e) => e.name.local == 't').map((e) => e.innerText).join(),
                );
            cells.add(paragraphs.where((t) => t.trim().isNotEmpty).join('\n').trim());
          }
          if (cells.isNotEmpty) rows.add(cells);
        }
        if (rows.isEmpty) continue;
        final tableBox = tableFrame == null || tableFrame.cx <= 0
            ? _Frame(slideWidth * 0.1, slideHeight * 0.25, slideWidth * 0.8, slideHeight * 0.5)
            : xf.map(tableFrame);
        boxes.add(box(tableBox, table: rows));
      case 'grpSp':
        final xfrm = _child(_child(child, 'grpSpPr'), 'xfrm');
        final off = _frameOf(xfrm);
        final chOff = _child(xfrm, 'chOff');
        final chExt = _child(xfrm, 'chExt');
        var inner = xf;
        if (off != null) {
          final cx0 = double.tryParse(chOff?.getAttribute('x') ?? '') ?? 0.0;
          final cy0 = double.tryParse(chOff?.getAttribute('y') ?? '') ?? 0.0;
          final cw = double.tryParse(chExt?.getAttribute('cx') ?? '') ?? 0.0;
          final ch = double.tryParse(chExt?.getAttribute('cy') ?? '') ?? 0.0;
          final sx = cw > 0 && off.cx > 0 ? off.cx / cw : 1.0;
          final sy = ch > 0 && off.cy > 0 ? off.cy / ch : 1.0;
          // child point p → group: off + (p - chOff) * s → slide: xf
          final local = _Xf(off.x - cx0 * sx, off.y - cy0 * sy, sx, sy);
          inner = _Xf(xf.dx + local.dx * xf.sx, xf.dy + local.dy * xf.sy, local.sx * xf.sx, local.sy * xf.sy);
        }
        _spTree(child, inner, archive, rels, slidePath, slideWidth, slideHeight, frames, dark, boxes);
      case 'AlternateContent':
        final choice = _child(child, 'Choice') ?? _child(child, 'Fallback');
        if (choice != null) _spTree(choice, xf, archive, rels, slidePath, slideWidth, slideHeight, frames, dark, boxes);
      default:
        break;
    }
  }
}

Uint8List? _slideImage(XmlElement picture, Archive archive, Map<String, String> rels, String slidePath) {
  for (final blip in picture.descendants.whereType<XmlElement>().where((e) => e.name.local == 'blip')) {
    final id = _attr(blip, 'embed');
    final target = id == null ? null : rels[id];
    if (target == null) continue;
    final file = archive.findFile(_resolve(_dirOf(slidePath), target));
    if (file == null) continue;
    final bytes = Uint8List.fromList(file.content as List<int>);
    if (isRasterImage(bytes)) return bytes;
  }
  return null;
}

int? _schemeColor(XmlElement? node) {
  final scheme = node?.descendants.whereType<XmlElement>().where((e) => e.name.local == 'schemeClr').firstOrNull;
  return switch (scheme?.getAttribute('val')) {
    'bg1' || 'lt1' => 0xFFFFFF,
    'tx1' || 'dk1' => 0x000000,
    _ => null,
  };
}

List<OfficeParagraph> _txParagraphs(XmlElement shape, double defaultSize, bool dark, double scale) {
  final body = shape.descendants.whereType<XmlElement>().where((e) => e.name.local == 'txBody').firstOrNull;
  if (body == null) return const [];
  final paragraphs = <OfficeParagraph>[];
  for (final paragraph in body.childElements.where((e) => e.name.local == 'p')) {
    final pPr = _child(paragraph, 'pPr');
    final align = switch (pPr?.getAttribute('algn')) {
      'ctr' => RunAlign.center,
      'r' => RunAlign.end,
      _ => RunAlign.start,
    };
    final bullet = _child(pPr, 'buChar')?.getAttribute('char');
    final runs = <OfficeRun>[];
    for (final run in paragraph.childElements) {
      final local = run.name.local;
      if (local == 'br') {
        if (runs.isNotEmpty) runs.add(runs.last.withText('\n'));
        continue;
      }
      if (local != 'r' && local != 'fld') continue;
      final props = _child(run, 'rPr');
      final sizeRaw = int.tryParse(props?.getAttribute('sz') ?? '');
      final size = sizeRaw == null ? defaultSize : sizeRaw / 100 * scale;
      final text = run.descendants.whereType<XmlElement>().where((e) => e.name.local == 't').map((e) => e.innerText).join();
      if (text.isEmpty) continue;
      final fill = _child(props, 'solidFill');
      final color = _srgb(fill) ?? _schemeColor(fill) ?? (dark ? 0xFFFFFF : null);
      runs.add(OfficeRun(
        text,
        bold: props?.getAttribute('b') == '1',
        italic: props?.getAttribute('i') == '1',
        underline: (props?.getAttribute('u') ?? 'none') != 'none',
        size: size.clamp(6, 96).toDouble(),
        color: color,
      ));
    }
    if (runs.isEmpty) {
      paragraphs.add(OfficeParagraph([OfficeRun('', size: defaultSize)], align: align));
      continue;
    }
    if (bullet != null && bullet.isNotEmpty) {
      final char = bullet.codeUnitAt(0) >= 0xF000 ? '•' : bullet;
      runs[0] = runs[0].withText('$char ${runs[0].text}');
    }
    paragraphs.add(OfficeParagraph(runs, align: align, spaceAfter: 2));
  }
  // trailing empty paragraphs only add height
  while (paragraphs.isNotEmpty && paragraphs.last.plain.isEmpty) {
    paragraphs.removeLast();
  }
  return paragraphs;
}
