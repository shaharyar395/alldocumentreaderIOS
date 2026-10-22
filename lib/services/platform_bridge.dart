import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A file that came from outside: "Open with" / share from another app, or a pinned
/// "To home screen" shortcut ([shortcut] true; [uri] is then a plain file path).
typedef IncomingFile = ({String uri, bool shortcut});

/// What the system knows about an incoming content:// / file:// uri. [path] is the real file
/// when the app can read it in place (Android), otherwise null and the file must be copied.
typedef IncomingInfo = ({String? path, String name, String mime, int size});

/// One file found by the Android device scan.
typedef DeviceFile = ({String path, int size, int modified});

class PlatformBridge {
  static const _channel = MethodChannel('com.theoccess.alldocreader/platform');

  /// Home-screen widget buttons and the iOS widget link: "search", "recent", "bookmarks",
  /// "edit" or "home". The main screen handles it and sets it back to null.
  static final ValueNotifier<String?> widgetAction = ValueNotifier<String?>(null);

  /// Counts up when Android's media index changed (another app added / removed a file); the
  /// native side already waits 2.5 s for the changes to settle (see [startWatching]).
  static final ValueNotifier<int> mediaChanged = ValueNotifier<int>(0);

  static void listen(void Function(IncomingFile file) onIncoming) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onIncomingUri':
          final file = _incoming(call.arguments);
          if (file != null) onIncoming(file);
        case 'onWidgetAction':
          final action = call.arguments as String?;
          if (action != null && action.isNotEmpty) widgetAction.value = action;
        case 'onMediaChanged':
          mediaChanged.value++;
      }
    });
  }

  static IncomingFile? _incoming(Object? raw) {
    if (raw is String) return raw.isEmpty ? null : (uri: raw, shortcut: false);
    if (raw is Map) {
      final uri = raw['uri']?.toString() ?? '';
      if (uri.isEmpty) return null;
      return (uri: uri, shortcut: raw['shortcut'] == true);
    }
    return null;
  }

  /// The widget action that started the app (cold start), if any.
  static Future<void> pullPendingAction() async {
    try {
      final action = await _channel.invokeMethod<String>('takePendingAction');
      if (action != null && action.isNotEmpty) widgetAction.value = action;
    } catch (error) {
      debugPrint('pending action: $error');
    }
  }

  /// The app's version name (Android versionName, iOS CFBundleShortVersionString).
  static Future<String?> appVersion() async {
    try {
      return await _channel.invokeMethod<String>('appVersion');
    } catch (error) {
      return null;
    }
  }

  /// Android: asks the launcher to pin a shortcut that opens [path] in the app. The icon is the
  /// file type's icon ([kind] is a DocKind name: pdf, word, excel, ppt, txt, image, other).
  static Future<bool> pinShortcut(String path, String name, {String kind = 'other'}) async {
    try {
      return await _channel.invokeMethod<bool>('pinShortcut', {'path': path, 'name': name, 'kind': kind}) ?? false;
    } catch (error) {
      debugPrint('pin shortcut: $error');
      return false;
    }
  }

  /// Android: asks the launcher to place a home-screen widget ([kind] "tools" or "reader").
  static Future<bool> pinWidget(String kind) async {
    try {
      return await _channel.invokeMethod<bool>('pinWidget', {'kind': kind}) ?? false;
    } catch (error) {
      debugPrint('pin widget: $error');
      return false;
    }
  }

  /// The file (or shortcut) that started the app, if any; read once.
  static Future<IncomingFile?> takePendingIncoming() async {
    try {
      return _incoming(await _channel.invokeMethod<Object?>('takePendingIncoming'));
    } catch (error) {
      return null;
    }
  }

  /// Older form of [takePendingIncoming] (the uri only).
  static Future<String?> takePendingUri() async => (await takePendingIncoming())?.uri;

  static Future<String?> displayName(String uri) async {
    try {
      return await _channel.invokeMethod<String>('displayName', {'uri': uri});
    } catch (error) {
      return null;
    }
  }

  /// Name, MIME type, size and (when readable in place) the real path of an incoming uri.
  static Future<IncomingInfo?> resolveIncoming(String uri) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('resolveIncoming', {'uri': uri});
      if (raw == null) return null;
      final path = raw['path']?.toString();
      final size = raw['size'];
      return (
        path: path == null || path.isEmpty ? null : path,
        name: raw['name']?.toString() ?? '',
        mime: raw['mime']?.toString() ?? '',
        size: size is num ? size.toInt() : -1,
      );
    } catch (error) {
      debugPrint('resolve incoming: $error');
      return null;
    }
  }

  static Future<void> copyUri(String uri, String dest) async {
    await _channel.invokeMethod<void>('copyUri', {'uri': uri, 'dest': dest});
  }

  /// Android: whether "All files access" (11+) / the storage permission (10 and older) is on.
  /// iOS has no such access: always true.
  static Future<bool> storageAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('storageAccess') ?? false;
    } catch (error) {
      debugPrint('storage access: $error');
      return false;
    }
  }

  /// Android 11+: opens the system "All files access" page for this app (returns at once);
  /// Android 10 and older: the system permission dialog (returns when it is answered).
  /// Returns whether access is on afterwards (always false for the settings page).
  static Future<bool> requestStorageAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestStorageAccess') ?? false;
    } catch (error) {
      debugPrint('request storage access: $error');
      return false;
    }
  }

  /// Android: every supported file on the phone (media index + folder walk, like the Android
  /// app's FileRepository). Needs storage access; [extensions] without the dot.
  static Future<List<DeviceFile>> scanDevice(List<String> extensions) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('scanDevice', {'extensions': extensions});
      if (raw == null) return const [];
      final items = <DeviceFile>[];
      for (final row in raw) {
        if (row is! Map) continue;
        final path = row['path']?.toString() ?? '';
        final size = row['size'];
        final modified = row['modified'];
        if (path.isEmpty || size is! num || modified is! num) continue;
        items.add((path: path, size: size.toInt(), modified: modified.toInt()));
      }
      return items;
    } catch (error) {
      debugPrint('device scan: $error');
      return const [];
    }
  }

  /// Android: tells the media index that these files changed (renamed / deleted / saved).
  static Future<void> scanPaths(List<String> paths) async {
    if (!Platform.isAndroid || paths.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('scanPaths', {'paths': paths});
    } catch (error) {
      debugPrint('scan paths: $error');
    }
  }

  /// Android: starts listening for media index changes ([mediaChanged]).
  static Future<void> startWatching() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startWatching');
    } catch (error) {
      debugPrint('watch media: $error');
    }
  }

  /// Android: the public Documents folder (/storage/emulated/0/Documents). Null on iOS.
  static Future<String?> publicDocumentsDir() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('publicDocumentsDir');
    } catch (error) {
      return null;
    }
  }

  /// Opens the file in another app: Android ACTION_VIEW chooser (FileProvider uri), iOS "Open
  /// in…" menu. False when no app can open it.
  static Future<bool> openExternal(String path, {String? mime}) async {
    try {
      return await _channel.invokeMethod<bool>('openExternal', {'path': path, 'mime': ?mime}) ?? false;
    } catch (error) {
      debugPrint('open external: $error');
      return false;
    }
  }

  /// "Save to Drive": Android hands the file to the Google Drive app's upload screen ('ok'),
  /// 'missing' when Drive is not installed, 'failed' otherwise. iOS opens the share sheet ('ok').
  static Future<String> saveToDrive(String path) async {
    try {
      return await _channel.invokeMethod<String>('saveToDrive', {'path': path}) ?? 'failed';
    } catch (error) {
      debugPrint('save to drive: $error');
      return 'failed';
    }
  }

  /// Opens the phone's own Files app. False if nothing could be opened.
  static Future<bool> openFileManager() async {
    try {
      return await _channel.invokeMethod<bool>('openFileManager') ?? false;
    } catch (error) {
      debugPrint('file manager: $error');
      return false;
    }
  }

  /// True on Xiaomi / Redmi / POCO phones (MIUI blocks shortcuts until a permission is on).
  static Future<bool> isXiaomi() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isXiaomi') ?? false;
    } catch (error) {
      return false;
    }
  }

  /// Opens this app's system "App info" page (MIUI: its permission editor when available).
  static Future<void> openAppDetails() async {
    try {
      await _channel.invokeMethod<void>('openAppDetails');
    } catch (error) {
      debugPrint('app details: $error');
    }
  }

  static Future<void> rememberIosDirectory(String path) async {
    try {
      await _channel.invokeMethod<void>('rememberIosDirectory', {'path': path});
    } catch (error) {
      debugPrint('ios directory: $error');
    }
  }

  static Future<List<String>> iosBookmarkedFiles() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('iosBookmarkedFiles');
      if (raw == null) return const [];
      return [for (final item in raw) item.toString()].where((path) => path.isNotEmpty).toList();
    } catch (error) {
      return const [];
    }
  }

  /// Builds a new PDF at [output] from real pages of other PDFs (Android: pdfbox, iOS: PDFKit).
  /// Each page is {'src': path, 'index': 0-based page, 'rotate': degrees}. Returns false on failure.
  static Future<bool> assemblePdf(String output, List<Map<String, Object>> pages) async {
    try {
      final done = await _channel.invokeMethod<String>('assemblePdf', {'output': output, 'pages': pages});
      return done != null;
    } catch (error) {
      debugPrint('assemblePdf: $error');
      return false;
    }
  }

  static Future<void> updateWidget(String line) async {
    try {
      await _channel.invokeMethod<void>('updateWidget', {'line': line});
    } catch (error) {
      debugPrint('widget update: $error');
    }
  }

  static Future<({int total, int free})?> storage() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('storageStats');
      if (raw == null) return null;
      final total = raw['total'];
      final free = raw['free'];
      if (total is! num || free is! num) return null;
      return (total: total.toInt(), free: free.toInt());
    } catch (error) {
      return null;
    }
  }
}

String localPath(String uriOrPath) {
  if (uriOrPath.startsWith('file://')) {
    return Uri.parse(uriOrPath).toFilePath(windows: Platform.isWindows);
  }
  return uriOrPath;
}
