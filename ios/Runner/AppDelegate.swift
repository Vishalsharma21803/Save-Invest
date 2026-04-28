import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let safariChannel = FlutterMethodChannel(
      name: "com.saveup.app/safari_sheet",
      binaryMessenger: controller.binaryMessenger
    )

    safariChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "enableUndimmedBackground":
        let patched = self?.makeTopSheetUndimmed() ?? false
        result(patched)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @discardableResult
  private func makeTopSheetUndimmed() -> Bool {
    guard let rootVC = window?.rootViewController else {
      print("[SaveUp] makeTopSheetUndimmed: no rootViewController")
      return false
    }

    var topVC = rootVC
    while let presented = topVC.presentedViewController {
      topVC = presented
    }

    guard let sheet = topVC.sheetPresentationController else {
      print("[SaveUp] No sheetPresentationController found - not ready")
      return false
    }

    if #available(iOS 16.0, *) {
      let customIdentifier = UISheetPresentationController.Detent.Identifier("saveup_90pct")
      let customDetent = UISheetPresentationController.Detent.custom(
        identifier: customIdentifier
      ) { context in
        return context.maximumDetentValue * 0.90
      }

      sheet.animateChanges {
        sheet.detents = [customDetent]
        sheet.largestUndimmedDetentIdentifier = customIdentifier
        topVC.isModalInPresentation = true
      }

      print("[SaveUp] iOS 16+: 90% detent + undimmed applied")
      return true
    } else if #available(iOS 15.0, *) {
      sheet.animateChanges {
        sheet.detents = [.large()]
        sheet.largestUndimmedDetentIdentifier = .large
      }

      print("[SaveUp] iOS 15: large detent fallback applied")
      return true
    }

    return false
  }
}
