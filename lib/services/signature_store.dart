import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A drawn signature: strokes as points in a box of [aspect] (width / height), x and y in 0..1.
class Signature {
  Signature({required this.strokes, required this.color, required this.width, required this.aspect, List<double>? widths, this.file})
      : widths = widths != null && widths.length == strokes.length ? widths : List<double>.filled(strokes.length, width);

  final List<List<Offset>> strokes;

  /// Ink colour of the whole signature (the native pad recolours every stroke when the colour
  /// changes).
  final int color;

  /// Pen width as a fraction of the signature box's width (the widest stroke).
  final double width;

  /// Pen width of each stroke (fractions of the box width): the native pad keeps the width a
  /// stroke was drawn with.
  final List<double> widths;
  final double aspect;

  /// Where it is kept (saved signatures only).
  final String? file;

  Map<String, Object> toJson() => {
        'color': color,
        'width': width,
        'aspect': aspect,
        'widths': widths,
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
      final rawWidths = json['widths'];
      return Signature(
        strokes: strokes,
        color: (json['color'] as num).toInt(),
        width: (json['width'] as num).toDouble(),
        aspect: (json['aspect'] as num).toDouble(),
        widths: rawWidths is List ? [for (final value in rawWidths) (value as num).toDouble()] : null,
        file: file,
      );
    } catch (_) {
      return null;
    }
  }

  Signature withFile(String path) => Signature(strokes: strokes, color: color, width: width, aspect: aspect, widths: widths, file: path);
}

/// Signatures drawn in the signature pad, kept for next time in app-private storage (like the
/// native SignatureStore in filesDir/signatures). On iOS that is Library/Application Support, so
/// they don't show up as a folder in the Files app (the app's Documents folder is shared there).
class SignatureStore {
  static bool _migrated = false;

  static Future<Directory> _dir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'signatures'));
    await dir.create(recursive: true);
    if (!_migrated) {
      _migrated = true;
      await _moveOld(dir);
    }
    return dir;
  }

  /// Earlier versions kept the signatures in Documents/signatures: move them over once.
  static Future<void> _moveOld(Directory dir) async {
    try {
      final old = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'signatures'));
      if (old.path == dir.path || !await old.exists()) return;
      for (final file in old.listSync().whereType<File>()) {
        final target = File(p.join(dir.path, p.basename(file.path)));
        try {
          if (!await target.exists()) {
            final modified = file.statSync().modified;
            await file.copy(target.path);
            await target.setLastModified(modified);
          }
          await file.delete();
        } catch (_) {
          // keep it where it is
        }
      }
      if (old.listSync().isEmpty) await old.delete();
    } catch (_) {
      // nothing to move
    }
  }

  /// Newest first.
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
    return signature.withFile(file.path);
  }

  static Future<void> delete(Signature signature) async {
    final path = signature.file;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
