/*
 * SiYuan - From thought to insight, with agents
 * Copyright (c) 2020-present, b3log.org
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  private static let shorthandMoveQueue = DispatchQueue(label: "com.ld246.siyuan.shorthand-move")

  var window: UIWindow?
  private var shorthandVC: ShorthandViewController?
  /// 闪念冷启动（root VC）后置位：豁免随后的 sceneDidBecomeActive 恢复主界面兜底，
  /// 让用户这次确实停留在闪念。仅在 scene(_:willConnectTo:) 的闪念冷启动分支置位。
  private var pendingShorthandShortcut = false
  private var hasPendingShorthandRequest = false
  private var pendingShorthandText = ""

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    let isShorthand =
      (connectionOptions.shortcutItem?.type == "com.b3log.siyuan.shorthand")
      || connectionOptions.urlContexts.contains(where: {
        $0.url.scheme == "siyuan" && $0.url.host == "shorthand"
      })

    guard isShorthand else {
      // Normal launch: system loaded Main.storyboard, ViewController.viewDidLoad will start kernel
      for context in connectionOptions.urlContexts {
        if isOIDCCallback(context.url) {
          ViewController.handleOIDCCallback(context.url)
        } else if !(context.url.scheme == "siyuan" && context.url.host == "shorthand") {
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let encoded = try? JSONEncoder().encode(context.url.absoluteString),
              let argument = String(data: encoded, encoding: .utf8)
            else {
              return
            }
            ViewController.syWebView.evaluateJavaScript("openFileByURL(\(argument))")
          }
        }
      }
      return
    }

    // Shorthand launch: replace root VC before ViewController.viewDidLoad fires
    let vc = ShorthandViewController()
    shorthandVC = vc
    configureShorthandFinish(vc)
    for context in connectionOptions.urlContexts {
      if context.url.scheme == "siyuan" && context.url.host == "shorthand",
        let text = context.url.query?.removingPercentEncoding
      {
        vc.appendText(text)
      }
    }
    window?.rootViewController = vc
    // 标记本次激活由闪念冷启动触发，豁免 sceneDidBecomeActive 的恢复兜底
    pendingShorthandShortcut = true
    // root VC 场景提交后挂起应用，root 恢复交给 sceneDidBecomeActive 兜底
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleShorthandSubmitAsRoot),
      name: ShorthandViewController.didSubmitAsRootNotification, object: nil)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      let url = context.url
      if url.scheme == "siyuan" && url.host == "shorthand" {
        presentShorthand(text: url.query?.removingPercentEncoding)
      } else if isOIDCCallback(url) {
        ViewController.handleOIDCCallback(url)
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
          guard let encoded = try? JSONEncoder().encode(url.absoluteString),
            let argument = String(data: encoded, encoding: .utf8)
          else {
            return
          }
          ViewController.syWebView.evaluateJavaScript("openFileByURL(\(argument))")
        }
      }
    }
  }

  private func isOIDCCallback(_ url: URL) -> Bool {
    return url.scheme?.lowercased() == "siyuan" && url.host == nil
      && url.path == "/oidc-callback"
  }

  private func presentShorthand(text: String? = nil) {
    guard let rootVC = window?.rootViewController else {
      enqueueShorthandRequest(text)
      return
    }
    guard window?.windowScene?.activationState == .foregroundActive else {
      enqueueShorthandRequest(text)
      return
    }
    if hasPendingShorthandRequest {
      enqueueShorthandRequest(text)
      if let root = rootVC as? ShorthandViewController, root.isCompleting {
        replaceCompletedShorthandRoot()
      } else {
        replayPendingShorthandRequest()
      }
      return
    }

    if let shorthandRoot = rootVC as? ShorthandViewController {
      if shorthandRoot.isCompleting {
        enqueueShorthandRequest(text)
        replaceCompletedShorthandRoot()
      } else if let t = text, !t.isEmpty {
        shorthandRoot.appendText(t)
      }
      return
    }

    if let existing = shorthandVC {
      if existing.isCompleting {
        enqueueShorthandRequest(text)
        return
      }
      if let t = text, !t.isEmpty {
        existing.appendText(t)
      }
      if existing.presentingViewController == nil && rootVC.presentedViewController != existing {
        existing.modalPresentationStyle = .fullScreen
        rootVC.present(existing, animated: true)
      }
      return
    }

    let vc = ShorthandViewController()
    shorthandVC = vc
    configureShorthandFinish(vc)

    if let t = text, !t.isEmpty {
      vc.appendText(t)
    }

    vc.modalPresentationStyle = .fullScreen
    rootVC.present(vc, animated: true)

    // Donate shortcut for Siri/Shortcuts
    let activity = NSUserActivity(activityType: "com.b3log.siyuan.shorthand")
    activity.title = NSLocalizedString("shorthand_label", comment: "")
    activity.isEligibleForSearch = true
    activity.isEligibleForPrediction = true
    activity.persistentIdentifier = NSUserActivityPersistentIdentifier("com.b3log.siyuan.shorthand")
    vc.userActivity = activity
    activity.becomeCurrent()
  }

  private func configureShorthandFinish(_ viewController: ShorthandViewController) {
    viewController.onFinish = { [weak self, weak viewController] in
      guard let self = self, let viewController = viewController else { return }
      if self.shorthandVC === viewController {
        self.shorthandVC = nil
      }
      self.replayPendingShorthandRequest()
    }
  }

  private func enqueueShorthandRequest(_ text: String?) {
    hasPendingShorthandRequest = true
    guard let text = text, !text.isEmpty else { return }
    pendingShorthandText = joinShorthandContent(pendingShorthandText, text)
  }

  private func consumeShorthandRequest() -> String? {
    guard hasPendingShorthandRequest else { return nil }
    let text = pendingShorthandText
    hasPendingShorthandRequest = false
    pendingShorthandText = ""
    return text.isEmpty ? nil : text
  }

  private func replayPendingShorthandRequest() {
    guard hasPendingShorthandRequest else { return }
    guard window?.windowScene?.activationState == .foregroundActive else { return }
    let text = consumeShorthandRequest()
    presentShorthand(text: text)
  }

  private func replaceCompletedShorthandRoot() {
    guard hasPendingShorthandRequest else { return }
    guard let root = window?.rootViewController as? ShorthandViewController,
      root.isCompleting
    else {
      return
    }
    let text = consumeShorthandRequest()
    let viewController = ShorthandViewController()
    shorthandVC = viewController
    configureShorthandFinish(viewController)
    if let text = text {
      viewController.appendText(text)
    }
    window?.rootViewController = viewController
  }

  private func joinShorthandContent(_ existing: String, _ incoming: String) -> String {
    guard !existing.isEmpty else { return incoming }
    if existing.hasSuffix("\n\n") {
      return existing + incoming
    }
    if existing.hasSuffix("\n") {
      return existing + "\n" + incoming
    }
    return existing + "\n\n" + incoming
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    flushShorthandDraft()
    NotificationCenter.default.removeObserver(
      self, name: ShorthandViewController.didSubmitAsRootNotification, object: nil)
  }

  /// 闪念作为 root VC 提交后：仅挂起应用。
  /// root 恢复交给 sceneDidBecomeActive 在下次激活时安全完成，避免此处同步拉起内核与挂起竞争。
  @objc private func handleShorthandSubmitAsRoot() {
    UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
  }

  private func restoreMainWindow() {
    guard window?.rootViewController is ShorthandViewController else { return }
    guard let mainVC = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
    else {
      return
    }
    window?.rootViewController = mainVC
    shorthandVC = nil
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    LANSyncBonjour.shared.start()
    let keepShorthandRoot = pendingShorthandShortcut
    pendingShorthandShortcut = false
    // App Intent（iOS 16+ 快捷指令/Siri，见 ShorthandAppShortcuts）入队的闪念请求：
    if let text = ShorthandLauncher.consume() {
      presentShorthand(text: text.isEmpty ? nil : text)
      return
    }
    if hasPendingShorthandRequest {
      if let root = window?.rootViewController as? ShorthandViewController,
        root.isCompleting
      {
        replaceCompletedShorthandRoot()
      } else {
        replayPendingShorthandRequest()
      }
      return
    }
    if keepShorthandRoot {
      // 本次激活由闪念快捷方式触发，用户确实要进闪念，跳过恢复
      return
    }
    // 兜底：点 App 图标等非闪念入口激活时，若 root 仍是闪念则恢复主界面。
    // 与 Android（BootActivity→MainActivity）一致：launcher 永远回到主界面。
    if window?.rootViewController is ShorthandViewController {
      restoreMainWindow()
    }
  }

  func sceneWillResignActive(_ scene: UIScene) {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
    flushShorthandDraft()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    Self.shorthandMoveQueue.async { [weak self] in
      self?.moveSharedShorthands()
    }
  }

  func windowScene(
    _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    if shortcutItem.type == "com.b3log.siyuan.shorthand" {
      presentShorthand()
    }
    completionHandler(true)
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == "com.b3log.siyuan.shorthand" {
      presentShorthand()
    }
  }

  private func moveSharedShorthands() {
    guard
      let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.ld246.siyuan")
    else {
      return
    }
    let sharedDirectoryURL = containerURL.appendingPathComponent(
      "home/.config/siyuan/shortcuts/shorthands", isDirectory: true)
    let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let targetDirectoryURL = urls[0].appendingPathComponent(
      "home/.config/siyuan/shortcuts/shorthands", isDirectory: true)

    let fm = FileManager.default
    guard fm.fileExists(atPath: sharedDirectoryURL.path) else { return }

    do {
      try fm.createDirectory(
        at: targetDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    } catch {
      print("create shorthand directory failed: \(error)")
      return
    }

    let markdownURLs: [URL]
    do {
      markdownURLs = try fm.contentsOfDirectory(
        at: sharedDirectoryURL, includingPropertiesForKeys: [.isRegularFileKey]
      ).filter { $0.pathExtension == "md" }
    } catch {
      print("list shared shorthands failed: \(error)")
      return
    }

    let sharedAssetsURL = sharedDirectoryURL.appendingPathComponent("assets", isDirectory: true)
    let targetAssetsURL = targetDirectoryURL.appendingPathComponent("assets", isDirectory: true)
    if fm.fileExists(atPath: sharedAssetsURL.path),
      !copySharedAssets(from: sharedAssetsURL, to: targetAssetsURL)
    {
      return
    }

    do {
      for sourceURL in markdownURLs {
        guard fm.fileExists(atPath: sourceURL.path) else { continue }
        guard try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
          print("unsupported shared shorthand file: \(sourceURL.lastPathComponent)")
          continue
        }
        let targetURL = nextSharedShorthandURL(
          for: sourceURL, in: targetDirectoryURL, sharedDirectoryURL: sharedDirectoryURL)
        try fm.moveItem(at: sourceURL, to: targetURL)
      }
      removeDirectoryIfEmpty(sharedAssetsURL)
      removeDirectoryIfEmpty(sharedDirectoryURL)
    } catch {
      print("move shared shorthand failed: \(error)")
    }
  }

  private func copySharedAssets(from sourceDirectoryURL: URL, to targetDirectoryURL: URL) -> Bool {
    let fm = FileManager.default
    do {
      try fm.createDirectory(
        at: targetDirectoryURL, withIntermediateDirectories: true, attributes: nil)
      let targetEntries = try fm.contentsOfDirectory(
        at: targetDirectoryURL, includingPropertiesForKeys: nil)
      for url in targetEntries where url.lastPathComponent.hasPrefix(".shorthand-partial-") {
        try fm.removeItem(at: url)
      }

      let sourceURLs = try fm.contentsOfDirectory(
        at: sourceDirectoryURL, includingPropertiesForKeys: [.isRegularFileKey])
      for sourceURL in sourceURLs {
        if sourceURL.lastPathComponent.hasPrefix(".shorthand-partial-") {
          continue
        }
        guard try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
          print("unsupported shared shorthand asset: \(sourceURL.lastPathComponent)")
          return false
        }
        let targetURL = targetDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: targetURL.path) {
          guard fm.contentsEqual(atPath: sourceURL.path, andPath: targetURL.path) else {
            print("shared shorthand asset collision: \(sourceURL.lastPathComponent)")
            return false
          }
          try fm.removeItem(at: sourceURL)
          continue
        }

        let partialURL = targetDirectoryURL.appendingPathComponent(
          ".shorthand-partial-" + UUID().uuidString)
        do {
          try fm.copyItem(at: sourceURL, to: partialURL)
          try fm.moveItem(at: partialURL, to: targetURL)
          try fm.removeItem(at: sourceURL)
        } catch {
          try? fm.removeItem(at: partialURL)
          throw error
        }
      }
      removeDirectoryIfEmpty(sourceDirectoryURL)
      return true
    } catch {
      print("move shared shorthand assets failed: \(error)")
      return false
    }
  }

  private func nextSharedShorthandURL(
    for sourceURL: URL, in targetDirectoryURL: URL, sharedDirectoryURL: URL
  ) -> URL {
    let fm = FileManager.default
    var timestamp = Int64(sourceURL.deletingPathExtension().lastPathComponent)
      ?? Int64(Date().timeIntervalSince1970 * 1000)
    var fileName = String(timestamp) + ".md"
    var targetURL = targetDirectoryURL.appendingPathComponent(fileName)
    var sharedURL = sharedDirectoryURL.appendingPathComponent(fileName)
    while fm.fileExists(atPath: targetURL.path)
      || (sharedURL != sourceURL && fm.fileExists(atPath: sharedURL.path))
    {
      timestamp += 1
      fileName = String(timestamp) + ".md"
      targetURL = targetDirectoryURL.appendingPathComponent(fileName)
      sharedURL = sharedDirectoryURL.appendingPathComponent(fileName)
    }
    return targetURL
  }

  private func removeDirectoryIfEmpty(_ directoryURL: URL) {
    let fm = FileManager.default
    do {
      guard fm.fileExists(atPath: directoryURL.path) else { return }
      guard try fm.contentsOfDirectory(atPath: directoryURL.path).isEmpty else { return }
      try fm.removeItem(at: directoryURL)
    } catch {
      print("remove empty shorthand directory failed: \(error)")
    }
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    LANSyncBonjour.shared.stop()
    flushShorthandDraft()
    guard !(window?.rootViewController is ShorthandViewController) else { return }
    ViewController.syWebView.evaluateJavaScript("lockscreenByMode();")
  }

  private func flushShorthandDraft() {
    let rootShorthand = window?.rootViewController as? ShorthandViewController
    rootShorthand?.flushDraft()
    if let shorthandVC = shorthandVC, shorthandVC !== rootShorthand {
      shorthandVC.flushDraft()
    }
  }

}
