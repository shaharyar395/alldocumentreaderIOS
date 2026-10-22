import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Text-bearing content streams, in file order. One stream is usually one page.
List<String> extractPdfPages(Uint8List data) {
  const streamMark = [115, 116, 114, 101, 97, 109]; // stream
  const endMark = [101, 110, 100, 115, 116, 114, 101, 97, 109]; // endstream
  final pages = <String>[];
  var cursor = 0;
  while (cursor < data.length) {
    final start = _indexOf(data, streamMark, cursor);
    if (start < 0) break;
    var content = start + streamMark.length;
    if (content < data.length && data[content] == 13) content++;
    if (content < data.length && data[content] == 10) content++;
    final end = _indexOf(data, endMark, content);
    if (end < 0) break;
    var raw = data.sublist(content, end);
    while (raw.isNotEmpty && (raw.last == 10 || raw.last == 13)) {
      raw = raw.sublist(0, raw.length - 1);
    }
    final dict = _lookback(data, start, 240);
    var decoded = raw;
    if (dict.contains('FlateDecode')) {
      try {
        decoded = Uint8List.fromList(const ZLibDecoder().decodeBytes(raw));
      } catch (_) {
        cursor = end + endMark.length;
        continue;
      }
    }
    final text = _textFromContent(decoded).trim();
    if (text.isNotEmpty) pages.add(text);
    cursor = end + endMark.length;
  }
  return pages;
}

String extractPdfText(Uint8List data) => extractPdfPages(data).join('\n\n');

String textFromDecodedStream(Uint8List decoded) => _textFromContent(decoded).trim();

int _indexOf(Uint8List data, List<int> pattern, int from) {
  final last = data.length - pattern.length;
  for (var i = from; i <= last; i++) {
    var matched = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}

String _lookback(Uint8List data, int end, int max) {
  final start = end - max < 0 ? 0 : end - max;
  return latin1.decode(data.sublist(start, end), allowInvalid: true);
}

String _textFromContent(Uint8List bytes) {
  final source = latin1.decode(bytes, allowInvalid: true);
  if (!source.contains('Tj') && !source.contains('TJ') && !source.contains("'")) return '';
  final buffer = StringBuffer();
  var lastWasSpace = true;
  void put(String text) {
    if (text.isEmpty) return;
    buffer.write(text);
    final code = text.codeUnitAt(text.length - 1);
    lastWasSpace = code == 32 || code == 10 || code == 13 || code == 9;
  }

  var inArray = false;
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    if (char == '(') {
      final parsed = _literal(source, i);
      if (parsed != null) {
        put(parsed.$1);
        i = parsed.$2;
        continue;
      }
    }
    if (char == '<' && (i + 1 >= source.length || source[i + 1] != '<')) {
      final hex = _hexString(source, i);
      if (hex != null) {
        put(hex.$1);
        i = hex.$2;
        continue;
      }
    }
    if (char == '[') {
      inArray = true;
      i++;
      continue;
    }
    if (char == ']') {
      inArray = false;
      i++;
      continue;
    }
    if (inArray && (char == '-' || char == '.' || _digit(char))) {
      // a big negative adjustment between two strings of a TJ array is a word space
      var end = i + 1;
      while (end < source.length && (_digit(source[end]) || source[end] == '.')) {
        end++;
      }
      final value = double.tryParse(source.substring(i, end));
      if (value != null && value <= -180 && !lastWasSpace) put(' ');
      i = end;
      continue;
    }
    if (source.startsWith('Tj', i) || source.startsWith('TJ', i)) {
      put('\n');
      i += 2;
      continue;
    }
    if (char == "'" || source.startsWith('T*', i)) {
      put('\n');
      i += char == "'" ? 1 : 2;
      continue;
    }
    i++;
  }
  return buffer.toString();
}

bool _digit(String char) {
  final code = char.codeUnitAt(0);
  return code >= 48 && code <= 57;
}

(String, int)? _literal(String source, int start) {
  if (source[start] != '(') return null;
  final buffer = StringBuffer();
  var i = start + 1;
  var depth = 1;
  while (i < source.length && depth > 0) {
    final char = source[i];
    if (char == r'\' && i + 1 < source.length) {
      final next = source[i + 1];
      if (next == 'n') {
        buffer.write('\n');
      } else if (next == 'r') {
        buffer.write('\r');
      } else if (next == 't') {
        buffer.write('\t');
      } else if (next == '(' || next == ')' || next == r'\') {
        buffer.write(next);
      } else if (_octal(next)) {
        var digits = next;
        var consumed = 1;
        while (consumed < 3 && i + 1 + consumed < source.length && _octal(source[i + 1 + consumed])) {
          digits += source[i + 1 + consumed];
          consumed++;
        }
        buffer.writeCharCode(int.parse(digits, radix: 8));
        i += 1 + consumed;
        continue;
      } else {
        buffer.write(next);
      }
      i += 2;
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
    i++;
  }
  return (buffer.toString(), i);
}

bool _octal(String char) {
  final code = char.codeUnitAt(0);
  return code >= 48 && code <= 55;
}

(String, int)? _hexString(String source, int start) {
  final end = source.indexOf('>', start + 1);
  if (end < 0 || end - start > 8000) return null;
  final hex = source.substring(start + 1, end).replaceAll(RegExp(r'\s'), '');
  if (hex.isEmpty || hex.length.isOdd || !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(hex)) return null;
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return (String.fromCharCodes(units), end + 1);
  }
  return (latin1.decode(bytes, allowInvalid: true), end + 1);
}
