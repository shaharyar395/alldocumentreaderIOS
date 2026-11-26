import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

  /// iOS StoreKit 2: a transaction from Transaction.updates (set by AppleBilling).
  static void Function(Object? event)? onIapTransaction;

  static void listen(void Function(IncomingFile file) onIncoming) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onIapTransaction':
          onIapTransaction?.call(call.arguments);
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
  /// True only for an App Store install. TestFlight, Xcode, and sideload are false.
  static Future<bool> installedFromAppStore() async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('installedFromAppStore') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Splash, Welcome back, and full-screen ads queue an in-app message instead of showing it.
  static Future<void> fiamBlocked(bool blocked) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('fiamBlocked', {'blocked': blocked});
    } catch (error) {
      debugPrint('in-app messages: $error');
    }
  }

  static Future<String?> appVersion() async {
    try {
      return await _channel.invokeMethod<String>('appVersion');
    } catch (error) {
      return null;
    }
  }

  /// Android: asks the launcher to pin a shortcut that opens [path] in the app. The icon is the
  /// file type's icon ([kind] is a DocKind name: pdf, word, excel, ppt, txt, image, other).
  /// iOS: adds the file to the app icon's Home Screen quick actions (at most 4, newest first).
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
  /// 'missing' when Drive is not installed, 'failed' otherwise. iOS opens the Files export picker
  /// (Google Drive is a location there): 'ok', 'cancelled' or 'failed'.
  static Future<String> saveToDrive(String path) async {
    try {
      return await _channel.invokeMethod<String>('saveToDrive', {'path': path}) ?? 'failed';
    } catch (error) {
      debugPrint('save to drive: $error');
      return 'failed';
    }
  }

  /// Opens the phone's own Files app (iOS: at this app's folder, or at [path] — a folder, or a
  /// file's folder). False if nothing could be opened.
  static Future<bool> openFileManager({String? path}) async {
    try {
      return await _channel.invokeMethod<bool>('openFileManager', {'path': ?path}) ?? false;
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

  /// iOS "Allow access": the Files folder picker. Returns the picked folder's path (the app keeps
  /// access to it from now on), or null when the user cancels.
  static Future<String?> pickIosFolder() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('pickIosFolder');
    } catch (error) {
      debugPrint('ios folder picker: $error');
      return null;
    }
  }

  /// iOS: supported files inside the folders the user allowed. A plain directory listing cannot
  /// see those security-scoped folders, so this is read by the system file manager.
  static Future<List<DeviceFile>> scanIosFolders(List<String> extensions) async {
    if (!Platform.isIOS) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('scanIosFolders', {'extensions': extensions});
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
      debugPrint('ios folder scan: $error');
      return const [];
    }
  }

  /// iOS: the folders the user picked (access opened for this run). Empty on Android.
  static Future<List<String>> iosFolders() async {
    if (!Platform.isIOS) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('iosFolders');
      if (raw == null) return const [];
      return [for (final item in raw) item.toString()].where((path) => path.isNotEmpty).toList();
    } catch (error) {
      debugPrint('ios folders: $error');
      return const [];
    }
  }

  /// iOS: forgets a picked folder (its files are no longer listed).
  static Future<void> removeIosFolder(String path) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('removeIosFolder', {'path': path});
    } catch (error) {
      debugPrint('ios folder remove: $error');
    }
  }

  /// iOS PDFKit: how many pages [path] has. Throws when the PDF is locked.
  static Future<int> pdfPageCount(String path) async {
    final count = await _channel.invokeMethod<int>('pdfPageCount', {'path': path});
    return count ?? 0;
  }

  /// iOS PDFKit: one page drawn as a JPEG, plus its size in points. Null when it cannot be drawn.
  static Future<({Uint8List jpeg, double width, double height})?> renderPdfPage(String path, int index) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('renderPdfPage', {'path': path, 'index': index});
    if (raw == null) return null;
    final jpeg = raw['jpeg'];
    final width = raw['width'];
    final height = raw['height'];
    if (jpeg is! Uint8List || width is! num || height is! num || jpeg.isEmpty) return null;
    return (jpeg: jpeg, width: width.toDouble(), height: height.toDouble());
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

  /// iOS StoreKit 2: the product ids of the subscriptions active right now, or null when the
  /// store could not be asked.
  static Future<List<String>?> activeSubscriptions() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('activeSubscriptions');
      if (raw == null) return null;
      return [for (final id in raw) id.toString()];
    } catch (error) {
      debugPrint('active subscriptions: $error');
      return null;
    }
  }

  /// iOS StoreKit 2: whether this Apple ID can still get the product's free trial (null: unknown).
  static Future<bool?> introEligible(String productId) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<bool>('introEligible', {'id': productId});
    } catch (error) {
      debugPrint('intro eligible: $error');
      return null;
    }
  }

  /// iOS: the App Store's "Manage subscriptions" sheet. False when it could not be shown.
  static Future<bool> manageSubscriptions() async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('manageSubscriptions') ?? false;
    } catch (error) {
      debugPrint('manage subscriptions: $error');
      return false;
    }
  }

  /// iOS: Apple's rating prompt (the system decides whether and how often it shows).
  static Future<void> requestReview() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('requestReview');
    } catch (error) {
      debugPrint('request review: $error');
    }
  }

  /// iOS iCloud Drive: makes sure the file is on the phone (downloads a file that is only in
  /// iCloud, waiting up to 2 minutes). Always true on Android when the file exists. False when
  /// the file is gone or could not be downloaded.
  static Future<bool> ensureLocal(String path) async {
    if (!Platform.isIOS) return File(path).existsSync();
    try {
      return await _channel.invokeMethod<bool>('ensureLocal', {'path': path}) ?? File(path).existsSync();
    } catch (error) {
      debugPrint('ensure local: $error');
      return File(path).existsSync();
    }
  }

  /// iOS: shows the file in QuickLook inside the app. False when QuickLook can't show it.
  static Future<bool> quickLook(String path) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('quickLook', {'path': path}) ?? false;
    } catch (error) {
      debugPrint('quick look: $error');
      return false;
    }
  }

  /// iOS: Mail's compose sheet. Returns 'sent', 'saved', 'cancelled', 'failed', or
  /// 'unavailable' (no mail account on the phone, or not iOS).
  static Future<String> composeMail({
    required List<String> to,
    required String subject,
    required String body,
    List<String> attachments = const [],
  }) async {
    if (!Platform.isIOS) return 'unavailable';
    try {
      return await _channel.invokeMethod<String>('composeMail', {
            'to': to,
            'subject': subject,
            'body': body,
            'attachments': attachments,
          }) ??
          'unavailable';
    } catch (error) {
      debugPrint('compose mail: $error');
      return 'unavailable';
    }
  }

  static ({String name, String device, String documents})? _iosInfo;

  /// [iosAppInfo] once it has been loaded (null before, and on Android).
  static ({String name, String device, String documents})? get iosAppInfoCached => _iosInfo;

  /// iOS: the app's display name, "iPhone" / "iPad" and the Documents folder (cached).
  static Future<({String name, String device, String documents})?> iosAppInfo() async {
    if (!Platform.isIOS) return null;
    final cached = _iosInfo;
    if (cached != null) return cached;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('iosAppInfo');
      if (raw == null) return null;
      final info = (
        name: raw['name']?.toString() ?? '',
        device: raw['device']?.toString() ?? 'iPhone',
        documents: raw['documents']?.toString() ?? '',
      );
      _iosInfo = info;
      return info;
    } catch (error) {
      debugPrint('ios app info: $error');
      return null;
    }
  }

  static Map<String, String>? _widgetLabels;

  /// iOS: the home-screen widgets' texts in the app's language (written to the App Group).
  static Future<void> updateWidgetLabels(Map<String, String> labels) async {
    if (!Platform.isIOS || mapEquals(_widgetLabels, labels)) return;
    _widgetLabels = labels;
    try {
      await _channel.invokeMethod<void>('widgetLabels', {'labels': labels});
    } catch (error) {
      debugPrint('widget labels: $error');
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

/// Where the share sheet's popover points on iPad (share_plus needs it there): the widget of
/// [context] when it is a small on-screen widget (the tapped button / row), otherwise a point in
/// the middle of the screen.
Rect shareOrigin(BuildContext? context) {
  Rect? centre;
  if (context != null && context.mounted) {
    final size = MediaQuery.maybeSizeOf(context);
    if (size != null) centre = Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final small = size == null || rect.width * rect.height < size.width * size.height * 0.4;
      if (small && rect.width > 0 && rect.height > 0) return rect;
    }
  }
  if (centre != null) return centre;
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  final logical = view == null ? const Size(400, 800) : view.physicalSize / view.devicePixelRatio;
  return Rect.fromCenter(center: logical.center(Offset.zero), width: 1, height: 1);
}
