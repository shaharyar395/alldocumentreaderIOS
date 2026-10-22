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
}
