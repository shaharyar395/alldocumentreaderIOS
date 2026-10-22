import Flutter
import PDFKit
import UIKit
import UniformTypeIdentifiers
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(
      name: "com.theoccess.alldocreader/platform",
      binaryMessenger: messenger
    )
    PlatformBridge.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takePendingUri", "takePendingIncoming":
        // iOS files come in through "Open in" / Files (no home-screen shortcuts): a local path
        result(PlatformBridge.pending)
        PlatformBridge.pending = nil
      case "takePendingAction":
        result(PlatformBridge.pendingAction)
        PlatformBridge.pendingAction = nil
      case "appVersion":
        result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
      case "deviceInfo":
        // for the Feedback e-mail: "iOS 17.5 · iPhone15,2" (like Android's version + model line)
        var info = utsname()
        uname(&info)
        let model = withUnsafePointer(to: &info.machine) {
          $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        result("iOS \(UIDevice.current.systemVersion) · \(model)")
      case "pinShortcut", "pinWidget":
        // not possible on iOS (the Dart side hides "To home screen" and explains the widget)
        result(false)
      case "copyUri":
        guard let args = call.arguments as? [String: Any],
              let uri = args["uri"] as? String,
              let dest = args["dest"] as? String else {
          result(FlutterError(code: "bad_args", message: "uri and dest required", details: nil))
          return
        }
        do {
          try PlatformBridge.copy(uri: uri, dest: dest)
          result(dest)
        } catch {
          result(FlutterError(code: "copy_failed", message: error.localizedDescription, details: nil))
        }
      case "displayName":
        let uri = (call.arguments as? [String: Any])?["uri"] as? String
        let name = uri.flatMap { URL(string: $0)?.lastPathComponent }
        result(name?.isEmpty == false ? name : "document")
      case "storageStats":
        result(PlatformBridge.storage())
      case "storageAccess", "requestStorageAccess":
        // iOS has no "all files" access: documents come in through Files / "Open in"
        result(true)
      case "publicDocumentsDir", "scanPaths", "startWatching":
        result(nil)
      case "scanDevice":
        result([])
      case "resolveIncoming":
        let uri = (call.arguments as? [String: Any])?["uri"] as? String ?? ""
        result(PlatformBridge.resolve(uri: uri))
      case "openExternal":
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        result(PlatformBridge.openExternal(path: path))
      case "saveToDrive":
        // no Drive hand-off on iOS: the share sheet (Google Drive is one of its targets)
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        result(PlatformBridge.share(path: path) ? "ok" : "failed")
      case "openFileManager":
        PlatformBridge.openFilesApp { opened in result(opened) }
      case "isXiaomi":
        result(false)
      case "openAppDetails":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      case "rememberIosDirectory":
        let path = (call.arguments as? [String: Any])?["path"] as? String
        if let path {
          PlatformBridge.rememberDirectory(path)
        }
        result(nil)
      case "iosBookmarkedFiles":
        result(PlatformBridge.bookmarkedFiles())
      case "updateWidget":
        let line = (call.arguments as? [String: Any])?["line"] as? String ?? "0"
        UserDefaults(suiteName: "group.com.ol.documents.reader.docera.offline")?.set(line, forKey: "widget_line")
        if #available(iOS 14.0, *) {
          WidgetCenter.shared.reloadAllTimelines()
        }
        result(nil)
      case "assemblePdf":
        // Merge / Split / Extract / Manage pages: copies the real PDF pages (text stays text)
        guard let args = call.arguments as? [String: Any],
              let output = args["output"] as? String,
              let pages = args["pages"] as? [[String: Any]] else {
          result(FlutterError(code: "bad_args", message: "output and pages required", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let ok = PlatformBridge.assemblePdf(output: output, pages: pages)
          DispatchQueue.main.async {
            if ok {
              result(output)
            } else {
              result(FlutterError(code: "pdf_failed", message: "could not build the PDF", details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

enum PlatformBridge {
  static var channel: FlutterMethodChannel?

  /// Builds a new PDF at `output` from `pages` ({"src": path, "index": 0-based, "rotate": degrees}).
  /// Pages are copied with PDFKit, so text, fonts and pictures stay as they are.
  static func assemblePdf(output: String, pages: [[String: Any]]) -> Bool {
    var sources: [String: PDFDocument] = [:]
    let target = PDFDocument()
    for entry in pages {
      guard let src = entry["src"] as? String else { continue }
      var document = sources[src]
      if document == nil {
        document = PDFDocument(url: URL(fileURLWithPath: src))
        sources[src] = document
      }
      guard let source = document, !source.isLocked else { return false }
      let index = (entry["index"] as? NSNumber)?.intValue ?? 0
      guard index >= 0, index < source.pageCount,
            let page = source.page(at: index)?.copy() as? PDFPage else { continue }
      let rotate = (entry["rotate"] as? NSNumber)?.intValue ?? 0
      if rotate % 360 != 0 {
        page.rotation = ((page.rotation + rotate) % 360 + 360) % 360
      }
      target.insert(page, at: target.pageCount)
    }
    if target.pageCount == 0 { return false }
    let temp = URL(fileURLWithPath: output + ".part")
    try? FileManager.default.removeItem(at: temp)
    guard target.write(to: temp) else { return false }
    sources.removeAll()
    let destination = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: destination)
    do {
      try FileManager.default.moveItem(at: temp, to: destination)
    } catch {
      return false
    }
    return true
  }
  static var pending: String?

  /// Widget link (alldocreader://widget/<action>) that started the app, until Dart asks for it.
  static var pendingAction: String?

  /// alldocreader://widget/search, …/recent, …/bookmarks, …/edit, …/home (home-screen widget).
  static func acceptLink(url: URL, deliverNow: Bool) {
    let action = url.pathComponents.last(where: { $0 != "/" }) ?? url.host ?? "home"
    if deliverNow, let channel {
      channel.invokeMethod("onWidgetAction", arguments: action)
    } else {
      pendingAction = action
    }
  }

  /// A file from "Open in" / Files. A file that is already in the app's Documents folder is
  /// opened where it is; anything else is copied into Documents/library/import: a copy with the
  /// same name and size is reused, otherwise the name becomes "name (n).ext"; a name without an
  /// extension gets one from the file's type.
  static func accept(url: URL, deliverNow: Bool) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let fm = FileManager.default
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let docsPath = docs.resolvingSymlinksInPath().path
    let sourcePath = url.resolvingSymlinksInPath().path
    var delivered: String?
    if url.isFileURL, sourcePath.hasPrefix(docsPath + "/"), !sourcePath.contains("/Inbox/") {
      delivered = url.path
    } else {
      let dir = docs.appendingPathComponent("library/import", isDirectory: true)
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
      var name = url.lastPathComponent.isEmpty ? "document" : url.lastPathComponent
      if (name as NSString).pathExtension.isEmpty,
         let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
         let ext = type.preferredFilenameExtension {
        name += ".\(ext)"
      }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
      let existing = dir.appendingPathComponent(name)
      let existingSize = (try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
      if fm.fileExists(atPath: existing.path), size > 0, existingSize == size {
        delivered = existing.path
      } else {
        let dest = uniqueURL(in: dir, name: name)
        do {
          try fm.copyItem(at: url, to: dest)
          delivered = dest.path
        } catch {
          NSLog("Open-in copy failed: \(error.localizedDescription)")
        }
      }
      // a copy the system left in Documents/Inbox is not needed any more
      if sourcePath.contains("/Inbox/"), delivered != nil {
        try? fm.removeItem(at: url)
      }
    }
    guard let path = delivered else { return }
    if deliverNow, let channel {
      channel.invokeMethod("onIncomingUri", arguments: path)
    } else {
      pending = path
    }
  }

  /// "name.ext", or "name (1).ext", "name (2).ext"… when taken.
  static func uniqueURL(in dir: URL, name: String) -> URL {
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent(name)
    if !fm.fileExists(atPath: candidate.path) { return candidate }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var index = 1
    repeat {
      let next = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
      candidate = dir.appendingPathComponent(next)
      index += 1
    } while fm.fileExists(atPath: candidate.path)
    return candidate
  }

  /// Name, type and size of a local file (incoming files are always local paths on iOS).
  static func resolve(uri: String) -> [String: Any] {
    let url = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : (URL(string: uri) ?? URL(fileURLWithPath: uri))
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    let readable = url.isFileURL && FileManager.default.isReadableFile(atPath: url.path)
    return [
      "path": readable ? url.path : "",
      "name": url.lastPathComponent,
      "mime": values?.contentType?.preferredMIMEType ?? "",
      "size": values?.fileSize ?? -1,
    ]
  }

  /// The screen on top, to present system sheets from.
  static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  /// Kept alive while its "Open in" menu is on screen.
  static var interaction: UIDocumentInteractionController?

  /// "Open in…" another app; false when no app can open the file.
  static func openExternal(path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path), let top = topController() else { return false }
    let controller = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
    interaction = controller
    let bounds = top.view.bounds
    let anchor = CGRect(x: bounds.midX, y: bounds.maxY - 80, width: 1, height: 1)
    return controller.presentOpenInMenu(from: anchor, in: top.view, animated: true)
  }

  /// The system share sheet for one file.
  static func share(path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path), let top = topController() else { return false }
    let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
    }
    top.present(sheet, animated: true)
    return true
  }

  /// The Files app at this app's folder.
  static func openFilesApp(done: @escaping (Bool) -> Void) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    guard let url = URL(string: "shareddocuments://" + docs.path) else {
      done(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in done(opened) }
  }

  static func copy(uri: String, dest: String) throws {
    let source: URL
    if uri.hasPrefix("/") {
      source = URL(fileURLWithPath: uri)
    } else if let parsed = URL(string: uri), parsed.isFileURL {
      source = parsed
    } else {
      source = URL(fileURLWithPath: uri)
    }
    let destUrl = URL(fileURLWithPath: dest)
    try FileManager.default.createDirectory(
      at: destUrl.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: dest) {
      try FileManager.default.removeItem(at: destUrl)
    }
    try FileManager.default.copyItem(at: source, to: destUrl)
  }

  static func rememberDirectory(_ path: String) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
      return
    }
    UserDefaults.standard.set(data, forKey: "ios_scan_bookmark")
  }

  static func bookmarkedFiles() -> [String] {
    guard let data = UserDefaults.standard.data(forKey: "ios_scan_bookmark") else { return [] }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ) else { return [] }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    // the same types as the app lists (lib/data/doc_entry.dart docExtensions)
    let allowed: Set<String> = [
      "pdf", "doc", "docx", "docm", "dot", "dotx", "rtf", "odt",
      "xls", "xlsx", "xlsm", "xlt", "xltx", "csv", "ods", "tsv",
      "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "odp",
      "txt", "log", "md", "json", "xml",
      "jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif",
    ]
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alldoc-scan", isDirectory: true)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    var found: [String] = []
    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    while let item = enumerator.nextObject() as? URL {
      if found.count >= 2500 { break }
      let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile != true { continue }
      let ext = item.pathExtension.lowercased()
      if !allowed.contains(ext) { continue }
      let size = Int64(values?.fileSize ?? 0)
      if size <= 0 || size > 100 * 1024 * 1024 { continue }
      let dest = temp.appendingPathComponent(item.lastPathComponent)
      if FileManager.default.fileExists(atPath: dest.path) {
        try? FileManager.default.removeItem(at: dest)
      }
      do {
        try FileManager.default.copyItem(at: item, to: dest)
        found.append(dest.path)
      } catch {
        continue
      }
    }
    return found
  }

  static func storage() -> [String: Int64] {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [
      .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ])
    return [
      "total": Int64(values?.volumeTotalCapacity ?? 0),
      "free": values?.volumeAvailableCapacityForImportantUsage ?? 0,
    ]
  }
}
