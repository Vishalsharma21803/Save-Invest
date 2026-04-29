import SafariServices
import UIKit

final class SaveUpSafariSheetCoordinator: NSObject {
  enum State: String {
    case idle
    case presenting
    case active
    case closing
    case closed
  }

  private weak var sceneDelegate: SceneDelegate?
  private var safariViewController: SFSafariViewController?
  private(set) var activeSessionId: String?
  private var state: State = .idle
  private var closeEmitted = false
  private var patchSuccess = false
  private var patchAttempts = 0
  private var closeReasonByApp = false
  private var closeTrigger = "unknown"
  private var startAtMs: Int64 = 0
  private var watchdogWorkItem: DispatchWorkItem?

  private static let watchdogSeconds: TimeInterval = 45
  private static let customDetentIdentifier = UISheetPresentationController.Detent.Identifier("saveup_90pct")

  init(sceneDelegate: SceneDelegate) {
    self.sceneDelegate = sceneDelegate
    super.init()
  }

  func startSafariSession(urlString: String, sessionId: String) -> [String: Any] {
    guard let sceneDelegate else {
      return [
        "started": false,
        "code": "IOS_A1",
        "error": "SceneDelegate unavailable"
      ]
    }

    guard let url = URL(string: urlString) else {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=start-failed code=IOS_A2 reason=invalid-url"
      )
      return [
        "started": false,
        "code": "IOS_A2",
        "error": "Invalid URL"
      ]
    }

    if activeSessionId != nil || state == .presenting || state == .active || state == .closing {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=start-failed code=IOS_A3 reason=session-already-active"
      )
      return [
        "started": false,
        "code": "IOS_A3",
        "error": "Another safari session is active"
      ]
    }

    guard let presenter = sceneDelegate.topMostViewController() else {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=start-failed code=IOS_A4 reason=no-presenter"
      )
      return [
        "started": false,
        "code": "IOS_A4",
        "error": "No presenter view controller"
      ]
    }

    startAtMs = Self.nowMs()
    activeSessionId = sessionId
    closeEmitted = false
    closeReasonByApp = false
    closeTrigger = "unknown"
    patchSuccess = false
    patchAttempts = 0
    setState(.presenting)

    sceneDelegate.nativeLog(
      "sessionId=\(sessionId) state=\(state.rawValue) event=present-begin "
      + "host=\(url.host ?? "unknown") vcClass=\(type(of: presenter)) presentedDepth=\(sceneDelegate.presentationDepth())"
    )

    let configuration = SFSafariViewController.Configuration()
    configuration.barCollapsingEnabled = false
    configuration.entersReaderIfAvailable = false

    let safari = SFSafariViewController(url: url, configuration: configuration)
    safari.modalPresentationStyle = .pageSheet
    safari.dismissButtonStyle = .close
    safari.delegate = self
    safari.presentationController?.delegate = self
    safariViewController = safari

    presenter.present(safari, animated: true) { [weak self] in
      guard let self, let sceneDelegate = self.sceneDelegate else {
        return
      }

      self.setState(.active)
      let elapsedMs = Self.nowMs() - self.startAtMs
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(self.state.rawValue) event=present-end elapsedMs=\(elapsedMs)"
      )
      sceneDelegate.emitToFlutter(
        method: "safariSessionPresented",
        arguments: [
          "sessionId": sessionId,
          "state": self.state.rawValue,
          "elapsedMs": elapsedMs
        ]
      )
      _ = self.patchSheetIfPresented(sessionId: sessionId, attempt: 0)
      self.armWatchdog(sessionId: sessionId)
    }

    return [
      "started": true,
      "sessionId": sessionId
    ]
  }

  func closeSafariSession(sessionId: String, trigger: String) -> [String: Any] {
    guard let sceneDelegate else {
      return [
        "closed": false,
        "code": "IOS_C3",
        "error": "SceneDelegate unavailable"
      ]
    }

    guard let activeSessionId else {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=close-ignored reason=no-active-session trigger=\(trigger)"
      )
      return [
        "closed": false,
        "code": "IOS_C4",
        "error": "No active session"
      ]
    }

    if activeSessionId != sessionId {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=close-ignored reason=stale-session activeSessionId=\(activeSessionId)"
      )
      return [
        "closed": false,
        "code": "IOS_D1",
        "error": "Stale session id"
      ]
    }

    closeReasonByApp = true
    closeTrigger = trigger
    setState(.closing)
    cancelWatchdog()

    sceneDelegate.nativeLog(
      "sessionId=\(sessionId) state=\(state.rawValue) event=close-request trigger=\(trigger)"
    )

    if let safari = safariViewController {
      safari.dismiss(animated: true) { [weak self] in
        guard let self else {
          return
        }
        self.emitClosed(reason: "closedByApp", source: "programmatic:\(trigger)")
      }
      return [
        "closed": true,
        "sessionId": sessionId
      ]
    }

    emitClosed(reason: "closedByApp", source: "programmatic-missing-safari:\(trigger)")
    return [
      "closed": true,
      "sessionId": sessionId
    ]
  }

  func patchSheetIfPresented(sessionId: String, attempt: Int) -> [String: Any] {
    guard let sceneDelegate else {
      return [
        "patched": false,
        "attempt": attempt,
        "code": "IOS_B9",
        "error": "SceneDelegate unavailable"
      ]
    }

    guard let activeSessionId else {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=patch-ignored reason=no-active-session"
      )
      return [
        "patched": false,
        "attempt": attempt
      ]
    }

    if activeSessionId != sessionId {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=patch-ignored reason=stale-session activeSessionId=\(activeSessionId)"
      )
      return [
        "patched": false,
        "attempt": attempt
      ]
    }

    patchAttempts = max(patchAttempts, attempt)
    guard let topViewController = sceneDelegate?.topMostViewController() else {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=patch-miss attempt=\(attempt) reason=no-top-vc"
      )
      emitPatched(
        sessionId: sessionId,
        attempt: attempt,
        detentMode: "none",
        undimmedApplied: false
      )
      return [
        "patched": false,
        "attempt": attempt
      ]
    }

    guard let sheet = topViewController.sheetPresentationController else {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=patch-miss attempt=\(attempt) "
        + "reason=no-sheet vcClass=\(type(of: topViewController))"
      )
      emitPatched(
        sessionId: sessionId,
        attempt: attempt,
        detentMode: "none",
        undimmedApplied: false
      )
      return [
        "patched": false,
        "attempt": attempt
      ]
    }

    if #available(iOS 16.0, *) {
      let customDetent = UISheetPresentationController.Detent.custom(
        identifier: Self.customDetentIdentifier
      ) { context in
        context.maximumDetentValue * 0.90
      }

      sheet.animateChanges {
        sheet.detents = [customDetent]
        sheet.largestUndimmedDetentIdentifier = Self.customDetentIdentifier
        topViewController.isModalInPresentation = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        sheet.prefersGrabberVisible = false
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.preferredCornerRadius = 16
      }

      patchSuccess = true
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=patch-success attempt=\(attempt) "
        + "detentMode=custom90 vcClass=\(type(of: topViewController)) "
        + "presentedDepth=\(sceneDelegate.presentationDepth())"
      )
      emitPatched(
        sessionId: sessionId,
        attempt: attempt,
        detentMode: "custom90",
        undimmedApplied: true
      )
      return [
        "patched": true,
        "attempt": attempt,
        "detentMode": "custom90"
      ]
    }

    if #available(iOS 15.0, *) {
      sheet.animateChanges {
        sheet.detents = [.large()]
        sheet.largestUndimmedDetentIdentifier = .large
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        sheet.prefersGrabberVisible = false
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.preferredCornerRadius = 16
      }

      patchSuccess = true
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=patch-success attempt=\(attempt) "
        + "detentMode=largeFallback vcClass=\(type(of: topViewController)) "
        + "presentedDepth=\(sceneDelegate.presentationDepth())"
      )
      emitPatched(
        sessionId: sessionId,
        attempt: attempt,
        detentMode: "largeFallback",
        undimmedApplied: true
      )
      return [
        "patched": true,
        "attempt": attempt,
        "detentMode": "largeFallback"
      ]
    }

    sceneDelegate.nativeLog(
      "sessionId=\(sessionId) state=\(state.rawValue) event=patch-miss attempt=\(attempt) reason=unsupported-ios-version"
    )
    emitPatched(
      sessionId: sessionId,
      attempt: attempt,
      detentMode: "unsupported",
      undimmedApplied: false
    )
    return [
      "patched": false,
      "attempt": attempt,
      "detentMode": "unsupported"
    ]
  }

  private func setState(_ next: State) {
    state = next
    sceneDelegate?.nativeLog(
      "sessionId=\(activeSessionId ?? "nil") state=\(state.rawValue) event=state-transition"
    )
  }

  private func emitPatched(
    sessionId: String,
    attempt: Int,
    detentMode: String,
    undimmedApplied: Bool
  ) {
    guard let sceneDelegate else {
      return
    }
    sceneDelegate.emitToFlutter(
      method: "safariSessionPatched",
      arguments: [
        "sessionId": sessionId,
        "attempt": attempt,
        "iosVersion": UIDevice.current.systemVersion,
        "detentMode": detentMode,
        "undimmedApplied": undimmedApplied
      ]
    )
  }

  private func emitClosed(reason: String, source: String) {
    guard let sceneDelegate, let sessionId = activeSessionId else {
      return
    }

    if closeEmitted {
      sceneDelegate.nativeLog(
        "sessionId=\(sessionId) state=\(state.rawValue) event=close-dedup reason=\(reason) source=\(source)"
      )
      return
    }
    closeEmitted = true
    cancelWatchdog()
    setState(.closed)

    let elapsedMs = max(0, Self.nowMs() - startAtMs)
    sceneDelegate.nativeLog(
      "sessionId=\(sessionId) state=\(state.rawValue) event=closed reason=\(reason) source=\(source) "
      + "elapsedMs=\(elapsedMs) patchAttempts=\(patchAttempts) patchSuccess=\(patchSuccess)"
    )

    sceneDelegate.emitToFlutter(
      method: "safariSessionClosed",
      arguments: [
        "sessionId": sessionId,
        "reason": reason,
        "source": source,
        "elapsedMs": elapsedMs
      ]
    )

    safariViewController = nil
    activeSessionId = nil
    closeReasonByApp = false
    closeTrigger = "unknown"
  }

  private func emitError(sessionId: String, code: String, message: String, stage: String) {
    guard let sceneDelegate else {
      return
    }
    sceneDelegate.nativeLog(
      "sessionId=\(sessionId) state=\(state.rawValue) event=error code=\(code) stage=\(stage) message=\(message)"
    )
    sceneDelegate.emitToFlutter(
      method: "safariSessionError",
      arguments: [
        "sessionId": sessionId,
        "code": code,
        "message": message,
        "stage": stage
      ]
    )
  }

  private func armWatchdog(sessionId: String) {
    cancelWatchdog()
    let item = DispatchWorkItem { [weak self] in
      guard let self, let activeSessionId = self.activeSessionId else {
        return
      }
      guard activeSessionId == sessionId, self.state == .active, !self.closeEmitted else {
        return
      }
      self.emitError(
        sessionId: sessionId,
        code: "IOS_C1",
        message: "Close callback timeout",
        stage: "watchdog"
      )
      _ = self.closeSafariSession(sessionId: sessionId, trigger: "watchdog_timeout")
    }
    watchdogWorkItem = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.watchdogSeconds,
      execute: item
    )
  }

  private func cancelWatchdog() {
    watchdogWorkItem?.cancel()
    watchdogWorkItem = nil
  }

  private static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }
}

extension SaveUpSafariSheetCoordinator: SFSafariViewControllerDelegate {
  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    guard activeSessionId != nil else {
      return
    }
    if closeReasonByApp {
      emitClosed(reason: "closedByApp", source: "didFinish:\(closeTrigger)")
    } else {
      emitClosed(reason: "userDismissed", source: "didFinish")
    }
  }
}

extension SaveUpSafariSheetCoordinator: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard activeSessionId != nil else {
      return
    }
    if closeReasonByApp {
      emitClosed(reason: "closedByApp", source: "presentationDidDismiss:\(closeTrigger)")
    } else {
      emitClosed(reason: "userDismissed", source: "presentationDidDismiss")
    }
  }
}
