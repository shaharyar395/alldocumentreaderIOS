import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// One sheet: cell texts by key (row * 100000 + column, 0-based) and column widths in points.
class SheetData {
  SheetData(this.name);

  static const maxRows = 5000;
  static const maxCols = 60;
  static const defaultWidth = 64.0;

  final String name;
  final Map<int, String> cells = {};
  final Map<int, double> widths = {};
  int maxRow = -1;
  int maxCol = -1;

  static int key(int row, int col) => row * 100000 + col;

  void put(int row, int col, String value) {
    if (value.isEmpty || row < 0 || col < 0 || row >= maxRows || col >= maxCols) return;
    cells[key(row, col)] = value;
    if (row > maxRow) maxRow = row;
    if (col > maxCol) maxCol = col;
  }

  String cell(int row, int col) => cells[key(row, col)] ?? '';

  double widthOf(int col) => widths[col] ?? defaultWidth;
}

/// "A", "B" … "Z", "AA" …
String columnName(int col) {
  var n = col + 1;
  final letters = <String>[];
  while (n > 0) {
    final m = (n - 1) % 26;
    letters.add(String.fromCharCode(65 + m));
    n = (n - 1) ~/ 26;
  }
  return letters.reversed.join();
}

/// True for old binary Excel files (.xls), which are not read in the app.
bool isLegacyExcel(Uint8List bytes) =>
    bytes.length > 8 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0;

/// Every sheet of an .xlsx / .xlsm / .xltx, .ods, .csv or .tsv file (throws when unreadable).
List<SheetData> parseSpreadsheet(Uint8List bytes, String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.csv') || lower.endsWith('.tsv') || lower.endsWith('.txt')) {
    return [_csv(bytes, lower.endsWith('.tsv') ? '\t' : null)];
  }
  final archive = ZipDecoder().decodeBytes(bytes);
  if (lower.endsWith('.ods') || (archive.findFile('content.xml') != null && archive.findFile('xl/workbook.xml') == null)) {
    return _ods(archive);
  }
  return _xlsx(archive);
}

String _utf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

XmlDocument? _xml(Archive archive, String name) {
  final file = archive.findFile(name);
  if (file == null) return null;
  return XmlDocument.parse(_utf8(file.content as List<int>));
}

String? _attr(XmlElement? node, String local) {
  if (node == null) return null;
  for (final attr in node.attributes) {
    if (attr.name.local == local) return attr.value;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// xlsx

enum _Fmt { general, date, time, dateTime, percent, number }

class _Style {
  const _Style(this.kind, {this.decimals = 0, this.grouping = false, this.prefix = '', this.suffix = ''});
  final _Fmt kind;
  final int decimals;
  final bool grouping;
  final String prefix;
  final String suffix;
}

List<SheetData> _xlsx(Archive archive) {
  final shared = <String>[];
  final sharedXml = _xml(archive, 'xl/sharedStrings.xml');
  if (sharedXml != null) {
    for (final si in sharedXml.rootElement.childElements.where((e) => e.name.local == 'si')) {
      final buffer = StringBuffer();
      for (final t in si.descendants.whereType<XmlElement>().where((e) => e.name.local == 't')) {
        if (t.ancestors.whereType<XmlElement>().any((e) => e.name.local == 'rPh')) continue;
        buffer.write(t.innerText);
      }
      shared.add(buffer.toString());
    }
  }
  final styles = _styles(_xml(archive, 'xl/styles.xml'));
  final rels = <String, String>{};
  final relsXml = _xml(archive, 'xl/_rels/workbook.xml.rels');
  if (relsXml != null) {
    for (final rel in relsXml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      rels[id] = target.startsWith('/') ? target.substring(1) : 'xl/${target.replaceFirst('./', '')}';
    }
  }
  var date1904 = false;
  final list = <(String, String)>[];
  final workbook = _xml(archive, 'xl/workbook.xml');
  if (workbook != null) {
    for (final node in workbook.descendants.whereType<XmlElement>()) {
      if (node.name.local == 'workbookPr') {
        final raw = _attr(node, 'date1904');
        date1904 = raw == '1' || raw == 'true';
      } else if (node.name.local == 'sheet') {
        final state = _attr(node, 'state');
        if (state == 'hidden' || state == 'veryHidden') continue;
        final id = _attr(node, 'id');
        final path = id == null ? null : rels[id];
        if (path == null) continue;
        list.add((_attr(node, 'name') ?? '', path));
      }
    }
  }
  if (list.isEmpty) {
    final names = archive.files
        .map((f) => f.name)
        .where((n) => n.startsWith('xl/worksheets/sheet') && n.endsWith('.xml'))
        .toList()
      ..sort();
    for (var i = 0; i < names.length; i++) {
      list.add(('Sheet${i + 1}', names[i]));
    }
  }
  final sheets = <SheetData>[];
  for (final (name, path) in list) {
    final xml = _xml(archive, path);
    if (xml == null) continue;
    sheets.add(_xlsxSheet(xml, name, shared, styles, date1904));
  }
  if (sheets.isEmpty) throw const FormatException('No sheets');
  return sheets;
}

int? _ref(String? ref) {
  if (ref == null) return null;
  var i = 0;
  var col = 0;
  while (i < ref.length) {
    final c = ref.codeUnitAt(i);
    final upper = c >= 97 && c <= 122 ? c - 32 : c;
    if (upper < 65 || upper > 90) break;
    col = col * 26 + (upper - 64);
    i++;
  }
  final row = int.tryParse(ref.substring(i));
  if (row == null || col == 0) return null;
  return SheetData.key(row - 1, col - 1);
}

SheetData _xlsxSheet(XmlDocument xml, String name, List<String> shared, List<_Style> styles, bool date1904) {
  final sheet = SheetData(name);
  final root = xml.rootElement;
  for (final col in root.descendants.whereType<XmlElement>().where((e) => e.name.local == 'col')) {
    final min = int.tryParse(_attr(col, 'min') ?? '');
    final max = int.tryParse(_attr(col, 'max') ?? '') ?? min;
    final width = double.tryParse(_attr(col, 'width') ?? '');
    if (min == null || max == null || width == null) continue;
    final hidden = _attr(col, 'hidden') == '1' || _attr(col, 'hidden') == 'true';
    // Excel width = characters of the default font (~5.6 pt each, + padding)
    final points = hidden ? 0.0 : (width * 5.6 + 4).clamp(18.0, 420.0);
    for (var c = min - 1; c < math.min(max, SheetData.maxCols); c++) {
      sheet.widths[c] = points;
    }
  }
  final data = root.childElements.where((e) => e.name.local == 'sheetData').firstOrNull;
  if (data == null) return sheet;
  var row = -1;
  for (final rowNode in data.childElements.where((e) => e.name.local == 'row')) {
    final r = int.tryParse(_attr(rowNode, 'r') ?? '');
    row = r == null ? row + 1 : r - 1;
    if (row >= SheetData.maxRows) break;
    var col = -1;
    for (final cell in rowNode.childElements.where((e) => e.name.local == 'c')) {
      final key = _ref(_attr(cell, 'r'));
      if (key != null) {
        col = key % 100000;
      } else {
        col++;
      }
      final type = _attr(cell, 't');
      final styleIndex = int.tryParse(_attr(cell, 's') ?? '') ?? 0;
      final valueNode = cell.childElements.where((e) => e.name.local == 'v').firstOrNull;
      final value = valueNode?.innerText ?? '';
      final String text;
      switch (type) {
        case 's':
          final index = int.tryParse(value.trim());
          text = index != null && index >= 0 && index < shared.length ? shared[index] : '';
        case 'inlineStr':
          text = cell.descendants.whereType<XmlElement>().where((e) => e.name.local == 't').map((e) => e.innerText).join();
        case 'b':
          text = value.trim() == '1' ? 'TRUE' : 'FALSE';
        case 'str' || 'e':
          text = value;
        default:
          text = _number(value, styleIndex < styles.length ? styles[styleIndex] : const _Style(_Fmt.general), date1904);
      }
      sheet.put(row, col, text);
    }
  }
  return sheet;
}

List<_Style> _styles(XmlDocument? xml) {
  if (xml == null) return const [];
  final custom = <int, String>{};
  for (final node in xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'numFmt')) {
    final id = int.tryParse(_attr(node, 'numFmtId') ?? '');
    final code = _attr(node, 'formatCode');
    if (id != null && code != null) custom[id] = code;
  }
  final cellXfs = xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'cellXfs').firstOrNull;
  if (cellXfs == null) return const [];
  return [
    for (final xf in cellXfs.childElements.where((e) => e.name.local == 'xf'))
      _styleFor(int.tryParse(_attr(xf, 'numFmtId') ?? '') ?? 0, custom),
  ];
}

_Style _styleFor(int id, Map<int, String> custom) {
  switch (id) {
    case 1:
      return const _Style(_Fmt.number);
    case 2:
      return const _Style(_Fmt.number, decimals: 2);
    case 3 || 37 || 38:
      return const _Style(_Fmt.number, grouping: true);
    case 4 || 39 || 40:
      return const _Style(_Fmt.number, decimals: 2, grouping: true);
    case 9:
      return const _Style(_Fmt.percent);
    case 10:
      return const _Style(_Fmt.percent, decimals: 2);
    case >= 14 && <= 17 || >= 27 && <= 36 || >= 50 && <= 58:
      if (!custom.containsKey(id)) return const _Style(_Fmt.date);
    case >= 18 && <= 21 || 45 || 46 || 47:
      if (!custom.containsKey(id)) return const _Style(_Fmt.time);
    case 22:
      if (!custom.containsKey(id)) return const _Style(_Fmt.dateTime);
  }
  final code = custom[id];
  if (code == null) return const _Style(_Fmt.general);
  final section = code.split(';').first;
  // quoted text, [colour] / [$-locale] parts and escaped characters are not format letters
  var currency = '';
  final money = RegExp(r'\[\$([^\-\]]+)').firstMatch(section);
  if (money != null) currency = money.group(1) ?? '';
  final clean = section
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .replaceAll(RegExp(r'_.'), '')
      .toLowerCase();
  if (clean.contains('general') || clean.trim().isEmpty || clean.trim() == '@') return const _Style(_Fmt.general);
  final hasDate = clean.contains('y') || clean.contains('d') || (clean.contains('m') && !clean.contains('h') && !clean.contains('s'));
  final hasTime = clean.contains('h') || clean.contains('s');
  final dot = clean.indexOf('.');
  var decimals = 0;
  if (dot >= 0) {
    var i = dot + 1;
    while (i < clean.length && (clean[i] == '0' || clean[i] == '#')) {
      decimals++;
      i++;
    }
  }
  if (clean.contains('%')) return _Style(_Fmt.percent, decimals: decimals);
  if (hasDate && hasTime) return const _Style(_Fmt.dateTime);
  if (hasDate && (clean.contains('y') || clean.contains('d'))) return const _Style(_Fmt.date);
  if (hasTime) return const _Style(_Fmt.time);
  if (clean.contains('0') || clean.contains('#')) {
    final quoted = RegExp(r'"([^"]*)"').allMatches(section).map((m) => m.group(1) ?? '').join();
    final symbols = section.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]|[0#.,?%\s_\\*()\-]'), '');
    final prefixSymbol = currency.isNotEmpty ? currency : (symbols.isNotEmpty && section.trimLeft().indexOf(symbols[0]) == 0 ? symbols : '');
    final suffix = prefixSymbol.isEmpty && symbols.isNotEmpty ? symbols : '';
    final leadingQuote = section.trimLeft().startsWith('"');
    return _Style(
      _Fmt.number,
      decimals: decimals,
      grouping: clean.contains(','),
      prefix: '$prefixSymbol${leadingQuote ? quoted : ''}',
      suffix: '$suffix${leadingQuote ? '' : quoted}',
    );
  }
  return const _Style(_Fmt.general);
}

String _number(String raw, _Style style, bool date1904) {
  final value = double.tryParse(raw.trim());
  if (value == null) return raw;
  return switch (style.kind) {
    _Fmt.percent => '${_fixed(value * 100, style.decimals, false)}%',
    _Fmt.date || _Fmt.time || _Fmt.dateTime => _serialDate(value, style.kind, date1904),
    _Fmt.number => '${value < 0 ? '-' : ''}${style.prefix}${_fixed(value.abs(), style.decimals, style.grouping)}${style.suffix}',
    _Fmt.general => plainNumber(value),
  };
}

String _fixed(double value, int decimals, bool grouping) {
  final text = value.toStringAsFixed(decimals.clamp(0, 10));
  if (!grouping) return text;
  final dot = text.indexOf('.');
  final whole = dot < 0 ? text : text.substring(0, dot);
  final rest = dot < 0 ? '' : text.substring(dot);
  final negative = whole.startsWith('-');
  final digits = negative ? whole.substring(1) : whole;
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${negative ? '-' : ''}$buffer$rest';
}

/// 12.0 → "12", 0.1 + 0.2 → "0.3", big / tiny numbers like Excel's General format.
String plainNumber(double value) {
  if (value.isNaN || value.isInfinite) return value.toString();
  if (value == value.roundToDouble() && value.abs() < 1e15) return value.toStringAsFixed(0);
  if (value.abs() >= 1e11 || value.abs() < 1e-9) {
    return value.toStringAsExponential(5).replaceAll(RegExp(r'0+e'), 'e').replaceAll('.e', 'e').toUpperCase();
  }
  var text = value.toStringAsPrecision(11);
  if (text.contains('e')) return value.toString();
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text;
}

String _two(int value) => value < 10 ? '0$value' : '$value';

String _serialDate(double serial, _Fmt kind, bool date1904) {
  final base = date1904 ? DateTime.utc(1904, 1, 1) : DateTime.utc(1899, 12, 30);
  final days = serial.floor();
  final millis = ((serial - days) * 86400000).round();
  final date = base.add(Duration(days: days, milliseconds: millis));
  final day = '${date.year}-${_two(date.month)}-${_two(date.day)}';
  final time = '${_two(date.hour)}:${_two(date.minute)}';
  return switch (kind) {
    _Fmt.time => '$time:${_two(date.second)}',
    _Fmt.dateTime => '$day $time',
    _ => day,
  };
}

// ---------------------------------------------------------------------------------------------
// ods

String? _odsAttr(XmlElement node, String local) {
  for (final attr in node.attributes) {
    if (attr.name.local == local) return attr.value;
  }
  return null;
}

String _odsText(XmlElement node) {
  final buffer = StringBuffer();
  void walk(XmlNode current) {
    for (final child in current.children) {
      if (child is XmlText) {
        buffer.write(child.value);
      } else if (child is XmlCDATA) {
        buffer.write(child.value);
      } else if (child is XmlElement) {
        switch (child.name.local) {
          case 's':
            buffer.write(' ' * (int.tryParse(_odsAttr(child, 'c') ?? '') ?? 1).clamp(1, 100));
          case 'tab':
            buffer.write('\t');
          case 'line-break':
            buffer.write('\n');
          case 'annotation':
            break;
          default:
            walk(child);
        }
      }
    }
  }

  walk(node);
  return buffer.toString();
}

List<SheetData> _ods(Archive archive) {
  final xml = _xml(archive, 'content.xml');
  if (xml == null) throw const FormatException('Not a spreadsheet');
  final sheets = <SheetData>[];
  final tables = xml.descendants.whereType<XmlElement>().where((e) => e.name.local == 'table' && e.name.prefix == 'table');
  for (final table in tables) {
    final sheet = SheetData(_odsAttr(table, 'name') ?? 'Sheet${sheets.length + 1}');
    var row = 0;
    final rows = table.descendants.whereType<XmlElement>().where((e) => e.name.local == 'table-row');
    for (final rowNode in rows) {
      if (row >= SheetData.maxRows) break;
      final repeatRows = (int.tryParse(_odsAttr(rowNode, 'number-rows-repeated') ?? '') ?? 1).clamp(1, 1 << 20);
      var col = 0;
      final rowCells = <(int, String)>[];
      for (final cell in rowNode.childElements) {
        final local = cell.name.local;
        if (local != 'table-cell' && local != 'covered-table-cell') continue;
        final repeat = (int.tryParse(_odsAttr(cell, 'number-columns-repeated') ?? '') ?? 1).clamp(1, 1 << 14);
        final paragraphs = cell.childElements.where((e) => e.name.local == 'p').map(_odsText).toList();
        var text = paragraphs.join('\n');
        if (text.isEmpty) {
          final type = _odsAttr(cell, 'value-type');
          final value = _odsAttr(cell, 'value');
          text = switch (type) {
            'float' || 'currency' => value == null ? '' : plainNumber(double.tryParse(value) ?? 0.0),
            'percentage' => value == null ? '' : '${plainNumber((double.tryParse(value) ?? 0.0) * 100)}%',
            'date' => (_odsAttr(cell, 'date-value') ?? '').replaceAll('T', ' ').split('.').first,
            'boolean' => (_odsAttr(cell, 'boolean-value') ?? '').toUpperCase(),
            _ => '',
          };
        }
        if (text.isNotEmpty) {
          for (var k = 0; k < repeat && col + k < SheetData.maxCols; k++) {
            rowCells.add((col + k, text));
          }
        }
        col += repeat;
        if (col >= SheetData.maxCols) break;
      }
      if (rowCells.isNotEmpty) {
        // repeated rows with content are copied (empty filler rows are only skipped)
        final copies = math.min(repeatRows, 200);
        for (var k = 0; k < copies; k++) {
          for (final (c, text) in rowCells) {
            sheet.put(row + k, c, text);
          }
        }
      }
      row += repeatRows;
    }
    sheets.add(sheet);
  }
  if (sheets.isEmpty) throw const FormatException('No sheets');
  return sheets;
}

// ---------------------------------------------------------------------------------------------
// csv / tsv

String decodeTextBytes(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  var start = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) start = 3;
  final text = utf8.decode(bytes.sublist(start), allowMalformed: true);
  // many replacement characters: probably a single-byte code page
  var bad = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0xFFFD) bad++;
  }
  if (bad > 8 && bad > text.length ~/ 50) return latin1.decode(bytes.sublist(start), allowInvalid: true);
  return text;
}

SheetData _csv(Uint8List raw, String? forced) {
  final bytes = raw.length > 8000000 ? Uint8List.sublistView(raw, 0, 8000000) : raw;
  final text = decodeTextBytes(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final firstLine = text.split('\n').first;
  var separator = forced ?? ',';
  if (forced == null) {
    var best = 0;
    for (final candidate in const [',', ';', '\t', '|']) {
      final count = candidate.allMatches(firstLine).length;
      if (count > best) {
        best = count;
        separator = candidate;
      }
    }
  }
  final sep = separator.codeUnitAt(0);
  final sheet = SheetData('');
  var row = 0;
  var col = 0;
  final cell = StringBuffer();
  var quoted = false;
  var i = 0;
  while (i < text.length && row < SheetData.maxRows) {
    final c = text.codeUnitAt(i);
    if (quoted) {
      if (c == 34) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 34) {
          cell.writeCharCode(34);
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.writeCharCode(c);
      }
    } else if (c == 34 && cell.isEmpty) {
      quoted = true;
    } else if (c == sep) {
      sheet.put(row, col, cell.toString());
      cell.clear();
      col++;
    } else if (c == 10) {
      sheet.put(row, col, cell.toString());
      cell.clear();
      col = 0;
      row++;
    } else {
      cell.writeCharCode(c);
    }
    i++;
  }
  if (cell.isNotEmpty) sheet.put(row, col, cell.toString());
  // column widths from the longest text (like Excel's auto-fit, capped)
  final longest = <int, int>{};
  sheet.cells.forEach((key, value) {
    final c = key % 100000;
    final length = value.split('\n').fold<int>(0, (m, line) => math.max(m, line.length));
    longest[c] = math.max(longest[c] ?? 0, length);
  });
  longest.forEach((c, n) {
    sheet.widths[c] = (n * 5.6 + 10).clamp(40.0, 260.0);
  });
  return sheet;
}
