import Flutter
import MessageUI
import PDFKit
import QuickLook
import StoreKit
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
        // "Open in" / Files: a local path; a Home Screen quick action: {"uri": path, "shortcut": true}
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
      case "pinWidget":
        // not possible on iOS (the Dart side explains how to add the widget)
        result(false)
      case "pinShortcut", "addQuickAction":
        // iOS "To home screen": the file becomes a Home Screen quick action (long-press the app icon)
        let args = call.arguments as? [String: Any]
        let path = args?["path"] as? String ?? ""
        let name = args?["name"] as? String ?? ""
        let kind = args?["kind"] as? String ?? "other"
        result(PlatformBridge.addQuickAction(path: path, name: name, kind: kind))
      case "activeSubscriptions":
        // StoreKit 2: the product ids of the subscriptions that are active right now
        Task { @MainActor in
          var ids: [String] = []
          for await entry in Transaction.currentEntitlements {
            if case .verified(let transaction) = entry, transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantFuture) > Date() {
              ids.append(transaction.productID)
            }
          }
          result(ids)
        }
      case "introEligible":
        // StoreKit 2: whether this Apple ID can still get the product's introductory offer (free trial)
        let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
        Task { @MainActor in
          var eligible = false
          if let products = try? await Product.products(for: [id]),
             let subscription = products.first?.subscription,
             subscription.introductoryOffer != nil {
            eligible = await subscription.isEligibleForIntroOffer
          }
          result(eligible)
        }
      case "manageSubscriptions":
        // the App Store's own "Manage subscriptions" sheet
        Task { @MainActor in
          guard let scene = PlatformBridge.activeScene() else {
            result(false)
            return
          }
          do {
            try await AppStore.showManageSubscriptions(in: scene)
            result(true)
          } catch {
            result(false)
          }
        }
      case "requestReview":
        // Apple's rating prompt (the system decides whether it is shown)
        if let scene = PlatformBridge.activeScene() {
          if #available(iOS 16.0, *) {
            AppStore.requestReview(in: scene)
          } else {
            SKStoreReviewController.requestReview(in: scene)
          }
        }
        result(nil)
      case "ensureLocal":
        // iCloud Drive: downloads a file that is only in iCloud (waits up to 2 minutes)
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        PlatformBridge.ensureLocal(path: path) { ok in result(ok) }
      case "quickLook":
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        result(PlatformBridge.quickLook(path: path))
      case "composeMail":
        let args = call.arguments as? [String: Any]
        PlatformBridge.composeMail(
          to: args?["to"] as? [String] ?? [],
          subject: args?["subject"] as? String ?? "",
          body: args?["body"] as? String ?? "",
          attachments: args?["attachments"] as? [String] ?? []
        ) { outcome in result(outcome) }
      case "iosAppInfo":
        // for the file info sheet: "On My iPhone › <name> › …"
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? ""
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        result([
          "name": name,
          "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
          "documents": docs.path,
        ])
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
        // "Save to Drive": the Files export picker (Google Drive is a location there once its
        // app is installed): "ok", "cancelled" or "failed"
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        PlatformBridge.exportFile(path: path) { outcome in result(outcome) }
      case "openFileManager":
        // the Files app at this app's folder, or at `path` (a folder) when given
        let path = (call.arguments as? [String: Any])?["path"] as? String
        PlatformBridge.openFilesApp(path: path) { opened in result(opened) }
      case "isXiaomi":
        result(false)
      case "openAppDetails":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      case "pickIosFolder":
        // iOS "Allow access": the user picks a folder in Files (On My iPhone, Downloads, iCloud…)
        PlatformBridge.pickFolder { path in result(path) }
      case "iosFolders":
        result(PlatformBridge.folders())
      case "removeIosFolder":
        let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
        PlatformBridge.removeFolder(path)
        result(nil)
      case "updateWidget":
        let line = (call.arguments as? [String: Any])?["line"] as? String ?? "0"
        UserDefaults(suiteName: PlatformBridge.appGroup)?.set(line, forKey: "widget_line")
        WidgetCenter.shared.reloadAllTimelines()
        result(nil)
      case "widgetLabels":
        // the widgets' texts in the app's language (the widget extension has no translations)
        let labels = (call.arguments as? [String: Any])?["labels"] as? [String: String] ?? [:]
        let defaults = UserDefaults(suiteName: PlatformBridge.appGroup)
        if defaults?.dictionary(forKey: "widget_labels") as? [String: String] != labels {
          defaults?.set(labels, forKey: "widget_labels")
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

  /// App Group shared with the ReaderWidget extension (Runner and ReaderWidget entitlements).
  static let appGroup = "group.com.ol.documents.reader.docera.offline"

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
  /// The file that started the app, until Dart asks for it: a path ("Open in") or
  /// {"uri": path, "shortcut": true} (Home Screen quick action).
  static var pending: Any?

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

  /// The Files app at this app's folder, or at `path` (a folder; a file's own folder).
  static func openFilesApp(path: String?, done: @escaping (Bool) -> Void) {
    let fm = FileManager.default
    var target = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    if let path, !path.isEmpty {
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: path, isDirectory: &isDir) {
        target = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
      }
    }
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
    guard let url = URL(string: "shareddocuments://" + encoded) else {
      done(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in done(opened) }
  }

  /// The scene on screen, for StoreKit's sheets and the rating prompt.
  static func activeScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  }

  // ------------------------------------------------------------------ iCloud Drive

  /// True once the file is on the phone: files that are not in iCloud right away; an iCloud
  /// file that is not downloaded (or out of date) is downloaded first. False when it is gone
  /// or the download did not finish within [timeout] seconds.
  static func ensureLocal(path: String, timeout: TimeInterval = 120, done: @escaping (Bool) -> Void) {
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    func status() -> (ubiquitous: Bool, current: Bool) {
      var fresh = url
      fresh.removeAllCachedResourceValues()
      let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
      let ubiquitous = values?.isUbiquitousItem ?? false
      return (ubiquitous, values?.ubiquitousItemDownloadingStatus == .current)
    }
    let first = status()
    let placeholder = url.deletingLastPathComponent()
      .appendingPathComponent("." + url.lastPathComponent + ".icloud").path
    if !first.ubiquitous, !fm.fileExists(atPath: placeholder) {
      // a plain local file
      done(fm.fileExists(atPath: path))
      return
    }
    if first.current, fm.fileExists(atPath: path) {
      done(true)
      return
    }
    do {
      try fm.startDownloadingUbiquitousItem(at: url)
    } catch {
      NSLog("iCloud download failed: \(error.localizedDescription)")
      done(false)
      return
    }
    let deadline = Date().addingTimeInterval(timeout)
    func poll() {
      let now = status()
      if now.current, fm.fileExists(atPath: path) {
        done(true)
      } else if Date() > deadline {
        done(false)
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { poll() }
      }
    }
    poll()
  }

  // ------------------------------------------------------------------ QuickLook

  /// Kept alive while its preview is on screen.
  static var preview: PreviewSource?

  /// Shows the file in QuickLook (old Word / Excel / PowerPoint, RTF, OpenDocument, iWork …);
  /// false when QuickLook cannot show it.
  static func quickLook(path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path),
          QLPreviewController.canPreview(url as NSURL),
          let top = topController() else { return false }
    let source = PreviewSource(url: url)
    preview = source
    let controller = QLPreviewController()
    controller.dataSource = source
    controller.delegate = source
    top.present(controller, animated: true)
    return true
  }

  // ------------------------------------------------------------------ Save to Drive (Files export)

  private static var exportDelegate: ExportPickerDelegate?

  /// The Files "Export" picker for a copy of the file: "ok", "cancelled" or "failed".
  static func exportFile(path: String, done: @escaping (String) -> Void) {
    guard FileManager.default.fileExists(atPath: path), let top = topController() else {
      done("failed")
      return
    }
    let picker = UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: path)], asCopy: true)
    let delegate = ExportPickerDelegate { outcome in
      PlatformBridge.exportDelegate = nil
      done(outcome)
    }
    exportDelegate = delegate
    picker.delegate = delegate
    top.present(picker, animated: true)
  }

  // ------------------------------------------------------------------ Feedback e-mail

  private static var mailDelegate: MailDelegate?

  /// Mail's compose sheet with the recipients, subject, body and attached files: "sent", "saved",
  /// "cancelled", "failed", or "unavailable" when no mail account is set up.
  static func composeMail(to: [String], subject: String, body: String, attachments: [String], done: @escaping (String) -> Void) {
    guard MFMailComposeViewController.canSendMail(), let top = topController() else {
      done("unavailable")
      return
    }
    let mail = MFMailComposeViewController()
    mail.setToRecipients(to)
    mail.setSubject(subject)
    mail.setMessageBody(body, isHTML: false)
    for path in attachments {
      let url = URL(fileURLWithPath: path)
      guard let data = try? Data(contentsOf: url) else { continue }
      let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      mail.addAttachmentData(data, mimeType: mime, fileName: url.lastPathComponent)
    }
    let delegate = MailDelegate { outcome in
      PlatformBridge.mailDelegate = nil
      done(outcome)
    }
    mailDelegate = delegate
    mail.mailComposeDelegate = delegate
    top.present(mail, animated: true)
  }

  // ------------------------------------------------------------------ Home Screen quick actions

  private static let quickActionType = "open_file"

  /// Adds the file as the first Home Screen quick action (at most 4, newest first; the same file
  /// again moves to the top). Files in Documents are kept relative to it (the container path
  /// changes on updates); files in picked folders keep their absolute path.
  static func addQuickAction(path: String, name: String, kind: String) -> Bool {
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
    let stored = shortcutPath(for: path)
    let title = name.isEmpty ? (path as NSString).lastPathComponent : name
    let symbol: String
    switch kind {
    case "pdf": symbol = "doc.richtext"
    case "word", "txt": symbol = "doc.text"
    case "excel": symbol = "tablecells"
    case "ppt": symbol = "rectangle.on.rectangle"
    case "image": symbol = "photo"
    default: symbol = "doc"
    }
    let item = UIApplicationShortcutItem(
      type: quickActionType,
      localizedTitle: title,
      localizedSubtitle: nil,
      icon: UIApplicationShortcutIcon(systemImageName: symbol),
      userInfo: ["path": stored as NSString]
    )
    var items = (UIApplication.shared.shortcutItems ?? []).filter {
      !($0.type == quickActionType && ($0.userInfo?["path"] as? String) == stored)
    }
    items.insert(item, at: 0)
    UIApplication.shared.shortcutItems = Array(items.prefix(4))
    return true
  }

  private static func shortcutPath(for path: String) -> String {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let docsPath = docs.standardizedFileURL.resolvingSymlinksInPath().path
    let filePath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    if filePath.hasPrefix(docsPath + "/") {
      return String(filePath.dropFirst(docsPath.count + 1))
    }
    return path
  }

  /// A quick action was chosen: the file is delivered like a shortcut (reader at once, no
  /// splash / ad). A file that is gone loses its quick action (Dart shows "not found").
  @discardableResult
  static func acceptShortcut(_ item: UIApplicationShortcutItem, deliverNow: Bool) -> Bool {
    guard item.type == quickActionType, let stored = item.userInfo?["path"] as? String, !stored.isEmpty else {
      return false
    }
    let path: String
    if stored.hasPrefix("/") {
      // a file in a picked folder: open access to the picked folders first
      _ = folders()
      path = stored
    } else {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      path = docs.appendingPathComponent(stored).path
    }
    if !FileManager.default.fileExists(atPath: path) {
      UIApplication.shared.shortcutItems = (UIApplication.shared.shortcutItems ?? []).filter {
        !($0.type == quickActionType && ($0.userInfo?["path"] as? String) == stored)
      }
    }
    let payload: [String: Any] = ["uri": path, "shortcut": true]
    if deliverNow, let channel {
      channel.invokeMethod("onIncomingUri", arguments: payload)
    } else {
      pending = payload
    }
    return true
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

  // ------------------------------------------------------------------ picked folders (iOS "Allow access")

  /// Folders picked by the user, as bookmarks (kept across launches). While the app runs, access to
  /// each one stays open, so Flutter can list, open, rename and delete the real files in place.
  private static let foldersKey = "ios_folder_bookmarks"
  private static var openFolders: [String: URL] = [:]
  private static var folderPicker: FolderPickerDelegate?

  static func pickFolder(_ done: @escaping (String?) -> Void) {
    guard let top = topController() else {
      done(nil)
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
    picker.allowsMultipleSelection = false
    let delegate = FolderPickerDelegate { url in
      PlatformBridge.folderPicker = nil
      guard let url else {
        done(nil)
        return
      }
      let accessing = url.startAccessingSecurityScopedResource()
      guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
        if accessing { url.stopAccessingSecurityScopedResource() }
        done(nil)
        return
      }
      var saved = (UserDefaults.standard.array(forKey: PlatformBridge.foldersKey) as? [Data]) ?? []
      // the same folder picked again replaces its old bookmark
      saved.removeAll { PlatformBridge.resolve($0)?.standardizedFileURL.path == url.standardizedFileURL.path }
      saved.append(data)
      UserDefaults.standard.set(saved, forKey: PlatformBridge.foldersKey)
      if accessing { PlatformBridge.openFolders[url.standardizedFileURL.path] = url }
      done(url.standardizedFileURL.path)
    }
    folderPicker = delegate
    picker.delegate = delegate
    top.present(picker, animated: true)
  }

  /// The picked folders that still exist, with access opened (paths for Flutter).
  static func folders() -> [String] {
    var saved = (UserDefaults.standard.array(forKey: foldersKey) as? [Data]) ?? []
    var paths: [String] = []
    var changed = false
    for (i, data) in saved.enumerated().reversed() {
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
        continue
      }
      let path = url.standardizedFileURL.path
      if openFolders[path] == nil {
        if url.startAccessingSecurityScopedResource() {
          openFolders[path] = url
        } else {
          continue
        }
      }
      if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
        saved[i] = fresh
        changed = true
      }
      paths.insert(path, at: 0)
    }
    if changed { UserDefaults.standard.set(saved, forKey: foldersKey) }
    return paths
  }

  static func removeFolder(_ path: String) {
    var saved = (UserDefaults.standard.array(forKey: foldersKey) as? [Data]) ?? []
    saved.removeAll { PlatformBridge.resolve($0)?.standardizedFileURL.path == path }
    UserDefaults.standard.set(saved, forKey: foldersKey)
    if let url = openFolders.removeValue(forKey: path) {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private static func resolve(_ data: Data) -> URL? {
    var stale = false
    return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
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

/// Delegate of the "pick a folder" document picker (kept alive by PlatformBridge while it is open).
final class FolderPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private let done: (URL?) -> Void

  init(done: @escaping (URL?) -> Void) {
    self.done = done
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    done(urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    done(nil)
  }
}

/// Data source of the QuickLook preview: one file.
final class PreviewSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  private let url: URL

  init(url: URL) {
    self.url = url
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    url as NSURL
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    if PlatformBridge.preview === self { PlatformBridge.preview = nil }
  }
}

/// Delegate of the "Save to Drive" export picker (kept alive by PlatformBridge while it is open).
final class ExportPickerDelegate: NSObject, UIDocumentPickerDelegate {
  private let done: (String) -> Void

  init(done: @escaping (String) -> Void) {
    self.done = done
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    done(urls.isEmpty ? "failed" : "ok")
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    done("cancelled")
  }
}

/// Delegate of the feedback e-mail sheet: closes it and reports how it ended.
final class MailDelegate: NSObject, MFMailComposeViewControllerDelegate {
  private let done: (String) -> Void

  init(done: @escaping (String) -> Void) {
    self.done = done
  }

  func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
    let outcome: String
    switch result {
    case .sent: outcome = "sent"
    case .saved: outcome = "saved"
    case .cancelled: outcome = "cancelled"
    default: outcome = "failed"
    }
    controller.dismiss(animated: true) { self.done(outcome) }
  }
}
