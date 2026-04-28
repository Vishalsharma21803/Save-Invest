import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var safariChannel: FlutterMethodChannel?
  private var safariCoordinator: SaveUpSafariSheetCoordinator?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    guard let flutterViewController = window?.rootViewController as? FlutterViewController else {
      return
    }

    safariCoordinator = SaveUpSafariSheetCoordinator(sceneDelegate: self)
    safariChannel = FlutterMethodChannel(
      name: "com.saveup.app/safari_sheet",
      binaryMessenger: flutterViewController.binaryMessenger
    )

    safariChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }

      switch call.method {
      case "enableUndimmedBackground":
        result(self.safariCoordinator?.makeTopSheetUndimmed() ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func topMostViewController() -> UIViewController? {
    guard let root = window?.rootViewController else {
      return nil
    }

    var topViewController = root
    while let presented = topViewController.presentedViewController {
      topViewController = presented
    }

    print("[SaveUp] topVC class: \(type(of: topViewController))")
    return topViewController
  }
}
