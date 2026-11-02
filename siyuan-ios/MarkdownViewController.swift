import UIKit
import UniformTypeIdentifiers
import WebKit

@MainActor final class MarkdownViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIDocumentPickerDelegate {
  static var visible: [String: WeakMarkdownController] = [:]
  private(set) var session: MarkdownHost.Session
  private let containerID: String
  private let tree: MarkdownTree
  private var documentEpoch = 0
  private var treeInitialized = false
  private var treeOpening = false
  private var treeCandidate: (ticket:String, session:MarkdownHost.Session, epoch:Int)?
  private var treeCommitted: String?
  private var treePoll: Task<Void,Never>?
  private var webView: WKWebView!
  private var schemeHandler: MarkdownSchemeHandler!
  private var pickerCompletion: (([URL]) -> Void)?
  private var replies: [String: (Bool) -> Void] = [:]
  private var resourceScopes: [URL] = []
  private var resourceDirectories: [MarkdownDirectoryGrant] = []
  private var imageFiles: [URL: String] = [:]
  private var resources: [String: MarkdownResourceGrant] = [:]
  private var resourceGeneration = 0
  private var closing = false
  private let languages: [String: String]
  private let language: String
  private var preferences: MarkdownJSON
  private var preferencesBlocked = false
  private var ruleList: WKContentRuleList?
  var initialError: String?
  private var rendererTerminated = false

  static let appDirectory = Bundle.main.resourceURL!.appendingPathComponent("app", isDirectory: true)
  static let assets = appDirectory.appendingPathComponent("stage/build/markdown", isDirectory: true)
  static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
    "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif", "bmp": "image/bmp", "ico": "image/x-icon"]

  init(session: MarkdownHost.Session) {
    self.session = session
    containerID = session.id
    tree = MarkdownTree(storage:MarkdownHost.shared.directory.appendingPathComponent("tree-view.json"))
    let preferred = Locale.preferredLanguages.first ?? "en"
    let selectedLanguage = preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") ? "zh-TW" : preferred.hasPrefix("zh") ? "zh-CN" : preferred.hasPrefix("pt") ? "pt-BR" : preferred.components(separatedBy: "-")[0]
    language = selectedLanguage
    let langDirectory = Self.appDirectory.appendingPathComponent("appearance/langs", isDirectory: true)
    let bytes = (try? Data(contentsOf: langDirectory.appendingPathComponent(selectedLanguage + ".json"))) ?? (try? Data(contentsOf: langDirectory.appendingPathComponent("en.json"))) ?? Data()
    let languageObject = (try? JSONSerialization.jsonObject(with:bytes) as? MarkdownJSON) ?? [:]
    languages = languageObject.compactMapValues { $0 as? String }
    preferences = ["mode": "ir", "theme": "system", "fontSize": 16]
    do { preferences = try MarkdownHost.shared.preferences() } catch { preferencesBlocked = true }
    super.init(nibName: nil, bundle: nil)
    Self.visible[session.id] = WeakMarkdownController(self)
    tree.onChange = { [weak self] in self?.notify("tree-change") }
    session.onExternalChange = { [weak self] in self?.notify("external-change") }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  deinit {
    treePoll?.cancel()
    for url in resourceScopes { url.stopAccessingSecurityScopedResource() }
  }
  func text(_ key: String) -> String { languages[key] ?? key }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    applyTheme()
    // 文件名与状态由共享编辑页呈现；原生导航栏只保留必要的关闭入口。
    title = nil
    navigationItem.hidesBackButton = true
    if navigationController?.viewControllers.first !== self || navigationController?.presentingViewController != nil {
      navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closeEditor))
    }
    navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    schemeHandler = MarkdownSchemeHandler(owner: self)
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: MarkdownCore.scheme)
    configuration.userContentController.add(WeakMarkdownScriptHandler(self), name: "siyuanMarkdown")
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.isOpaque = false
    updateSurfaceColors()
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
    ])
    let rules = """
      [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
      """
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "siyuan-markdown-offline", encodedContentRuleList: rules) { [weak self] rules, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard let rules = rules, error == nil else { self.showError(); return }
        self.ruleList = rules
        self.webView.configuration.userContentController.add(rules)
        self.webView.load(URLRequest(url: URL(string: "\(MarkdownCore.scheme)://\(self.containerID)/index.html")!))
      }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    updateSurfaceColors()
    notify("theme", extra: ["dark": traitCollection.userInterfaceStyle == .dark])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    applyTheme()
    if navigationController?.viewControllers.first !== self || navigationController?.presentingViewController != nil {
      navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem:.done, target:self, action:#selector(closeEditor))
    } else { navigationItem.leftBarButtonItem = nil }
    if let error = initialError { initialError = nil; showError(message:error) }
    else if preferencesBlocked { showError() }
    if treeInitialized { foreground() }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    treePoll?.cancel(); treePoll = nil
    tree.observing = false
  }

  private func applyTheme() {
    let theme = preferences["theme"] as? String
    let style: UIUserInterfaceStyle = theme == "dark" ? .dark : theme == "light" ? .light : .unspecified
    overrideUserInterfaceStyle = style
    navigationController?.overrideUserInterfaceStyle = style
    updateSurfaceColors()
  }

  private func updateSurfaceColors() {
    guard isViewLoaded else { return }
    let background = effectiveDark ? UIColor(white: 30.0 / 255.0, alpha: 1) : UIColor.white
    view.backgroundColor = background
    webView?.backgroundColor = background
    webView?.scrollView.backgroundColor = background
  }

  var effectiveDark: Bool {
    let theme = preferences["theme"] as? String ?? "system"
    return theme == "dark" || theme == "system" && traitCollection.userInterfaceStyle == .dark
  }

  @objc private func background() {
    tree.observing = false
    treePoll?.cancel(); treePoll = nil
    var task = UIBackgroundTaskIdentifier.invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "Markdown draft") {
      if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
    Task {
      _ = await command("background")
      if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
  }
  @objc private func foreground() {
    tree.observing = true
    notify("external-change")
    treePoll?.cancel()
    treePoll = Task { [weak self] in
      while !Task.isCancelled {
        guard let self = self else { return }
        if await self.tree.poll() { self.notify("tree-change") }
        do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
      }
    }
  }
  @objc private func closeEditor() {
    guard !closing else { return }
    guard let navigation = navigationController,
      navigation.viewControllers.first !== self || navigation.presentingViewController != nil else { return }
    closing = true
    Task {
      defer { closing = false }
      await cancelTreeCandidate()
      guard await command("close"), MarkdownHost.shared.sessions[session.id] == nil else { return }
      Self.visible.removeValue(forKey: session.id)
      if navigationController?.viewControllers.first === self { navigationController?.dismiss(animated: true) }
      else { navigationController?.popViewController(animated: true) }
      MarkdownLauncher.finishDeferredExit()
    }
  }

  func notify(_ type: String, extra: MarkdownJSON = [:]) {
    var message = extra
    message["id"] = MarkdownCore.newID()
    message["type"] = type
    javascript("__siyuanMarkdownCommand", value: message)
  }
  private func command(_ type: String) async -> Bool {
    let id = MarkdownCore.newID()
    guard replies[id] == nil else { return false }
    return await withCheckedContinuation { continuation in
      replies[id] = { continuation.resume(returning: $0) }
      javascript("__siyuanMarkdownCommand", value: ["id": id, "type": type])
      DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
        self?.replies.removeValue(forKey: id)?(false)
      }
    }
  }
  private func javascript(_ method: String, value: Any) {
    guard let data = try? MarkdownCore.jsonData(value), let json = String(data: data, encoding: .utf8) else { return }
    webView?.evaluateJavaScript("window.\(method)?.(\(json))", completionHandler: nil)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.webView === webView, message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.protocol == MarkdownCore.scheme,
      message.frameInfo.securityOrigin.host == containerID,
      message.frameInfo.request.url?.path == "/index.html",
      let request = message.body as? MarkdownJSON, let id = request["id"] as? String, id.count <= 128,
      let action = request["action"] as? String else { return }
    let epoch = documentEpoch
    Task {
      do {
        let result = try await perform(action, payload: request["payload"])
        if epoch == documentEpoch || action == "tree-commit-open" {
          javascript("__siyuanMarkdownResponse", value: ["id": id, "result": result])
        } else {
          javascript("__siyuanMarkdownResponse", value: ["id":id,"error":"Stale Markdown request"])
        }
      } catch {
        let failure: Any = epoch == documentEpoch ? MarkdownCore.failure(error)["error"] ?? "unavailable" : "Stale Markdown request"
        javascript("__siyuanMarkdownResponse", value: ["id": id, "error": failure])
      }
    }
  }

  private func perform(_ action: String, payload: Any?) async throws -> Any {
    let session = self.session
    let started = documentEpoch
    if action.hasPrefix("host:") {
      let epoch = documentEpoch
      let result = try await MarkdownHost.shared.request(String(action.dropFirst(5)), payload: MarkdownCore.dictionary(payload), sessionID: session.id)
      guard epoch == documentEpoch else { throw MarkdownError.invalid }
      synchronizeResources()
      if action == "host:commitSaveAs", (result as? MarkdownJSON)?["kind"] as? String == "committed" {
        if treeCandidate != nil { treeFollowAfterCancel = true }
        else { await tree.follow(current?.url, authorizedDirectory:current?.scope, afterSaveAs:true) }
        notify("tree-change")
      }
      return result
    }
    switch action {
    case "bootstrap":
      if !treeInitialized { treeInitialized = true; await tree.follow(current?.url, authorizedDirectory:current?.scope); foreground() }
      var bootstrap: MarkdownJSON = ["sessionId": session.id, "content": session.initial, "format": session.format,
        "preferences": preferences, "languages": languages, "lang": language, "platform": "ios", "dark": traitCollection.userInterfaceStyle == .dark]
      if let current = current {
        var target = current.target
        target["baseline"] = session.restoredBaseline ?? current.baseline
        bootstrap["target"] = target
      }
      bootstrap["recovered"] = session.recovered
      return bootstrap
    case "tree-state": return await tree.state()
    case "tree-list":
      let epoch = documentEpoch
      let result = await tree.list(try MarkdownCore.dictionary(payload))
      guard epoch == documentEpoch else { throw MarkdownError.invalid }
      return result
    case "tree-choose-root":
      guard treeCandidate == nil, !treeOpening else { throw MarkdownError.invalid }
      let epoch = documentEpoch
      guard let url = await pick([.folder]).first else { return ["kind":"cancelled"] }
      guard epoch == documentEpoch else { throw MarkdownError.invalid }
      try await tree.choose(url)
      guard epoch == documentEpoch else { throw MarkdownError.invalid }
      notify("tree-change")
      return await tree.state()
    case "tree-save-view": try tree.saveView(MarkdownCore.dictionary(payload)); return NSNull()
    case "tree-prepare-open": return await prepareTreeOpen(try MarkdownCore.dictionary(payload))
    case "tree-commit-open":
      guard let ticket = payload as? String else { throw MarkdownError.invalid }
      if treeCommitted == ticket { return try await perform("bootstrap",payload:nil) }
      guard let candidate = treeCandidate, candidate.ticket == ticket, candidate.epoch == documentEpoch,
        MarkdownHost.shared.sessions[session.id] == nil else { throw MarkdownError.invalid }
      Self.visible.removeValue(forKey:session.id)
      session.onExternalChange = nil
      documentEpoch += 1; self.session = candidate.session; treeCandidate = nil; treeCommitted = ticket
      treeFollowAfterCancel = false
      Self.visible[self.session.id] = WeakMarkdownController(self)
      self.session.onExternalChange = { [weak self] in self?.notify("external-change") }
      resourceGeneration = -1; synchronizeResources()
      await tree.follow(current?.url)
      return try await perform("bootstrap",payload:nil)
    case "tree-cancel-open":
      guard let ticket = payload as? String else { throw MarkdownError.invalid }
      if treeCandidate?.ticket == ticket { await cancelTreeCandidate() }
      return NSNull()
    case "new": await presentDocument(); return NSNull()
    case "open":
      let urls = await pick([UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText], multiple: true)
      for url in urls { await presentDocument(url: url) }
      return NSNull()
    case "save-as":
      guard let folder = await pick([.folder]).first, let name = await filename(current?.url.lastPathComponent ?? "Untitled.md"),
        started == documentEpoch, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return ["kind": "cancelled"] }
      let url = folder.appendingPathComponent(name)
      guard MarkdownCore.accepts(url) else { return ["kind": "blocked"] }
      let access = folder.startAccessingSecurityScopedResource()
      defer { if access { folder.stopAccessingSecurityScopedResource() } }
      if FileManager.default.fileExists(atPath: url.path), !(await confirm("markdownOverwriteConfirm")) { return ["kind": "cancelled"] }
      guard started == documentEpoch else { throw MarkdownError.invalid }
      do {
        let grant = try await MarkdownHost.shared.authorize(session, url: url, scope: folder, reserved: true, format: MarkdownCore.dictionary(payload))
        return ["kind": "selected", "target": grant.target]
      } catch MarkdownError.occupied(let owner) { Self.focus(owner); return ["kind": "occupied"] }
      catch { return ["kind": "blocked"] }
    case "cancel-save-as":
      if let handle = payload as? String { await MarkdownHost.shared.cancelCandidate(handle, sessionID: session.id) }
      return NSNull()
    case "authorize-resources":
      let generation = session.generation
      guard let folder = await pick([.folder]).first else { return false }
      let access = folder.startAccessingSecurityScopedResource()
      guard started == documentEpoch, generation == session.generation, let grant = try? MarkdownDirectoryGrant(folder) else {
        if access { folder.stopAccessingSecurityScopedResource() }
        return false
      }
      synchronizeResources()
      if access { resourceScopes.append(folder) }
      resourceDirectories.append(grant)
      return true
    case "resource":
      guard let reference = payload as? String, let token = try await resource(reference) else { return NSNull() }
      return "\(MarkdownCore.scheme)://\(containerID)/resource/\(token)"
    case "insert-image": return await insertImage()
    case "link":
      guard let raw = payload as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
        url.user == nil, url.password == nil else { throw MarkdownError.invalid }
      await UIApplication.shared.open(url)
      return NSNull()
    case "preferences":
      let patch = try MarkdownCore.dictionary(payload)
      let next = try MarkdownHost.shared.preferences(patch:patch)
      preferences = next
      preferencesBlocked = false
      applyTheme()
      return next
    case "confirm":
      guard let operation = payload as? String, let key = ["reload": "markdownReloadConfirm", "overwrite": "markdownOverwriteConfirm", "save-as": "markdownRelativeLinks"][operation] else { return false }
      return await confirm(key)
    case "confirm-close":
      return await choice("markdownCloseDraft", keys: ["markdownKeepDraft", "saveAs", "cancel"], values: ["keep", "save-as", "cancel"])
    case "recoveries":
      let records = try MarkdownHost.shared.recoveries()
      if MarkdownHost.shared.hasCorruptRecoveries { showError(message: "markdownCorruptRecovery") }
      return records
    case "recover":
      guard let id = payload as? String else { throw MarkdownError.invalid }
      let recovered = try await MarkdownHost.shared.restore(id)
      navigationController?.pushViewController(MarkdownViewController(session: recovered), animated: true)
      return NSNull()
    case "discard-recovery":
      guard let id = payload as? String else { throw MarkdownError.invalid }
      if await confirm("discardUnsavedChanges") { try MarkdownHost.shared.discard(id) }
      return NSNull()
    case "state":
      guard (payload as? MarkdownJSON)?["sessionId"] as? String == session.id else { throw MarkdownError.invalid }
      return NSNull()
    case "response":
      if let response = payload as? MarkdownJSON, let id = response["id"] as? String, let accepted = response["accepted"] as? Bool { replies.removeValue(forKey: id)?(accepted) }
      return NSNull()
    default: throw MarkdownError.invalid
    }
  }

  private var current: MarkdownHost.Grant? { session.current.flatMap { session.grants[$0] } }

  private var treeFollowAfterCancel = false
  private func cancelTreeCandidate() async {
    guard let candidate = treeCandidate else { return }
    treeCandidate = nil
    _ = try? await MarkdownHost.shared.request("releaseSession",payload:["sessionId":candidate.session.id,"targetGeneration":candidate.session.generation],sessionID:candidate.session.id)
    if treeFollowAfterCancel {
      treeFollowAfterCancel = false
      await tree.follow(current?.url, authorizedDirectory:current?.scope, afterSaveAs:true)
      notify("tree-change")
    }
  }
  private func prepareTreeOpen(_ location: MarkdownJSON) async -> MarkdownJSON {
    guard !treeOpening, !closing, treeCandidate == nil else { return MarkdownCore.failure(MarkdownError.invalid) }
    treeOpening = true
    defer { treeOpening = false }
    let epoch = documentEpoch
    var created: MarkdownHost.Session?
    do {
      let (url, scope) = try tree.file(location)
      if url == current?.url { return ["kind":"current"] }
      let candidate = try await MarkdownHost.shared.create(url:url,scope:scope)
      created = candidate
      let checked = try tree.file(location)
      guard epoch == documentEpoch, !closing, checked.0 == url else { throw MarkdownError.invalid }
      let ticket = MarkdownCore.newID()
      guard ticket != treeCommitted else { throw MarkdownError.invalid }
      treeCandidate = (ticket,candidate,epoch)
      return ["kind":"ready","ticket":ticket,"sessionId":candidate.id]
    } catch {
      if let candidate = created {
        _ = try? await MarkdownHost.shared.request("releaseSession",payload:["sessionId":candidate.id,"targetGeneration":candidate.generation],sessionID:candidate.id)
      }
      if case MarkdownError.occupied(let owner) = error { Self.focus(owner); return ["kind":"occupied"] }
      return MarkdownCore.failure(error)
    }
  }

  func presentDocument(url: URL? = nil) async {
    do {
      let created = try await MarkdownHost.shared.create(url: url)
      navigationController?.pushViewController(MarkdownViewController(session: created), animated: true)
    } catch MarkdownError.occupied(let owner) { Self.focus(owner) }
    catch { showError() }
  }
  static func focus(_ id: String) {
    guard let controller = visible[id]?.value else { return }
    guard let navigation = controller.navigationController else { return }
    // 聚焦既有文档不能 pop 掉其上的其他会话；只调整可见顺序，保留每个编辑器。
    navigation.setViewControllers(navigation.viewControllers.filter { $0 !== controller } + [controller], animated: true)
  }

  private func pick(_ types: [UTType], multiple: Bool = false) async -> [URL] {
    guard pickerCompletion == nil, presentedViewController == nil else { return [] }
    return await withCheckedContinuation { continuation in
      pickerCompletion = { continuation.resume(returning: $0) }
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
      picker.allowsMultipleSelection = multiple
      picker.delegate = self
      present(picker, animated: true)
    }
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let completion = pickerCompletion
    pickerCompletion = nil
    controller.dismiss(animated: true) { completion?(urls) }
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let completion = pickerCompletion
    pickerCompletion = nil
    controller.dismiss(animated: true) { completion?([]) }
  }
  private func filename(_ proposed: String) async -> String? {
    guard presentedViewController == nil else { return nil }
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: text("saveAs"), message: nil, preferredStyle: .alert)
      alert.addTextField { $0.text = proposed; $0.autocapitalizationType = .none }
      alert.addAction(UIAlertAction(title: text("cancel"), style: .cancel) { _ in continuation.resume(returning: nil) })
      alert.addAction(UIAlertAction(title: text("save"), style: .default) { _ in continuation.resume(returning: alert.textFields?.first?.text) })
      present(alert, animated: true)
    }
  }
  private func choice(_ message: String, keys: [String], values: [String]) async -> String {
    guard presentedViewController == nil else { return values.last! }
    return await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: text("markdownEditor"), message: text(message), preferredStyle: .alert)
      for index in keys.indices {
        alert.addAction(UIAlertAction(title: text(keys[index]), style: index == keys.count - 1 ? .cancel : .default) { _ in continuation.resume(returning: values[index]) })
      }
      present(alert, animated: true)
    }
  }
  private func confirm(_ message: String) async -> Bool { await choice(message, keys: ["confirm", "cancel"], values: ["yes", "no"]) == "yes" }
  private func showError(message: String = "markdownError") {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: text("markdownEditor"), message: text(message), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: text("confirm"), style: .default))
    present(alert, animated: true)
  }

  private func resource(_ reference: String) async throws -> String? {
    let epoch = documentEpoch
    synchronizeResources()
    let generation = session.generation
    guard reference.count < 8192, let current = current, let decoded = reference.components(separatedBy: "#")[0].components(separatedBy: "?")[0].removingPercentEncoding,
      !decoded.hasPrefix("/"), !decoded.hasPrefix("\\"), !decoded.contains(":"), !decoded.contains("\0") else { return nil }
    let url = current.url.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
    let directory = try resourceDirectories.first { grant in try grant.validate(); return grant.contains(url) }
    guard imageFiles[url] != nil || directory != nil, Self.imageTypes[url.pathExtension.lowercased()] != nil else { return nil }
    let snapshot = try await Task.detached(priority:.userInitiated) { try MarkdownCore.read(url, maximum:32 * 1024 * 1024) }.value
    synchronizeResources()
    guard epoch == documentEpoch, generation == session.generation else { return nil }
    if let identity = imageFiles[url], identity != snapshot.physicalIdentity { throw MarkdownError.identityChanged }
    if let entry = resources.first(where: { $0.value.url == url && $0.value.identity == snapshot.physicalIdentity }) {
      try validateResource(entry.value)
      return entry.key
    }
    guard resources.count < 1024 else { return nil }
    let token = MarkdownCore.token()
    let grant = MarkdownResourceGrant(token:token, url:url, identity:snapshot.physicalIdentity,
      generation:session.generation, directory:imageFiles[url] == nil ? directory : nil)
    try grant.validate(generation:session.generation)
    resources[token] = grant
    return token
  }
  private func synchronizeResources() {
    guard resourceGeneration != session.generation else { return }
    resourceGeneration = session.generation
    resources.removeAll()
    imageFiles.removeAll()
    resourceDirectories.removeAll()
    resourceScopes.forEach { $0.stopAccessingSecurityScopedResource() }
    resourceScopes.removeAll()
  }
  func validateResource(_ grant: MarkdownResourceGrant) throws {
    synchronizeResources()
    guard resources[grant.token]?.identity == grant.identity else { throw MarkdownError.invalid }
    do { try grant.validate(generation:session.generation) }
    catch { invalidateResource(grant); throw error }
  }
  func invalidateResource(_ grant: MarkdownResourceGrant) { resources.removeValue(forKey:grant.token) }
  static func inside(_ root: URL, _ file: URL) -> Bool { file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") }

  func protocolResource(_ request: URLRequest) throws -> (url: URL, type: String, identity: String?, maximum: Int, grant: MarkdownResourceGrant?) {
    guard request.httpMethod == "GET", let url = request.url, url.scheme == MarkdownCore.scheme, url.host == containerID else { throw MarkdownError.invalid }
    if url.path.hasPrefix("/resource/") {
      let token = String(url.path.dropFirst("/resource/".count))
      guard let resource = resources[token] else { throw MarkdownError.invalid }
      try validateResource(resource)
      guard let type = Self.imageTypes[resource.url.pathExtension.lowercased()] else { throw MarkdownError.invalid }
      return (resource.url, type, resource.identity, 32 * 1024 * 1024, resource)
    }
    // A single exact script alias reuses the packaged parser without exposing the app tree.
    let sharedLute = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/vditor/dist/js/lute/lute.min.js"
    let root = (sharedLute ? Self.appDirectory : Self.assets).resolvingSymlinksInPath()
    let relative = sharedLute ? "stage/protyle/js/lute/lute.min.js" : String(url.path.dropFirst())
    let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    guard Self.inside(root, file) else { throw MarkdownError.invalid }
    let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
      "json": "application/json", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "svg": "image/svg+xml"]
    return (file, types[file.pathExtension] ?? Self.imageTypes[file.pathExtension] ?? "application/octet-stream", nil, 64 * 1024 * 1024, nil)
  }

  private func insertImage() async -> MarkdownJSON {
    let epoch = documentEpoch
    let generation = session.generation
    guard let target = current, let source = await pick([.image]).first,
      let folder = await pick([.folder]).first, let name = await filename(source.lastPathComponent),
      !name.contains("/"), !name.contains("\\"), Self.imageTypes[source.pathExtension.lowercased()] != nil,
      Self.imageTypes[name.components(separatedBy: ".").last?.lowercased() ?? ""] != nil else { return ["kind": "cancelled"] }
    let sourceAccess = source.startAccessingSecurityScopedResource()
    var folderAccess = folder.startAccessingSecurityScopedResource()
    defer { if sourceAccess { source.stopAccessingSecurityScopedResource() }; if folderAccess { folder.stopAccessingSecurityScopedResource() } }
    let destination = folder.appendingPathComponent(name).standardizedFileURL
    do {
      guard let sourceVolume = try target.url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
        let destinationVolume = try folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
        sourceVolume.isEqual(destinationVolume) else { throw MarkdownError.unavailable }
      let base = target.url.deletingLastPathComponent().standardizedFileURL.pathComponents
      let saved = destination.pathComponents
      var common = 0
      while common < min(base.count, saved.count) && base[common] == saved[common] { common += 1 }
      let components = Array(repeating: "..", count: base.count - common) + Array(saved.dropFirst(common))
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      let copied = try await MarkdownCore.importImage(source: source, destination: destination)
      guard epoch == documentEpoch, generation == session.generation else { return ["kind":"blocked"] }
      synchronizeResources()
      imageFiles[destination.resolvingSymlinksInPath().standardizedFileURL] = copied.physicalIdentity
      if folderAccess { resourceScopes.append(folder); folderAccess = false }
      return ["kind": "inserted", "reference": components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")]
    } catch { return ["kind": "blocked"] }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, url.scheme == MarkdownCore.scheme, url.host == containerID,
      url.path == "/index.html", navigationAction.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
    decisionHandler(.allow)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard !rendererTerminated else { return }
    rendererTerminated = true
    replies.values.forEach { $0(false) }
    replies.removeAll()
    Task {
      do {
        await cancelTreeCandidate()
        let recovered = try await MarkdownHost.shared.recoverTerminatedRenderer(session)
        let replacement = MarkdownViewController(session:recovered)
        replacement.initialError = "markdownError"
        Self.visible.removeValue(forKey:session.id)
        navigationController?.setViewControllers(navigationController!.viewControllers.map { $0 === self ? replacement : $0 }, animated:false)
      } catch { showError() }
    }
  }
}

final class WeakMarkdownController {
  weak var value: MarkdownViewController?
  init(_ value: MarkdownViewController) { self.value = value }
}
final class WeakMarkdownScriptHandler: NSObject, WKScriptMessageHandler {
  weak var delegate: WKScriptMessageHandler?
  init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    delegate?.userContentController(userContentController, didReceive: message)
  }
}

final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
  weak var owner: MarkdownViewController?
  private var active: Set<ObjectIdentifier> = []
  private let reads = DispatchQueue(label:"org.b3log.siyuan.markdown.resources", qos:.userInitiated)
  init(owner: MarkdownViewController) { self.owner = owner }
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let owner = self.owner else { return }
      let id = ObjectIdentifier(urlSchemeTask)
      self.active.insert(id)
      do {
        let resource = try owner.protocolResource(urlSchemeTask.request)
        self.reads.async {
          let result = Result { () throws -> Data in
            if let grant = resource.grant { try grant.validate(generation:grant.generation) }
            guard resource.url.resolvingSymlinksInPath() == resource.url else { throw MarkdownError.identityChanged }
            let snapshot = try MarkdownCore.read(resource.url, maximum:resource.maximum)
            guard resource.identity == nil || resource.identity == snapshot.physicalIdentity else { throw MarkdownError.identityChanged }
            return snapshot.data
          }
          DispatchQueue.main.sync {
            guard self.active.remove(id) != nil, let url = urlSchemeTask.request.url else { return }
            switch result {
            case .success(let bytes):
              do { if let grant = resource.grant { try owner.validateResource(grant) } }
              catch { urlSchemeTask.didFailWithError(error); return }
              let policy = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
              let response = HTTPURLResponse(url:url, statusCode:200, httpVersion:"HTTP/1.1", headerFields:["Content-Type":resource.type, "Content-Security-Policy":policy, "X-Content-Type-Options":"nosniff", "Cache-Control":"no-store"])!
              urlSchemeTask.didReceive(response)
              if url.path == "/index.html", let html = String(data: bytes, encoding: .utf8) {
                urlSchemeTask.didReceive(Data(MarkdownCore.initialPage(html, dark: owner.effectiveDark).utf8))
              } else { urlSchemeTask.didReceive(bytes) }
              urlSchemeTask.didFinish()
            case .failure(let error):
              if let grant = resource.grant { owner.invalidateResource(grant) }
              urlSchemeTask.didFailWithError(error)
            }
          }
        }
      } catch {
        if self.active.remove(id) != nil { urlSchemeTask.didFailWithError(error) }
      }
    }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    DispatchQueue.main.async { [weak self] in self?.active.remove(ObjectIdentifier(urlSchemeTask)) }
  }
}
