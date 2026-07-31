/*
 * SiYuan - 源于思考，饮水思源
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

  var window: UIWindow?
  private var shorthandVC: ShorthandViewController?
  /// 闪念冷启动（root VC）后置位：豁免随后的 sceneDidBecomeActive 恢复主界面兜底，
  /// 让用户这次确实停留在闪念。仅在 scene(_:willConnectTo:) 的闪念冷启动分支置位。
  private var pendingShorthandShortcut = false

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
        if !(context.url.scheme == "siyuan" && context.url.host == "shorthand") {
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            ViewController.syWebView.evaluateJavaScript(
              "openFileByURL('" + context.url.absoluteString + "')")
          }
        }
      }
      return
    }

    // Shorthand launch: replace root VC before ViewController.viewDidLoad fires
    let vc = ShorthandViewController()
    shorthandVC = vc
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
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
          ViewController.syWebView.evaluateJavaScript("openFileByURL('" + url.absoluteString + "')")
        }
      }
    }
  }

  private func presentShorthand(text: String? = nil) {
    guard let rootVC = window?.rootViewController else { return }

    if let shorthandRoot = rootVC as? ShorthandViewController {
      if let t = text, !t.isEmpty {
        shorthandRoot.appendText(t)
      }
      return
    }

    if let existing = shorthandVC {
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

  func sceneDidDisconnect(_ scene: UIScene) {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
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
    // App Intent（iOS 16+ 快捷指令/Siri，见 ShorthandAppShortcuts）入队的闪念请求：
    if let text = ShorthandLauncher.consume() {
      presentShorthand(text: text.isEmpty ? nil : text)
      return
    }
    if pendingShorthandShortcut {
      // 本次激活由闪念快捷方式触发，用户确实要进闪念，跳过恢复
      pendingShorthandShortcut = false
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
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    moveSharedShorthands()
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
    let sharedDir = containerURL.path + "/home/.config/siyuan/shortcuts/shorthands/"
    let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let targetDir = urls[0].path + "/home/.config/siyuan/shortcuts/shorthands/"

    let fm = FileManager.default
    guard fm.fileExists(atPath: sharedDir) else { return }

    try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true, attributes: nil)

    guard let entries = try? fm.contentsOfDirectory(atPath: sharedDir) else { return }
    for entry in entries {
      let src = sharedDir + entry
      let dst = targetDir + entry
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue {
        try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true, attributes: nil)
        if let subEntries = try? fm.contentsOfDirectory(atPath: src) {
          for subEntry in subEntries {
            let subSrc = src + "/" + subEntry
            let subDst = dst + "/" + subEntry
            if fm.fileExists(atPath: subDst) {
              try? fm.removeItem(atPath: subDst)
            }
            try? fm.moveItem(atPath: subSrc, toPath: subDst)
          }
        }
        try? fm.removeItem(atPath: src)
      } else {
        if fm.fileExists(atPath: dst) {
          try? fm.removeItem(atPath: dst)
        }
        try? fm.moveItem(atPath: src, toPath: dst)
      }
    }
    try? fm.removeItem(atPath: sharedDir)
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    guard !(window?.rootViewController is ShorthandViewController) else { return }
    ViewController.syWebView.evaluateJavaScript("lockscreenByMode();")
  }

}
