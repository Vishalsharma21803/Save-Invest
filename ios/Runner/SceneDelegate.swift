import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private static let safariChannelName = "com.saveup.app/safari_sheet"
  private static let logTag = "[SaveUp][iOS][Native][Session]"

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
      name: Self.safariChannelName,
      binaryMessenger: flutterViewController.binaryMessenger
    )

    safariChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "IOS_S0",
            message: "SceneDelegate unavailable",
            details: nil
          )
        )
        return
      }

      self.handleSafariMethod(call: call, result: result)
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
    return topViewController
  }

  func presentationDepth() -> Int {
    guard let root = window?.rootViewController else {
      return 0
    }
    var depth = 0
    var current: UIViewController? = root
    while let presented = current?.presentedViewController {
      depth += 1
      current = presented
    }
    return depth
  }

  private func handleSafariMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let safariCoordinator else {
      result(
        FlutterError(
          code: "IOS_S1",
          message: "Safari coordinator unavailable",
          details: nil
        )
      )
      return
    }

    switch call.method {
    case "startSafariSession":
      guard
        let args = call.arguments as? [String: Any],
        let url = args["url"] as? String,
        let sessionId = args["sessionId"] as? String
      else {
        result([
          "started": false,
          "code": "IOS_S2",
          "error": "Missing startSafariSession arguments"
        ])
        return
      }

      result(safariCoordinator.startSafariSession(urlString: url, sessionId: sessionId))
    case "closeSafariSession":
      guard
        let args = call.arguments as? [String: Any],
        let sessionId = args["sessionId"] as? String
      else {
        result([
          "closed": false,
          "code": "IOS_S3",
          "error": "Missing closeSafariSession sessionId"
        ])
        return
      }
      let trigger = (args["trigger"] as? String) ?? "unknown"
      result(safariCoordinator.closeSafariSession(sessionId: sessionId, trigger: trigger))
    case "patchSheetIfPresented":
      guard
        let args = call.arguments as? [String: Any],
        let sessionId = args["sessionId"] as? String
      else {
        result([
          "patched": false,
          "code": "IOS_S4",
          "error": "Missing patchSheetIfPresented sessionId"
        ])
        return
      }
      let attempt = (args["attempt"] as? Int) ?? 0
      result(safariCoordinator.patchSheetIfPresented(sessionId: sessionId, attempt: attempt))
    case "enableUndimmedBackground":
      // Backward-compatible alias for older Dart callers.
      let activeSessionId = safariCoordinator.activeSessionId ?? "legacy"
      let patch = safariCoordinator.patchSheetIfPresented(
        sessionId: activeSessionId,
        attempt: -1
      )
      result(patch["patched"] as? Bool ?? false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func emitToFlutter(method: String, arguments: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.safariChannel?.invokeMethod(method, arguments: arguments)
    }
  }

  func nativeLog(_ message: String) {
    let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
    let thread = Thread.isMainThread ? "main" : "background"
    print("\(Self.logTag) timestampMs=\(timestampMs) thread=\(thread) \(message)")
  }
}
