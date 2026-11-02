import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      if context.url.scheme == "alldocreader" {
        PlatformBridge.acceptLink(url: context.url, deliverNow: false)
      } else {
        PlatformBridge.accept(url: context.url, deliverNow: false)
      }
    }
    // started from a Home Screen quick action (a file added with "Add to app icon menu")
    if let item = connectionOptions.shortcutItem {
      _ = PlatformBridge.acceptShortcut(item, deliverNow: false)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      if context.url.scheme == "alldocreader" {
        PlatformBridge.acceptLink(url: context.url, deliverNow: true)
      } else {
        PlatformBridge.accept(url: context.url, deliverNow: true)
      }
    }
  }

  /// A Home Screen quick action while the app is running (or in the background). Not passed on
  /// to FlutterSceneDelegate: no plugin of this app handles quick actions.
  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(PlatformBridge.acceptShortcut(shortcutItem, deliverNow: true))
  }
}
