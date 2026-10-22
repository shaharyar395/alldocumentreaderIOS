import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A drawn signature: strokes as points in a box of [aspect] (width / height), x and y in 0..1.
class Signature {
  Signature({required this.strokes, required this.color, required this.width, required this.aspect, this.file});

  final List<List<Offset>> strokes;
  final int color;

  /// Pen width as a fraction of the signature box's width.
  final double width;
  final double aspect;

  /// Where it is kept (saved signatures only).
  final String? file;

  Map<String, Object> toJson() => {
        'color': color,
        'width': width,
        'aspect': aspect,
        'strokes': [
          for (final stroke in strokes) [for (final point in stroke) ...[point.dx, point.dy]],
        ],
      };

  static Signature? fromJson(Map<String, dynamic> json, String file) {
    try {
      final strokes = <List<Offset>>[];
      for (final raw in json['strokes'] as List<dynamic>) {
        final values = (raw as List<dynamic>).map((value) => (value as num).toDouble()).toList();
        strokes.add([for (var i = 0; i + 1 < values.length; i += 2) Offset(values[i], values[i + 1])]);
      }
      return Signature(
        strokes: strokes,
        color: (json['color'] as num).toInt(),
        width: (json['width'] as num).toDouble(),
        aspect: (json['aspect'] as num).toDouble(),
        file: file,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Signatures drawn in the signature pad, kept for next time in the app's documents folder.
class SignatureStore {
  static Future<Directory> _dir() async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'signatures'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<Signature>> list() async {
    try {
      final dir = await _dir();
      final files = dir.listSync().whereType<File>().where((file) => file.path.endsWith('.json')).toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      final out = <Signature>[];
      for (final file in files) {
        final sign = Signature.fromJson(json.decode(await file.readAsString()) as Map<String, dynamic>, file.path);
        if (sign != null) out.add(sign);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<Signature> save(Signature signature) async {
    final dir = await _dir();
    final file = File(p.join(dir.path, 'sign_${DateTime.now().millisecondsSinceEpoch}.json'));
    await file.writeAsString(json.encode(signature.toJson()), flush: true);
    return Signature(strokes: signature.strokes, color: signature.color, width: signature.width, aspect: signature.aspect, file: file.path);
  }

  static Future<void> delete(Signature signature) async {
    final path = signature.file;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
