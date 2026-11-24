import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Continue reading" (Android data/ReadingProgress.kt, 1.0.35+): the page the user last had on
/// screen in the reader, per file, and which file was read last. The reader saves it; the home
/// screen's top deck card shows the newest one and reopens the file at that page.
///
/// Files are keyed by their library ref ([DocEntry.relativePath]), so a position survives the
/// iOS container path changing with app updates. Positions are kept for at most 100 files.
class ReadingEntry {
  const ReadingEntry({required this.ref, required this.page, required this.pageCount, required this.time});

  /// The file's library ref (DocEntry.relativePath).
  final String ref;

  /// 0-based page.
  final int page;
  final int pageCount;

  /// When it was saved (ms since epoch).
  final int time;

  /// 0..1 for the card's progress bar.
  double get fraction => pageCount <= 1 ? 1 : ((page + 1) / pageCount).clamp(0.0, 1.0);
}

class ReadingProgress {
  ReadingProgress._();

  static const _prefix = 'rp:';
  static const _keyLast = 'rp_last';
  static const _maxFiles = 100;

  static SharedPreferences? _prefs;

  /// Something changed (the home deck listens).
  static final changed = ValueNotifier<int>(0);

  static Future<SharedPreferences> _sp() async => _prefs ??= await SharedPreferences.getInstance();

  /// Loaded once at start so [last] / [of] can answer synchronously.
  static Future<void> init() async {
    await _sp();
  }

  /// Reader: the page on screen changed (or the reader closes).
  static Future<void> save(String ref, int page, int pageCount) async {
    if (ref.isEmpty || pageCount <= 0) return;
    final prefs = await _sp();
    final value = '${page.clamp(0, pageCount - 1)}|$pageCount|${DateTime.now().millisecondsSinceEpoch}';
    if (prefs.getString('$_prefix$ref') == null) await _trim(prefs);
    await prefs.setString('$_prefix$ref', value);
    await prefs.setString(_keyLast, ref);
    changed.value++;
  }

  /// Drops the oldest positions so at most [_maxFiles] remain after adding one.
  static Future<void> _trim(SharedPreferences prefs) async {
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    if (keys.length < _maxFiles) return;
    final all = [
      for (final k in keys)
        if (_parse(k.substring(_prefix.length), prefs.getString(k)) case final e?) e,
    ]..sort((a, b) => a.time.compareTo(b.time));
    for (final e in all.take(keys.length - _maxFiles + 1)) {
      await prefs.remove('$_prefix${e.ref}');
    }
  }

  /// The saved position of [ref], or null.
  static ReadingEntry? of(String ref) {
    final prefs = _prefs;
    if (prefs == null) return null;
    return _parse(ref, prefs.getString('$_prefix$ref'));
  }

  /// The file read last (the caller checks the file still exists).
  static ReadingEntry? last() {
    final ref = _prefs?.getString(_keyLast);
    if (ref == null) return null;
    return of(ref);
  }

  /// The file was deleted: forget its position.
  static Future<void> forget(String ref) async {
    final prefs = await _sp();
    await prefs.remove('$_prefix$ref');
    if (prefs.getString(_keyLast) == ref) await prefs.remove(_keyLast);
    changed.value++;
  }

  /// The file was renamed / moved: keep its position under the new ref.
  static Future<void> moved(String from, String to) async {
    final prefs = await _sp();
    final value = prefs.getString('$_prefix$from');
    if (value == null) return;
    await prefs.remove('$_prefix$from');
    await prefs.setString('$_prefix$to', value);
    if (prefs.getString(_keyLast) == from) await prefs.setString(_keyLast, to);
    changed.value++;
  }

  static ReadingEntry? _parse(String ref, String? raw) {
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length < 3) return null;
    final page = int.tryParse(parts[0]);
    final count = int.tryParse(parts[1]);
    if (page == null || count == null) return null;
    return ReadingEntry(ref: ref, page: page, pageCount: count, time: int.tryParse(parts[2]) ?? 0);
  }
}
