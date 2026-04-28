import Flutter
import UIKit

final class SaveUpSafariSheetCoordinator {
  private weak var sceneDelegate: SceneDelegate?

  init(sceneDelegate: SceneDelegate) {
    self.sceneDelegate = sceneDelegate
  }

  func makeTopSheetUndimmed() -> Bool {
    guard let topViewController = sceneDelegate?.topMostViewController() else {
      print("[SaveUp] No top view controller")
      return false
    }

    guard let sheet = topViewController.sheetPresentationController else {
      print("[SaveUp] No sheetPresentationController found - not ready")
      return false
    }

    if #available(iOS 16.0, *) {
      let customIdentifier = UISheetPresentationController.Detent.Identifier("saveup_90pct")
      let customDetent = UISheetPresentationController.Detent.custom(
        identifier: customIdentifier
      ) { context in
        context.maximumDetentValue * 0.90
      }

      sheet.animateChanges {
        sheet.detents = [customDetent]
        sheet.largestUndimmedDetentIdentifier = customIdentifier
        topViewController.isModalInPresentation = true
      }

      print("[SaveUp] iOS 16+: 90% custom detent applied")
      return true
    }

    if #available(iOS 15.0, *) {
      sheet.animateChanges {
        sheet.detents = [.large()]
        sheet.largestUndimmedDetentIdentifier = .large
      }

      print("[SaveUp] iOS 15: large detent applied")
      return true
    }

    return false
  }
}
