import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every locale has the English keys', () {
    final dir = Directory('assets/l10n');
    final en = json.decode(File('assets/l10n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final keys = en.keys.toSet();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    expect(files.length, 23);
    for (final file in files) {
      final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(map.keys.toSet(), keys, reason: file.path);
      for (final value in map.values) {
        expect(value, isA<String>());
        expect((value as String).trim(), isNotEmpty);
      }
    }
  });
}
