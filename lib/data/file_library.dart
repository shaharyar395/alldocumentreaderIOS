import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/format.dart';
import '../services/platform_bridge.dart';
import 'doc_entry.dart';

enum LoadPhase { loading, ready }

/// Result of [FileLibrary.renameChecked] (like the Android app's FileOps.RenameResult).
enum RenameResult { ok, empty, invalid, exists, failed }

/// One path with a time (Recent / Bookmarks / "New" lists).
typedef _Stamp = ({String ref, int time});

/// The app's file index, like the Android app's FileRepository + LibraryStore + NewFiles +
/// RecycleBin.
///
/// Android: with "All files access" every supported file on the phone is found (media index +
/// a folder walk, see MainActivity.scanDevice) and used IN PLACE at its real path: rename,
/// delete, recycle bin and restore act on the real file. Files the app saves (create, convert,
/// merge, split, import…) go to the public folder `Documents/AllDocumentReader/<folder>`, named
/// "name (n).ext" when the name is taken.
///
/// iOS: there is no shared storage. Files the app saves live in `Documents/library/<folder>`
/// (visible in the Files app), files put into the app's Documents folder are listed in place,
/// and files from a folder picked in Files are copied in (once — not again after delete/rename).
///
/// Older versions copied every file into the private folder `library/`; those copies stay
/// listed ([DocEntry.relativePath] relative to [root]).
class FileLibrary extends ChangeNotifier {
  FileLibrary();

  FileLibrary.memory()
      : _memory = true,
        phase = LoadPhase.ready,
        root = '';

  bool _memory = false;

  /// The app's own library folder (Documents/library). Older copies live here.
  String root = '';
  LoadPhase phase = LoadPhase.loading;

  /// Every known file (active ones and the recycle bin).
  List<DocEntry> entries = [];
  int? storageTotal;
  int? storageFree;

  /// Called after the app saved a file (create / convert / merge / split …), not for imports.
  void Function()? onSaved;

  static const _legacyFolders = ['import', 'convert', 'create', 'merged', 'split'];
  static const _maxRecent = 100;

  /// More new files than this in one scan = a memory card / access came back: not "New".
  static const _maxBurst = 300;
  static const _newMaxAge = Duration(days: 30);

  String _meta = '';
  String _binDir = '';
  String _docsDir = '';

  /// Where saved files go: Android Documents/AllDocumentReader, iOS [root].
  String _outputBase = '';

  bool _booted = false;
  bool _scanStarted = false;
  Future<void>? _loading;
  final Completer<void> _firstScan = Completer<void>();

  List<_Stamp> _recent = [];
  final Map<String, int> _bookmarks = {};
  final Map<String, int> _fresh = {};

  /// Every path seen by a full scan (null until the first one: nothing is "New" right after
  /// installing).
  Set<String>? _known;

  /// iOS: "name|size" of picked-folder files the user deleted or renamed (not copied in again).
  final Set<String> _dismissed = {};

  /// Paths removed (deleted, renamed, binned) while a scan runs: the scan must not bring them back.
  final Set<String> _gone = {};

  Future<void>? _running;
  bool _again = false;
  DateTime? _lastScanAt;
  bool _deviceScanned = false;
  bool _scannedWithAccess = false;
  bool _watching = false;

  /// Set when the app saved a file; the home screen shows "Loading files…" → "Loaded
  /// successfully" when it comes back ([takePendingReload]).
  bool pendingReload = false;

  static int _idCounter = 0;

  /// A device scan is running.
  bool get scanning => _running != null;

  /// The first device scan has finished (the home tiles can show counts).
  bool get deviceScanned => _deviceScanned;

  /// The last device scan ran with storage access (Android).
  bool get scannedWithAccess => _scannedWithAccess;

  /// Completes once the library folder is known (the index is loaded).
  Future<void> ensureReady() async {
    if (_memory || _booted) return;
    if (!_scanStarted) unawaited(scan());
    await _firstScan.future;
  }

  List<DocEntry> get active => entries.where((e) => !e.inBin && e.kind != DocKind.other).toList();

  List<DocEntry> get recycled {
    final list = entries.where((e) => e.inBin).toList();
    list.sort((a, b) => (b.deletedAt ?? b.modified).compareTo(a.deletedAt ?? a.modified));
    return list;
  }

  /// Files opened in the app or saved by it, newest open first (at most 100). Each entry's
  /// [DocEntry.openedAt] is the open time.
  List<DocEntry> get recentOpened {
    final byRef = {for (final e in entries) if (!e.inBin && e.kind != DocKind.other) e.relativePath: e};
    return [
      for (final stamp in _recent)
        if (byRef[stamp.ref] case final entry?) entry.copyWith(openedAt: DateTime.fromMillisecondsSinceEpoch(stamp.time)),
    ];
  }

  /// Same as [recentOpened].
  List<DocEntry> get recent => recentOpened;

  /// Bookmarked files, newest bookmark first ([DocEntry.openedAt] is the bookmark time).
  List<DocEntry> get bookmarks {
    final list = [
      for (final e in active)
        if (_bookmarks[e.relativePath] case final time?) e.copyWith(openedAt: DateTime.fromMillisecondsSinceEpoch(time), bookmarked: true),
    ];
    list.sort((a, b) => b.openedAt.compareTo(a.openedAt));
    return list;
  }

  int countOf(DocKind? kind) {
    if (kind == null) return active.length;
    return active.where((e) => e.kind == kind).length;
  }

  int newCountOf(DocKind? kind) {
    final source = kind == null ? active : active.where((e) => e.kind == kind);
    return source.where((e) => e.isNew).length;
  }

  /// "Recently added": changed in the last 30 days or newly found (not opened yet), new ones first.
  List<DocEntry> get recentlyAdded {
    final since = DateTime.now().subtract(const Duration(days: 30));
    final list = active.where((e) => e.isNew || e.modified.isAfter(since)).toList();
    list.sort((a, b) {
      if (a.isNew != b.isNew) return a.isNew ? -1 : 1;
      return (b.addedAt ?? b.modified).compareTo(a.addedAt ?? a.modified);
    });
    return list;
  }

  /// The home "+N": new files (not opened yet) that arrived after [sinceMs].
  int newSince(int sinceMs) {
    return active.where((e) => e.isNew && (e.addedAt ?? e.modified).millisecondsSinceEpoch > sinceMs).length;
  }

  int get libraryBytes => active.fold(0, (sum, e) => sum + e.bytes);

  File fileOf(DocEntry entry) => File(entry.fullPath);

  /// Whether the home screen should show "Loading files…" now (clears the flag).
  bool takePendingReload() {
    final value = pendingReload;
    pendingReload = false;
    return value;
  }

  // ------------------------------------------------------------------ paths

  /// How a path is stored: relative to [root] on iOS (the app's container moves when the app
  /// is updated) and for the old library copies; absolute for real files on Android.
  String _ref(String absolutePath) {
    final normalized = p.normalize(absolutePath);
    if (root.isEmpty) return normalized;
    if (Platform.isIOS || p.isWithin(root, normalized)) return p.relative(normalized, from: root);
    return normalized;
  }

  static String _newId(String name) => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}_$name';

  // ------------------------------------------------------------------ loading / saving

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final docs = await getApplicationDocumentsDirectory();
    _docsDir = docs.path;
    root = p.join(docs.path, 'library');
    DocEntry.libraryRoot = root;
    final support = await getApplicationSupportDirectory();
    _meta = p.join(support.path, 'library_meta');
    _binDir = p.join(support.path, 'RecycleBin');
    await Directory(_meta).create(recursive: true);
    if (Platform.isAndroid) {
      final documents = await PlatformBridge.publicDocumentsDir() ?? '/storage/emulated/0/Documents';
      _outputBase = p.join(documents, 'AllDocumentReader');
    } else {
      _outputBase = root;
    }

    // the index: the app-private copy, or the one older versions kept in Documents/library
    final index = File(p.join(_meta, 'index.json'));
    final legacyIndex = File(p.join(root, 'index.json'));
    var loaded = <DocEntry>[];
    try {
      if (await index.exists()) {
        loaded = decodeEntries(await index.readAsString());
      } else if (await legacyIndex.exists()) {
        loaded = decodeEntries(await legacyIndex.readAsString());
      }
    } catch (error) {
      debugPrint('library index: $error');
    }
    entries = loaded;

    final state = File(p.join(_meta, 'state.json'));
    var hasState = false;
    try {
      if (await state.exists()) {
        _readState(json.decode(await state.readAsString()) as Map<String, dynamic>);
        hasState = true;
      }
    } catch (error) {
      debugPrint('library state: $error');
    }
    if (!hasState) _migrate();
    entries = [for (final e in entries) _decorate(e)];
    if (!hasState || !await index.exists()) {
      await _persist();
      // older versions kept the index next to the files (visible in the iOS Files app)
      try {
        if (await legacyIndex.exists()) await legacyIndex.delete();
      } catch (_) {
        // stays; it is not read again
      }
    }
  }

  /// First start of this version: Recent / Bookmarks / "New" come from the old index flags.
  void _migrate() {
    final recent = <_Stamp>[];
    for (final e in entries) {
      if (e.inBin) continue;
      if (e.bookmarked) _bookmarks[e.relativePath] = e.openedAt.millisecondsSinceEpoch;
      if (e.isNew) _fresh[e.relativePath] = (e.addedAt ?? DateTime.now()).millisecondsSinceEpoch;
      // files the app saved itself (not the scan copies in import/) were in Recent before
      final top = p.split(e.relativePath).first;
      if (!p.isAbsolute(e.relativePath) && top != 'import') {
        recent.add((ref: e.relativePath, time: e.openedAt.millisecondsSinceEpoch));
      }
    }
    recent.sort((a, b) => b.time.compareTo(a.time));
    _recent = recent.take(_maxRecent).toList();
  }

  void _readState(Map<String, dynamic> raw) {
    List<_Stamp> stamps(Object? list) {
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is List && item.length == 2 && item[0] is String && item[1] is num) (ref: item[0] as String, time: (item[1] as num).toInt()),
      ];
    }

    _recent = stamps(raw['recent']);
    _bookmarks
      ..clear()
      ..addEntries(stamps(raw['bookmarks']).map((s) => MapEntry(s.ref, s.time)));
    _fresh
      ..clear()
      ..addEntries(stamps(raw['fresh']).map((s) => MapEntry(s.ref, s.time)));
    final known = raw['known'];
    _known = known is List ? {for (final item in known) item.toString()} : null;
    final dismissed = raw['dismissed'];
    _dismissed
      ..clear()
      ..addAll(dismissed is List ? dismissed.map((e) => e.toString()) : const <String>[]);
  }

  Future<void> _persistChain = Future<void>.value();

  /// Saves the index and the lists (one write at a time, in order).
  Future<void> _persist() {
    if (_memory || _meta.isEmpty) return Future<void>.value();
    return _persistChain = _persistChain.then((_) => _writeNow());
  }

  Future<void> _writeNow() async {
    List<List<Object>> stamps(Iterable<_Stamp> list) => [for (final s in list) [s.ref, s.time]];
    final state = {
      'v': 1,
      'recent': stamps(_recent),
      'bookmarks': stamps(_bookmarks.entries.map((e) => (ref: e.key, time: e.value))),
      'fresh': stamps(_fresh.entries.map((e) => (ref: e.key, time: e.value))),
      'known': _known?.toList(),
      'dismissed': _dismissed.toList(),
    };
    try {
      await _writeAtomic(File(p.join(_meta, 'index.json')), encodeEntries(entries));
      await _writeAtomic(File(p.join(_meta, 'state.json')), json.encode(state));
    } catch (error) {
      debugPrint('library save: $error');
    }
  }

  static Future<void> _writeAtomic(File file, String text) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
  }

  DocEntry _decorate(DocEntry e) {
    if (e.inBin) return e.copyWith(isNew: false, bookmarked: false);
    final found = _fresh[e.relativePath];
    return e.copyWith(
      bookmarked: _bookmarks.containsKey(e.relativePath),
      isNew: found != null,
      addedAt: found == null ? null : DateTime.fromMillisecondsSinceEpoch(found),
    );
  }

  /// A scan worked on [snapshot] while the user may have changed files (save, rename, delete,
  /// bookmark…): keeps those changes on top of the scan's [computed] list.
  List<DocEntry> _reconcile(List<DocEntry> snapshot, List<DocEntry> computed) {
    if (identical(snapshot, entries)) return computed;
    final before = {for (final e in snapshot) e.id: e};
    final current = {for (final e in entries) e.id: e};
    final addedRefs = {
      for (final e in entries)
        if (!before.containsKey(e.id) && !e.inBin) e.relativePath,
    };
    final out = <DocEntry>[];
    final seen = <String>{};
    for (final e in computed) {
      final old = before[e.id];
      final now = current[e.id];
      if (old != null && now == null) continue; // removed meanwhile
      if (old == null && now == null && !e.inBin && addedRefs.contains(e.relativePath)) continue; // saved meanwhile
      out.add(old != null && now != null && !identical(old, now) ? now : e);
      seen.add(e.id);
    }
    for (final e in entries) {
      if (!before.containsKey(e.id) && !seen.contains(e.id)) out.add(e);
    }
    return out;
  }

  // ------------------------------------------------------------------ scanning

  /// Loads the index and re-checks the files already known (sizes, dates, files that are gone),
  /// plus the app's own library folder. No device scan and no permission prompts.
  Future<void> scan() async {
    if (_memory) {
      phase = LoadPhase.ready;
      notifyListeners();
      return;
    }
    _scanStarted = true;
    try {
      await _ensureLoaded();
      await _scanKnown();
      _booted = true;
    } catch (error, stack) {
      debugPrint('library scan: $error\n$stack');
    }
    phase = LoadPhase.ready;
    if (!_firstScan.isCompleted) _firstScan.complete();
    notifyListeners();
  }

  Future<void> _scanKnown() async {
    final now = DateTime.now();
    final snapshot = entries;
    final next = <DocEntry>[];
    final refs = <String>{};
    for (final e in snapshot) {
      FileStat stat;
      try {
        stat = await File(e.fullPath).stat();
      } catch (_) {
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue; // deleted or moved by another app
      if (!refs.add(e.relativePath)) continue;
      if (e.inBin) {
        final deleted = e.deletedAt ?? stat.modified;
        if (now.difference(deleted) >= _newMaxAge) {
          try {
            await File(e.fullPath).delete();
          } catch (_) {
            // tried again next time
          }
          continue;
        }
        next.add(e.copyWith(bytes: stat.size));
        continue;
      }
      next.add(e.copyWith(bytes: stat.size, modified: stat.modified, kind: kindForName(e.name)));
    }

    // the private library folders (older copies; outputs saved when the public folder was not
    // writable) and its old recycle bin
    for (final folder in [..._legacyFolders, 'recycle']) {
      final dir = Directory(p.join(root, folder));
      if (!await dir.exists()) continue;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('.') || kindForName(name) == DocKind.other) continue;
          final ref = _ref(entity.path);
          if (refs.contains(ref)) continue;
          final stat = await entity.stat();
          if (folder == 'recycle') {
            if (now.difference(stat.modified) >= _newMaxAge) {
              await entity.delete();
              continue;
            }
            next.add(_entryFor(ref, name, stat.size, stat.modified).copyWith(deletedAt: stat.modified));
          } else {
            next.add(_entryFor(ref, name, stat.size, stat.modified));
          }
          refs.add(ref);
        }
      } catch (error) {
        debugPrint('library folder $folder: $error');
      }
    }
    _fresh.removeWhere((_, at) => now.millisecondsSinceEpoch - at >= _newMaxAge.inMilliseconds);
    entries = [for (final e in _reconcile(snapshot, next)) _decorate(e)];
    await _persist();
  }

  DocEntry _entryFor(String ref, String name, int size, DateTime modified) {
    return DocEntry(
      id: _newId(name),
      name: name,
      relativePath: ref,
      kind: kindForName(name),
      modified: modified,
      bytes: size,
      openedAt: modified,
    );
  }

  /// Scans the device for files (Android: every supported file when storage access is on,
  /// otherwise only the app's own saved files; iOS: the app's Documents folder and the folder
  /// picked in Files). Calls while a scan runs make it run once more afterwards.
  Future<void> rescan() {
    if (_memory) return scan();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _rescanLoop();
    _running = run;
    return run;
  }

  Future<void> _rescanLoop() async {
    await Future<void>.value();
    notifyListeners();
    try {
      do {
        _again = false;
        _gone.clear();
        await _rescanOnce();
      } while (_again);
    } catch (error, stack) {
      debugPrint('device scan: $error\n$stack');
    } finally {
      _running = null;
      _lastScanAt = DateTime.now();
      notifyListeners();
    }
  }

  /// Back in the app: scans again when the last scan is older than [maxAge] (like the Android
  /// app's refreshIfStale).
  Future<void> refreshIfStale({Duration maxAge = const Duration(seconds: 8)}) async {
    if (_memory) return;
    final last = _lastScanAt;
    if (!_deviceScanned || last == null || DateTime.now().difference(last) > maxAge) await rescan();
  }

  /// Android: rescans (debounced 2.5 s natively) when other apps add or remove files.
  void startWatching() {
    if (_memory || _watching) return;
    _watching = true;
    PlatformBridge.mediaChanged.addListener(_onMediaChanged);
    unawaited(PlatformBridge.startWatching());
  }

  void _onMediaChanged() {
    if (_deviceScanned) unawaited(rescan());
  }

  Future<void> _rescanOnce() async {
    await scan();
    final found = <String, DeviceFile>{};
    var fullScan = false;
    var withAccess = false;
    if (Platform.isAndroid) {
      final access = await PlatformBridge.storageAccess();
      withAccess = access;
      if (access) {
        for (final file in await PlatformBridge.scanDevice(supportedExtensions)) {
          if (kindForName(file.path) == DocKind.other) continue;
          found[_ref(file.path)] = file;
        }
        fullScan = true;
      } else {
        // without access only the app's own saved files can be read
        await _walk(Directory(_outputBase), found, maxDepth: 3);
      }
    } else if (Platform.isIOS) {
      // the app's own folders in Documents are not the user's documents
      final skip = {
        for (final name in const ['library', 'signatures', 'tpl_images', 'tessdata', 'Inbox']) p.normalize(p.join(_docsDir, name)),
      };
      await _walk(Directory(_docsDir), found, maxDepth: 6, skip: skip);
      await _importIosPicked(found);
      fullScan = true;
      withAccess = true;
    }
    await _merge(found, fullScan: fullScan);
    _scannedWithAccess = withAccess;
    _deviceScanned = true;
    await _persist();
    notifyListeners();
    await _publishWidget();
  }

  Future<void> _walk(Directory dir, Map<String, DeviceFile> out, {required int maxDepth, int depth = 0, Set<String> skip = const {}}) async {
    if (depth > maxDepth) return;
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (entity is Directory) {
          if (skip.contains(p.normalize(entity.path))) continue;
          await _walk(entity, out, maxDepth: maxDepth, depth: depth + 1, skip: skip);
        } else if (entity is File) {
          if (kindForName(name) == DocKind.other) continue;
          final stat = await entity.stat();
          if (stat.size <= 0) continue;
          out[_ref(entity.path)] = (path: entity.path, size: stat.size, modified: stat.modified.millisecondsSinceEpoch);
        }
      }
    } catch (error) {
      debugPrint('folder scan ${dir.path}: $error');
    }
  }

  Future<void> _merge(Map<String, DeviceFile> found, {required bool fullScan}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final snapshot = entries;
    final byRef = {for (final e in snapshot) e.relativePath: e};
    final next = <DocEntry>[
      for (final e in snapshot)
        if (!found.containsKey(e.relativePath)) e,
    ];
    for (final item in found.entries) {
      if (_gone.contains(item.key)) continue;
      final file = item.value;
      final name = p.basename(file.path);
      final modified = DateTime.fromMillisecondsSinceEpoch(file.modified);
      final previous = byRef[item.key];
      if (previous != null && previous.inBin) continue;
      next.add(
        previous == null
            ? _entryFor(item.key, name, file.size, modified)
            : previous.copyWith(name: name, bytes: file.size, modified: modified, kind: kindForName(name)),
      );
    }

    // "New" files (like the Android app's NewFiles.onScan)
    if (fullScan && found.isNotEmpty) {
      final known = _known;
      if (known == null) {
        // first scan after installing: remember what is there, nothing is "new"
        _known = found.keys.toSet();
      } else {
        final recent = {for (final s in _recent) s.ref};
        final added = [
          for (final ref in found.keys)
            if (!known.contains(ref) && !recent.contains(ref)) ref,
        ];
        known.addAll(added);
        final present = {...found.keys, for (final e in next) e.relativePath};
        _fresh.removeWhere((ref, at) => !present.contains(ref) || now - at >= _newMaxAge.inMilliseconds);
        if (added.isNotEmpty && added.length <= _maxBurst) {
          for (final ref in added) {
            _fresh[ref] = now;
          }
        }
      }
    }

    if (Platform.isAndroid && fullScan) await _dropLegacyTwins(next, found);
    entries = [for (final e in _reconcile(snapshot, next)) _decorate(e)];
  }

  /// Older versions copied scanned files into library/import. Now that the real files are
  /// listed, a copy whose original (same name and size) is on the phone is a duplicate: its
  /// bookmark / Recent place move to the original and the copy is removed.
  Future<void> _dropLegacyTwins(List<DocEntry> list, Map<String, DeviceFile> found) async {
    final twins = <String, String>{};
    for (final item in found.entries) {
      twins.putIfAbsent('${p.basename(item.value.path).toLowerCase()}|${item.value.size}', () => item.key);
    }
    final drop = <DocEntry>[];
    for (final e in list) {
      if (e.inBin || p.isAbsolute(e.relativePath) || p.split(e.relativePath).first != 'import') continue;
      final twin = twins['${e.name.toLowerCase()}|${e.bytes}'];
      if (twin == null) continue;
      final mark = _bookmarks.remove(e.relativePath);
      if (mark != null) _bookmarks.putIfAbsent(twin, () => mark);
      final hasTwin = _recent.any((s) => s.ref == twin);
      _recent = [
        for (final s in _recent)
          if (s.ref == e.relativePath) ...[if (!hasTwin) (ref: twin, time: s.time)] else s,
      ];
      _fresh.remove(e.relativePath);
      try {
        await File(e.fullPath).delete();
        drop.add(e);
      } catch (error) {
        debugPrint('legacy copy: $error');
      }
    }
    list.removeWhere(drop.contains);
  }

  /// iOS: files of the folder picked in Files are copied in once (a copy with the same name and
  /// size is reused; files the user deleted or renamed in the app are not copied again).
  Future<void> _importIosPicked(Map<String, DeviceFile> found) async {
    final prefs = await SharedPreferences.getInstance();
    final sources = <String>[];
    final temps = <String>[];
    final savedRoot = prefs.getString('ios_scan_root');
    if (savedRoot != null && savedRoot.isNotEmpty) {
      final walked = <String, DeviceFile>{};
      await _walk(Directory(savedRoot), walked, maxDepth: 6);
      sources.addAll(walked.values.map((f) => f.path));
    }
    final bookmarked = await PlatformBridge.iosBookmarkedFiles();
    sources.addAll(bookmarked);
    temps.addAll(bookmarked);
    for (final path in sources) {
      final file = File(path);
      try {
        if (!await file.exists()) continue;
        final stat = await file.stat();
        final name = p.basename(path);
        if (kindForName(name) == DocKind.other || stat.size <= 0) continue;
        final key = '${name.toLowerCase()}|${stat.size}';
        if (_dismissed.contains(key)) continue;
        var copy = _sameFile(name, stat.size);
        if (copy == null) {
          final dest = await _writeOut('import', name, (target) => file.copy(target.path));
          if (dest == null) continue;
          try {
            await dest.setLastModified(stat.modified);
          } catch (_) {
            // keeps the copy's own date
          }
          final destStat = await dest.stat();
          copy = _entryFor(_ref(dest.path), p.basename(dest.path), destStat.size, destStat.modified);
          entries = [...entries, copy];
        }
        found[copy.relativePath] = (path: copy.fullPath, size: copy.bytes, modified: copy.modified.millisecondsSinceEpoch);
      } catch (error) {
        debugPrint('ios scan import: $error');
      }
    }
    for (final path in temps) {
      try {
        final temp = File(path);
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // a temp file; the system cleans it
      }
    }
  }

  /// An active entry with this name and size (a copy that can be reused).
  DocEntry? _sameFile(String name, int size) {
    final lower = name.toLowerCase();
    for (final e in entries) {
      if (!e.inBin && e.bytes == size && e.name.toLowerCase() == lower) return e;
    }
    return null;
  }

  Future<void> _publishWidget() async {
    final line = '${active.length}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('widget_line', line);
    await PlatformBridge.updateWidget(line);
  }

  // ------------------------------------------------------------------ saving files

  /// The folders a saved file may go to, in order: Android the public
  /// `Documents/AllDocumentReader/<folder>` first, then the private library as a fallback.
  List<String> _outputDirs(String folder) {
    final private = p.join(root, folder);
    if (Platform.isAndroid && _outputBase.isNotEmpty) return [p.join(_outputBase, folder), private];
    return [private];
  }

  /// Writes a new file named [name] ("name (n).ext" when taken) into the first writable output
  /// folder for [folder]; null when it could not be written anywhere.
  Future<File?> _writeOut(String folder, String name, Future<Object?> Function(File target) write) async {
    for (final dir in _outputDirs(folder)) {
      File? target;
      try {
        await Directory(dir).create(recursive: true);
        target = File(_uniquePath(dir, name));
        await write(target);
        return target;
      } catch (error) {
        debugPrint('save to $dir: $error');
        try {
          if (target != null && await target.exists()) await target.delete();
        } catch (_) {
          // nothing more to do
        }
      }
    }
    return null;
  }

  static String _uniquePath(String dir, String name) {
    final first = p.join(dir, name);
    if (!File(first).existsSync() && !Directory(first).existsSync()) return first;
    final ext = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '$stem ($i)$ext');
      if (!File(candidate).existsSync()) return candidate;
      i++;
    }
  }

  Future<DocEntry?> importPath(String source, {String? name, String folder = 'import'}) async {
    if (_memory) return null;
    final file = File(source);
    if (!await file.exists()) return null;
    await ensureReady();
    final fileName = safeFileName(name ?? p.basename(source));
    final stat = await file.stat();
    if (folder == 'import') {
      final existing = await _existingImport(fileName, stat.size);
      if (existing != null) return existing;
    }
    final dest = await _writeOut(folder, fileName, (target) => file.copy(target.path));
    if (dest == null) return null;
    try {
      await dest.setLastModified(stat.modified);
    } catch (_) {
      // keeps the copy's own date
    }
    return _registerSaved(dest, folder);
  }

  /// Writes a file the app made (create / convert / merge / split …) or imported. Android: into
  /// Documents/AllDocumentReader/[folder] on the phone ("name (n).ext" when taken); iOS: into
  /// the app's library. It goes to the top of Recent. [modified] keeps a source's date.
  Future<DocEntry?> importBytes(
    List<int> bytes, {
    required String name,
    String folder = 'import',
    bool? isNew,
    DateTime? modified,
  }) async {
    if (_memory) return null;
    await ensureReady();
    final fileName = safeFileName(name);
    if (folder == 'import') {
      final existing = await _existingImport(fileName, bytes.length);
      if (existing != null) return existing;
    }
    final dest = await _writeOut(folder, fileName, (target) => target.writeAsBytes(bytes, flush: true));
    if (dest == null) return null;
    if (modified != null) {
      try {
        await dest.setLastModified(modified);
      } catch (_) {
        // keeps the copy's own date
      }
    }
    return _registerSaved(dest, folder, isNew: isNew ?? false);
  }

  /// An import that is already there (same name and size in the import folder): reused instead
  /// of making "name (1)" (like the Android app's OpenDocumentActivity).
  Future<DocEntry?> _existingImport(String name, int size) async {
    for (final dir in _outputDirs('import')) {
      final file = File(p.join(dir, name));
      try {
        if (await file.exists() && await file.length() == size) {
          return await addFile(file.path, saved: false);
        }
      } catch (_) {
        // not readable: a new copy is made
      }
    }
    return null;
  }

  Future<DocEntry?> _registerSaved(File dest, String folder, {bool isNew = false}) async {
    final entry = await _register(dest.path, isNew: isNew);
    if (entry == null) return null;
    pendingReload = true;
    if (folder != 'import') onSaved?.call();
    return entry;
  }

  /// Adds an existing file (e.g. one the app just wrote) to the lists and to the top of Recent
  /// and returns its entry. [saved] (default) counts it as a file the app saved.
  Future<DocEntry?> addFile(String absolutePath, {bool saved = true}) async {
    if (_memory) return null;
    await ensureReady();
    final entry = await _register(absolutePath);
    if (entry != null && saved) {
      pendingReload = true;
      onSaved?.call();
    }
    return entry;
  }

  Future<DocEntry?> _register(String absolutePath, {bool isNew = false}) async {
    final file = File(absolutePath);
    FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final ref = _ref(absolutePath);
    final name = p.basename(absolutePath);
    final now = DateTime.now();
    final previous = entries.where((e) => e.relativePath == ref && !e.inBin).firstOrNull;
    final base = (previous ?? _entryFor(ref, name, stat.size, stat.modified))
        .copyWith(name: name, bytes: stat.size, modified: stat.modified, kind: kindForName(name), openedAt: now);
    _known?.add(ref);
    if (isNew) {
      _fresh[ref] = now.millisecondsSinceEpoch;
    } else {
      _fresh.remove(ref);
      _pushRecent(ref, now);
    }
    _gone.remove(ref);
    final entry = _decorate(base);
    entries = [...entries.where((e) => e.id != entry.id && !(e.relativePath == ref && !e.inBin)), entry];
    await _persist();
    notifyListeners();
    unawaited(PlatformBridge.scanPaths([absolutePath]));
    return entry;
  }

  void _pushRecent(String ref, DateTime at) {
    _recent = [
      (ref: ref, time: at.millisecondsSinceEpoch),
      ..._recent.where((s) => s.ref != ref),
    ].take(_maxRecent).toList();
  }

  /// The app wrote [path] itself (e.g. saved an edit in place): re-read the lists.
  Future<void> noteIfInside(String path) async {
    if (root.isEmpty) return;
    final normalized = p.normalize(path);
    if (byPath(normalized) == null && !p.isWithin(root, normalized)) return;
    await scan();
  }

  DocEntry? byPath(String path) {
    final normalized = p.normalize(path);
    for (final entry in entries) {
      if (p.normalize(entry.fullPath) == normalized) return entry;
    }
    return null;
  }

  // ------------------------------------------------------------------ user actions

  Future<void> toggleBookmark(DocEntry entry) async {
    final ref = entry.relativePath;
    if (_bookmarks.remove(ref) == null) _bookmarks[ref] = DateTime.now().millisecondsSinceEpoch;
    entries = [for (final e in entries) if (e.relativePath == ref && !e.inBin) _decorate(e) else e];
    await _persist();
    notifyListeners();
  }

  /// Renames keeping the extension, like the Android app's FileOps.rename: [newBaseName] is the
  /// name without extension.
  Future<RenameResult> renameChecked(DocEntry entry, String newBaseName) async {
    final base = newBaseName.trim();
    if (base.isEmpty) return RenameResult.empty;
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(base) || base == '.' || base == '..') return RenameResult.invalid;
    final dot = entry.name.lastIndexOf('.');
    final ext = dot > 0 ? entry.name.substring(dot) : '';
    final newName = '$base$ext';
    if (newName == entry.name) return RenameResult.ok;
    final src = File(entry.fullPath);
    final dst = p.join(p.dirname(src.path), newName);
    try {
      final sameIgnoringCase = newName.toLowerCase() == entry.name.toLowerCase();
      if (!sameIgnoringCase && (await File(dst).exists() || await Directory(dst).exists())) return RenameResult.exists;
      if (!await src.exists()) return RenameResult.failed;
      await src.rename(dst);
    } catch (error) {
      debugPrint('rename: $error');
      return RenameResult.failed;
    }
    await _afterRename(entry, dst);
    return RenameResult.ok;
  }

  /// Renames a file ([nextName] with or without its extension); "name (n)" when the name is taken.
  Future<void> rename(DocEntry entry, String nextName) async {
    final base = safeFileName(nextName);
    final ext = p.extension(entry.name);
    final withExt = base.toLowerCase().endsWith(ext.toLowerCase()) || ext.isEmpty ? base : '$base$ext';
    final src = File(entry.fullPath);
    final dir = p.dirname(src.path);
    if (withExt == entry.name) return;
    final target = withExt.toLowerCase() == entry.name.toLowerCase() ? p.join(dir, withExt) : _uniquePath(dir, withExt);
    await src.rename(target);
    await _afterRename(entry, target);
  }

  Future<void> _afterRename(DocEntry entry, String newPath) async {
    final oldRef = entry.relativePath;
    final newRef = _ref(newPath);
    final oldPath = entry.fullPath;
    _moveRef(oldRef, newRef);
    if (Platform.isIOS) _dismissed.add('${entry.name.toLowerCase()}|${entry.bytes}');
    final name = p.basename(newPath);
    final updated = _decorate(entry.copyWith(name: name, relativePath: newRef, kind: kindForName(name)));
    entries = [for (final e in entries) if (e.id == entry.id) updated else e];
    await _persist();
    notifyListeners();
    unawaited(PlatformBridge.scanPaths([oldPath, newPath]));
  }

  /// A renamed file keeps its Recent / Bookmarks / "New" state.
  void _moveRef(String oldRef, String newRef) {
    _recent = [for (final s in _recent) s.ref == oldRef ? (ref: newRef, time: s.time) : s];
    final mark = _bookmarks.remove(oldRef);
    if (mark != null) _bookmarks[newRef] = mark;
    final fresh = _fresh.remove(oldRef);
    if (fresh != null) _fresh[newRef] = fresh;
    _known?.add(newRef);
    _gone.add(oldRef);
    _gone.remove(newRef);
  }

  /// A deleted file leaves Recent and Bookmarks (like LibraryStore.purge).
  void _forgetRef(String ref) {
    _recent = _recent.where((s) => s.ref != ref).toList();
    _bookmarks.remove(ref);
    _fresh.remove(ref);
    _gone.add(ref);
  }

  Future<void> moveToBin(DocEntry entry) async {
    if (entry.inBin) return;
    await _moveToBin(entry);
    await _persist();
    notifyListeners();
  }

  /// Moves several files to the recycle bin; returns how many were moved.
  Future<int> moveManyToBin(List<DocEntry> list) async {
    var done = 0;
    for (final entry in list) {
      if (entry.inBin) continue;
      try {
        await _moveToBin(entry);
        done++;
      } catch (error) {
        debugPrint('move to bin: $error');
      }
    }
    await _persist();
    notifyListeners();
    return done;
  }

  /// Restores several files from the recycle bin; returns how many were restored.
  Future<int> restoreMany(List<DocEntry> list) async {
    var done = 0;
    for (final entry in list) {
      try {
        await _restore(entry);
        done++;
      } catch (error) {
        debugPrint('restore: $error');
      }
    }
    await _persist();
    notifyListeners();
    return done;
  }

  /// Deletes several files for good (from the bin or directly); returns how many were deleted.
  Future<int> deleteManyForever(List<DocEntry> list) async {
    var done = 0;
    final gone = <String>{};
    final paths = <String>[];
    for (final entry in list) {
      try {
        final file = fileOf(entry);
        if (await file.exists()) await file.delete();
        gone.add(entry.id);
        if (!entry.inBin) {
          _forgetRef(entry.relativePath);
          paths.add(entry.fullPath);
        }
        done++;
      } catch (error) {
        debugPrint('delete: $error');
      }
    }
    entries = entries.where((e) => !gone.contains(e.id)).toList();
    await _persist();
    notifyListeners();
    unawaited(PlatformBridge.scanPaths(paths));
    return done;
  }

  /// Moves the file into the app's recycle bin (kept 30 days; restore puts it back where it was).
  Future<void> _moveToBin(DocEntry entry) async {
    await Directory(_binDir).create(recursive: true);
    var stamp = DateTime.now().millisecondsSinceEpoch;
    while (File(p.join(_binDir, '${stamp}_${entry.name}')).existsSync()) {
      stamp++;
    }
    final dest = p.join(_binDir, '${stamp}_${entry.name}');
    final original = entry.fullPath;
    await _move(File(original), dest);
    _forgetRef(entry.relativePath);
    if (Platform.isIOS) _dismissed.add('${entry.name.toLowerCase()}|${entry.bytes}');
    final binned = entry.copyWith(relativePath: _ref(dest), deletedAt: DateTime.now(), originalPath: original, isNew: false, bookmarked: false);
    entries = [for (final e in entries) if (e.id == entry.id) binned else e];
    unawaited(PlatformBridge.scanPaths([original]));
  }

  Future<void> restore(DocEntry entry) async {
    await _restore(entry);
    await _persist();
    notifyListeners();
  }

  Future<void> _restore(DocEntry entry) async {
    final original = entry.originalPath.isNotEmpty ? entry.originalPath : p.join(root, 'import', entry.name);
    final dir = p.dirname(original);
    await Directory(dir).create(recursive: true);
    final dest = File(original).existsSync() ? _uniquePath(dir, p.basename(original)) : original;
    await _move(fileOf(entry), dest);
    final ref = _ref(dest);
    final name = p.basename(dest);
    _known?.add(ref);
    _gone.remove(ref);
    final restored = _decorate(entry.copyWith(
      name: name,
      relativePath: ref,
      kind: kindForName(name),
      clearDeleted: true,
      openedAt: DateTime.now(),
    ));
    entries = [for (final e in entries) if (e.id == entry.id) restored else e];
    unawaited(PlatformBridge.scanPaths([dest]));
  }

  /// Moves a file, also between storage volumes (copy, then delete the source).
  static Future<void> _move(File source, String dest) async {
    try {
      await source.rename(dest);
      return;
    } on FileSystemException {
      // another volume: copy below
    }
    final copy = await source.copy(dest);
    try {
      await source.delete();
    } catch (error) {
      await copy.delete();
      rethrow;
    }
  }

  Future<void> deleteForever(DocEntry entry) async {
    await deleteManyForever([entry]);
  }

  Future<void> emptyBin() async {
    for (final entry in recycled) {
      try {
        final file = fileOf(entry);
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint('empty bin: $error');
      }
    }
    entries = entries.where((e) => !e.inBin).toList();
    await _persist();
    notifyListeners();
  }

  /// Opened in the app: top of Recent, no "New" tag any more.
  Future<void> markOpened(DocEntry entry) async {
    if (!_memory && !entries.any((e) => e.id == entry.id || (e.relativePath == entry.relativePath && !e.inBin))) {
      // a file from outside the lists (e.g. Directories → Storage): it joins them, top of Recent
      await ensureReady();
      await _register(entry.fullPath);
      return;
    }
    final now = DateTime.now();
    final ref = entry.relativePath;
    _pushRecent(ref, now);
    _fresh.remove(ref);
    _known?.add(ref);
    entries = [for (final e in entries) if (e.id == entry.id) _decorate(e.copyWith(openedAt: now)) else e];
    await _persist();
    notifyListeners();
  }

  Future<void> clearNew({DocKind? kind}) async {
    for (final entry in entries) {
      if (!entry.inBin && (kind == null || entry.kind == kind)) _fresh.remove(entry.relativePath);
    }
    entries = [for (final e in entries) _decorate(e)];
    await _persist();
    notifyListeners();
  }

  void setStorage(int total, int free) {
    storageTotal = total;
    storageFree = free;
    notifyListeners();
  }
}
