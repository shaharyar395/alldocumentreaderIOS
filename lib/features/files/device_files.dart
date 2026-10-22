import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/doc_entry.dart';
import '../../data/file_library.dart';

/// Real files on the device for Directories (Storage volumes, folder browser, All documents),
/// like the Android app's StorageVolumes / StorageBrowserActivity / AllDocumentsFragment.
/// iOS has no shared storage: there the app's Documents folder is the only "volume".

/// Extensions the in-app viewers open (Android ViewerActivity.canOpen + SheetParser +
/// ImageViewerActivity). Every other Word / Excel / PowerPoint type is handed to another app.
const Set<String> inAppExtensions = {
  'pdf',
  'txt', 'log', 'md', 'json', 'xml',
  'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif',
  'xlsx', 'xlsm', 'xltx', 'xltm', 'ods', 'csv', 'tsv',
  'docx', 'docm', 'dotx',
  'pptx', 'ppsx', 'potx',
};

String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
}

/// True when the app shows this file itself (otherwise: another app, or "not supported").
bool opensInApp(String name) => inAppExtensions.contains(extensionOf(name));

/// One storage volume: its root folder and how many items are directly inside it.
class StorageVolume {
  const StorageVolume(this.root, this.count);
  final String root;
  final int count;

  /// Shown name: the last path segment ("0" for the phone, "0000-000C" for an SD card).
  String get name {
    final base = p.basename(root);
    return base.isEmpty ? root : base;
  }
}

/// The phone storage ("0") and every SD card / USB volume under /storage (Android), or the
/// app's Documents folder (iOS).
Future<List<StorageVolume>> storageVolumes() async {
  final roots = <String>[];
  if (Platform.isAndroid) {
    roots.add('/storage/emulated/0');
    try {
      for (final entity in Directory('/storage').listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == 'emulated' || name == 'self' || name.startsWith('.')) continue;
        if (entity is Directory || FileSystemEntity.isDirectorySync(entity.path)) roots.add(entity.path);
      }
    } catch (_) {
      // /storage is not listable on some phones: the phone storage alone
    }
  } else {
    roots.add((await getApplicationDocumentsDirectory()).path);
  }
  final volumes = <StorageVolume>[];
  for (final root in roots) {
    try {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      volumes.add(StorageVolume(root, dir.listSync(followLinks: false).length));
    } catch (_) {
      // not readable
    }
  }
  return volumes;
}

/// A folder or a file inside a folder of the storage browser.
class DeviceItem {
  const DeviceItem({required this.path, required this.isDir, required this.modified, this.size = 0, this.count = 0});

  final String path;
  final bool isDir;
  final DateTime modified;
  final int size;

  /// Folders: how many items are directly inside.
  final int count;

  String get name => p.basename(path);
}

/// Folders first, then files, newest first in both; hidden items are listed too.
Future<List<DeviceItem>> listFolder(String dir) {
  return Isolate.run(() => _listFolder(dir));
}

List<DeviceItem> _listFolder(String dir) {
  final folders = <DeviceItem>[];
  final files = <DeviceItem>[];
  List<FileSystemEntity> children;
  try {
    children = Directory(dir).listSync(followLinks: false);
  } catch (_) {
    return const [];
  }
  for (final entity in children) {
    try {
      final stat = entity.statSync();
      if (stat.type == FileSystemEntityType.directory) {
        var count = 0;
        try {
          count = Directory(entity.path).listSync(followLinks: false).length;
        } catch (_) {
          count = 0;
        }
        folders.add(DeviceItem(path: entity.path, isDir: true, modified: stat.modified, count: count));
      } else if (stat.type == FileSystemEntityType.file) {
        files.add(DeviceItem(path: entity.path, isDir: false, modified: stat.modified, size: stat.size));
      }
    } catch (_) {
      // unreadable entry
    }
  }
  folders.sort((a, b) => b.modified.compareTo(a.modified));
  files.sort((a, b) => b.modified.compareTo(a.modified));
  return [...folders, ...files];
}

/// "All documents": every file on the storage volumes (all types), newest first, at most 3000.
Future<List<DeviceItem>> allDeviceFiles(List<String> roots) {
  return Isolate.run(() => _allFiles(roots));
}

List<DeviceItem> _allFiles(List<String> roots) {
  const limit = 3000;
  final out = <DeviceItem>[];
  void walk(Directory dir, int depth) {
    List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entity in children) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      try {
        final stat = entity.statSync();
        if (stat.type == FileSystemEntityType.directory) {
          // app-private data and OBB files are not documents (and not readable on Android 11+)
          if (name == 'data' || name == 'obb') {
            if (p.basename(dir.path) == 'Android') continue;
          }
          if (depth < 12) walk(Directory(entity.path), depth + 1);
        } else if (stat.type == FileSystemEntityType.file && stat.size > 0) {
          out.add(DeviceItem(path: entity.path, isDir: false, modified: stat.modified, size: stat.size));
        }
      } catch (_) {
        // unreadable entry
      }
    }
  }

  for (final root in roots) {
    walk(Directory(root), 0);
  }
  out.sort((a, b) => b.modified.compareTo(a.modified));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// A row for a device file that is not (yet) in the library — only for showing it in a list.
DocEntry deviceEntry(DeviceItem item) {
  return DocEntry(
    id: 'device:${item.path}',
    name: item.name,
    relativePath: item.path,
    kind: kindForName(item.name),
    modified: item.modified,
    bytes: item.size,
    openedAt: item.modified,
  );
}

/// The library's entry for the file at [path], registering it when it is a supported type
/// that is not known yet (like the Android app, which works on real paths everywhere).
Future<DocEntry?> libraryEntryFor(FileLibrary library, String path) async {
  final normalized = p.normalize(path);
  for (final entry in library.entries) {
    if (!entry.inBin && p.normalize(entry.fullPath) == normalized) return entry;
  }
  if (kindForName(path) == DocKind.other) return null;
  return library.addFile(path);
}
