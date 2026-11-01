import UIKit

@MainActor enum MarkdownLauncher {
  static let shortcut = "com.b3log.siyuan.markdown"
  private static var pending: [(UIViewController, URL?)] = []
  private static var opening = false
  private static var deferredWorkspaceExit: (() -> Void)?

  static func requestWorkspaceExit(_ action: @escaping () -> Void) {
    deferredWorkspaceExit = action
    finishDeferredExit()
  }

  static func finishDeferredExit() {
    guard pending.isEmpty, !opening, MarkdownHost.shared.sessions.isEmpty else { return }
    let action = deferredWorkspaceExit
    deferredWorkspaceExit = nil
    action?()
  }

  static func present(from root: UIViewController, url: URL? = nil) {
    pending.append((root, url))
    drain()
  }

  private static func drain() {
    guard !opening, let (root, url) = pending.first else { return }
    var presenter = root
    while let next = presenter.presentedViewController { presenter = next }
    if presenter is UIAlertController || presenter is UIDocumentPickerViewController || presenter.isBeingDismissed || presenter.isBeingPresented {
      DispatchQueue.main.asyncAfter(deadline:.now() + 0.25) { drain() }
      return
    }
    pending.removeFirst()
    opening = true
    Task {
      defer { opening = false; drain(); finishDeferredExit() }
      if let navigation = presenter as? UINavigationController, let editor = navigation.visibleViewController as? MarkdownViewController {
        await editor.presentDocument(url:url)
        return
      }
      if let editor = presenter as? MarkdownViewController { await editor.presentDocument(url:url); return }
      do {
        let session = try await MarkdownHost.shared.create(url: url)
        let navigation = UINavigationController(rootViewController: MarkdownViewController(session: session))
        navigation.modalPresentationStyle = .fullScreen
        navigation.isModalInPresentation = true
        await withCheckedContinuation { continuation in presenter.present(navigation, animated:true) { continuation.resume() } }
      } catch MarkdownError.occupied(let owner) { MarkdownViewController.focus(owner) }
      catch {
        // 无法打开目标时保留独立入口，用户仍可选择文件或恢复草稿。
        if let session = try? await MarkdownHost.shared.create() {
          let editor = MarkdownViewController(session:session)
          editor.initialError = "markdownError"
          let navigation = UINavigationController(rootViewController:editor)
          navigation.modalPresentationStyle = .fullScreen
          navigation.isModalInPresentation = true
          await withCheckedContinuation { continuation in presenter.present(navigation, animated:true) { continuation.resume() } }
        }
      }
    }
  }
}

@MainActor final class MarkdownSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var pending: [URL?] = []
  private var opening = false

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    self.window = window
    let loading = UIViewController()
    loading.view.backgroundColor = .systemBackground
    window.rootViewController = UINavigationController(rootViewController: loading)
    window.makeKeyAndVisible()
    pending.append(contentsOf: connectionOptions.urlContexts.map(\.url).filter(MarkdownCore.isLaunch).map { MarkdownCore.accepts($0) ? $0 : nil })
    Task {
      let first = pending.isEmpty ? nil : pending.removeFirst()
      var session = try? await MarkdownHost.shared.create(url: first)
      let failed = session == nil
      if session == nil { session = try? await MarkdownHost.shared.create() }
      guard let session = session else { return }
      let editor = MarkdownViewController(session:session)
      if failed { editor.initialError = "markdownError" }
      (window.rootViewController as? UINavigationController)?.setViewControllers([editor], animated: false)
      drain()
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    pending.append(contentsOf: URLContexts.map(\.url).filter(MarkdownCore.isLaunch).map { MarkdownCore.accepts($0) ? $0 : nil })
    drain()
  }
  private func drain() {
    guard !opening, let navigation = window?.rootViewController as? UINavigationController,
      navigation.visibleViewController is MarkdownViewController else { return }
    opening = true
    Task {
      defer { opening = false }
      while !pending.isEmpty {
        let url = pending.removeFirst()
        if let editor = navigation.visibleViewController as? MarkdownViewController { await editor.presentDocument(url: url) }
      }
    }
  }
}
