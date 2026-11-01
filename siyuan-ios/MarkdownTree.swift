import Foundation

private final class MarkdownDirectoryPresenter: NSObject, NSFilePresenter {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue = {
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility; return queue
  }()
  private let changed: () -> Void
  init(_ url: URL, changed: @escaping () -> Void) { presentedItemURL = url; self.changed = changed }
  func presentedItemDidChange() { DispatchQueue.main.async(execute:changed) }
  func presentedSubitemDidAppear(at url: URL) { presentedItemDidChange() }
  func presentedSubitemDidChange(at url: URL) { presentedItemDidChange() }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { presentedItemDidChange() }
  func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) { presentedItemDidChange(); completionHandler(nil) }
}

// 目录授权属于编辑容器，不绑定到单个文档，也不扩展图片读取权限。
@MainActor final class MarkdownTree {
  struct Node {
    let id: String
    let url: URL
    let identity: String
    let directory: Bool
    let parents: [String]
    var json: MarkdownJSON { ["id":id, "name":url.lastPathComponent, "kind":directory ? "directory" : "file"] }
  }
  private let storage: URL
  private var grant: MarkdownDirectoryGrant?
  private var scope: URL?
  private var scoped = false
  private var rootID = ""
  private var rootName = ""
  private var nodes: [String:Node] = [:]
  private var signatures: [String:String] = [:]
  private var manual = false
  private var epoch = 0
  private var unavailable = false
  private var current: URL?
  private(set) var generation = 0
  private var width = 240
  private var visible = true
  private var expanded: [String] = []
  private var presenters: [String:MarkdownDirectoryPresenter] = [:]
  var onChange: (() -> Void)?
  var observing = true { didSet { updatePresenters() } }

  init(storage: URL) { self.storage = storage }
  deinit {
    presenters.values.forEach { NSFileCoordinator.removeFilePresenter($0) }
    if scoped { scope?.stopAccessingSecurityScopedResource() }
  }
  private func updatePresenters() {
    let ids = observing && grant != nil ? Set([rootID] + expanded) : []
    for (id, presenter) in presenters where !ids.contains(id) { NSFileCoordinator.removeFilePresenter(presenter); presenters.removeValue(forKey:id) }
    for id in ids {
      guard presenters[id] == nil, let node = nodes[id], node.directory else { continue }
      let presenter = MarkdownDirectoryPresenter(node.url) { [weak self] in self?.onChange?() }
      NSFileCoordinator.addFilePresenter(presenter); presenters[id] = presenter
    }
  }

  nonisolated private static func id(_ text: String) -> String { MarkdownCore.hash(Data(text.utf8)) }
  nonisolated private static func validID(_ value: String) -> Bool { value.range(of:"^[a-f0-9]{64}$", options:.regularExpression) != nil }
  private static func record(at url: URL) throws -> MarkdownJSON {
    guard FileManager.default.fileExists(atPath:url.path) else { return ["version":1,"width":240,"visible":true,"roots":[]] }
    let value = try MarkdownCore.dictionary(JSONSerialization.jsonObject(with:Data(contentsOf:url)))
    guard value["version"] as? Int == 1, let width = value["width"] as? Int, (180...480).contains(width),
      value["visible"] is Bool, let roots = value["roots"] as? [MarkdownJSON], roots.count <= 16 else { throw MarkdownError.invalid }
    for root in roots {
      guard let id = root["id"] as? String, validID(id), let expanded = root["expanded"] as? [String], expanded.count <= 256,
        expanded.allSatisfy(validID), root["bookmark"] is String, root["scopeIdentity"] is String else { throw MarkdownError.invalid }
    }
    return value
  }
  private func loadView() throws {
    let record = try Self.record(at:storage)
    width = record["width"] as? Int ?? 240
    visible = record["visible"] as? Bool ?? true
    expanded = (record["roots"] as? [MarkdownJSON])?.first { $0["id"] as? String == rootID }?["expanded"] as? [String] ?? []
    updatePresenters()
  }
  func saveView(_ patch: MarkdownJSON) throws {
    var record = try Self.record(at:storage) // 损坏或未知记录保持原件，不能被默认值覆盖。
    if let value = patch["width"] { let number = try MarkdownCore.counter(value); guard (180...480).contains(number) else { throw MarkdownError.invalid }; record["width"] = number }
    if let value = patch["visible"] { guard let flag = value as? Bool else { throw MarkdownError.invalid }; record["visible"] = flag }
    var roots = record["roots"] as? [MarkdownJSON] ?? []
    if patch["expanded"] != nil {
      guard patch["rootId"] as? String == rootID, try MarkdownCore.counter(patch["generation"]) == generation,
        let values = patch["expanded"] as? [String], values.count <= 256, values.allSatisfy(Self.validID) else { throw MarkdownError.invalid }
      var item = roots.first { $0["id"] as? String == rootID } ?? ["id":rootID,"bookmark":"","scopeIdentity":""]
      item["expanded"] = Array(Set(values)).sorted()
      roots.removeAll { $0["id"] as? String == rootID }; roots.insert(item, at:0)
      record["roots"] = Array(roots.prefix(16))
    }
    try write(record)
    try loadView()
  }
  private func write(_ value: MarkdownJSON) throws {
    try MarkdownCore.jsonData(value).write(to:storage, options:.atomic)
    let file = try FileHandle(forWritingTo:storage)
    try MarkdownCore.synchronizeAndClose({ try file.synchronize() }, close:{ try file.close() })
  }

  func follow(_ url: URL?, authorizedDirectory: URL? = nil) async {
    current = url?.standardizedFileURL
    if let url = current, let grant = grant, grant.contains(url) { return }
    if manual { return }
    epoch += 1
    let ticket = epoch
    reset()
    guard let url = current else { return }
    rootName = url.deletingLastPathComponent().lastPathComponent
    unavailable = true
    do {
      try loadView()
      if let selected = authorizedDirectory, url.path.hasPrefix(selected.standardizedFileURL.path + "/") {
        try await install(url.deletingLastPathComponent(),scope:selected,manual:false,ticket:ticket)
        return
      }
      // 单文件授权不包含父目录。仅恢复显式选过的目录书签，或使用应用自己的沙箱。
      let record = try Self.record(at:storage)
      for item in record["roots"] as? [MarkdownJSON] ?? [] {
        guard let encoded = item["bookmark"] as? String, let data = Data(base64Encoded:encoded) else { continue }
        var stale = false
        guard let scope = try? URL(resolvingBookmarkData:data, options:.withoutUI, relativeTo:nil, bookmarkDataIsStale:&stale), !stale,
          url.path.hasPrefix(scope.standardizedFileURL.path + "/") else { continue }
        let access = scope.startAccessingSecurityScopedResource()
        let identity = try? MarkdownCore.directoryIdentity(scope)
        if access { scope.stopAccessingSecurityScopedResource() }
        guard identity == item["scopeIdentity"] as? String else { continue }
        try await install(url.deletingLastPathComponent(), scope:scope, manual:false, ticket:ticket)
        return
      }
      let home = URL(fileURLWithPath:NSHomeDirectory(), isDirectory:true).standardizedFileURL.path
      if url.path.hasPrefix(home + "/") { try await install(url.deletingLastPathComponent(), scope:url.deletingLastPathComponent(), manual:false, ticket:ticket) }
    } catch { unavailable = true }
  }
  private func reset() {
    if scoped { scope?.stopAccessingSecurityScopedResource() }
    scope = nil; scoped = false; grant = nil; rootID = ""; nodes.removeAll(); signatures.removeAll(); expanded = []; generation += 1
    updatePresenters()
  }
  func choose(_ url: URL) async throws {
    epoch += 1
    try await install(url, scope:url, manual:true, ticket:epoch)
  }
  private func install(_ root: URL, scope: URL, manual: Bool, ticket: Int) async throws {
    let access = scope.startAccessingSecurityScopedResource()
    do {
      let captured = try MarkdownDirectoryGrant(root)
      let identity = Self.id(captured.canonical.path + "\0" + captured.identity)
      let rootNode = Node(id:identity,url:captured.canonical,identity:captured.identity,directory:true,parents:[])
      let initial = try await Self.children(captured, directory:root, rootID:identity, parents:[rootNode])
      guard epoch == ticket else { throw MarkdownError.invalid }
      var record = try Self.record(at:storage)
      var roots = record["roots"] as? [MarkdownJSON] ?? []
      let previous = roots.first { $0["id"] as? String == identity }
      let bookmark = (try? scope.bookmarkData(options:.minimalBookmark, includingResourceValuesForKeys:nil, relativeTo:nil).base64EncodedString()) ?? ""
      roots.removeAll { $0["id"] as? String == identity }
      roots.insert(["id":identity,"bookmark":bookmark,"scopeIdentity":try MarkdownCore.directoryIdentity(scope),"expanded":previous?["expanded"] ?? []],at:0)
      record["roots"] = Array(roots.prefix(16)); try write(record)
      reset(); self.grant = captured; self.scope = scope; scoped = access; self.manual = manual
      rootID = identity; rootName = root.lastPathComponent; unavailable = false
      nodes[rootID] = Node(id:rootID,url:captured.canonical,identity:captured.identity,directory:true,parents:[])
      for node in initial { nodes[node.id] = node }
      signatures[rootID] = Self.signature(initial)
      try loadView()
    } catch { if access { scope.stopAccessingSecurityScopedResource() }; throw error }
  }
  nonisolated private static func signature(_ nodes: [Node]) -> String { nodes.map { $0.id + $0.url.lastPathComponent }.joined(separator:"\0") }
  nonisolated private static func children(_ grant: MarkdownDirectoryGrant, directory: URL, rootID: String, parents: [Node]) async throws -> [Node] {
    try await Task.detached(priority:.utility) {
      try grant.validate()
      for node in parents { try validate(node, grant:grant) }
      var result: Result<[Node], Error> = .failure(MarkdownError.unavailable)
      var coordinationError: NSError?
      NSFileCoordinator().coordinate(readingItemAt:directory, options:.withoutChanges, error:&coordinationError) { coordinated in
        result = Result {
          guard coordinated.standardizedFileURL == directory.standardizedFileURL else { throw MarkdownError.identityChanged }
          let files = try FileManager.default.contentsOfDirectory(at:coordinated, includingPropertiesForKeys:nil)
          guard files.count <= 10_000 else { throw MarkdownError.size }
          var nodes: [Node] = []
          for file in files {
            guard file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else { continue }
            // 单个子项消失或撤权不影响仍可用的父目录；交付前继续复验目录链。
            guard let attributes = try? FileManager.default.attributesOfItem(atPath:file.path) else { continue }
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular && MarkdownCore.accepts(file) else { continue }
            guard let identity = try? (type == .typeDirectory ? MarkdownCore.directoryIdentity(file) : MarkdownCore.fileIdentity(file)) else { continue }
            if type == .typeDirectory && (identity == grant.identity || parents.contains { $0.identity == identity }) { continue }
            let relative = file.path.dropFirst(grant.canonical.path.count)
            let id = Self.id(rootID + "\0" + String(relative) + "\0" + identity)
            nodes.append(Node(id:id,url:file,identity:identity,directory:type == .typeDirectory,parents:parents.map(\.id)))
          }
          try grant.validate()
          for node in parents { try validate(node, grant:grant) }
          return nodes.sorted { a,b in
            if a.directory != b.directory { return a.directory }
            let order = a.url.lastPathComponent.compare(b.url.lastPathComponent, options:[.numeric,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
          }
        }
      }
      if let error = coordinationError { throw error }
      return try result.get()
    }.value
  }
  nonisolated private static func validate(_ node: Node, grant: MarkdownDirectoryGrant) throws {
    guard node.url == grant.canonical || grant.contains(node.url), node.url.resolvingSymlinksInPath().standardizedFileURL == node.url.standardizedFileURL,
      try (node.directory ? MarkdownCore.directoryIdentity(node.url) : MarkdownCore.fileIdentity(node.url)) == node.identity else { throw MarkdownError.identityChanged }
  }
  private func location(_ value: MarkdownJSON) throws -> Node {
    guard value["rootId"] as? String == rootID, try MarkdownCore.counter(value["generation"]) == generation,
      let id = value["nodeId"] as? String, let node = nodes[id], let grant = grant else { throw MarkdownError.invalid }
    try grant.validate(); try Self.validate(node,grant:grant)
    for id in node.parents { guard let ancestor = nodes[id] else { throw MarkdownError.invalid }; try Self.validate(ancestor,grant:grant) }
    return node
  }
  func file(_ value: MarkdownJSON) throws -> (URL, URL) {
    let node = try location(value)
    guard !node.directory, let scope = scope else { throw MarkdownError.invalid }
    return (node.url, scope)
  }
  func list(_ value: MarkdownJSON) async -> MarkdownJSON {
    do {
      let node = try location(value)
      guard node.directory, node.parents.count < 64, let grant = grant else { throw MarkdownError.invalid }
      let ticket = generation
      let parents = node.parents.compactMap { nodes[$0] } + [node]
      let entries = try await Self.children(grant,directory:node.url,rootID:rootID,parents:parents)
      guard ticket == generation else { throw MarkdownError.invalid }
      guard nodes.count + entries.filter({ nodes[$0.id] == nil }).count <= 10_000 else { throw MarkdownError.size }
      // 交付新列表前清除已失效的直接子节点及其后代。
      let valid = Set(entries.map(\.id))
      let removed = Set(nodes.values.filter { $0.parents.last == node.id && !valid.contains($0.id) }.map(\.id))
      nodes = nodes.filter { !removed.contains($0.key) && !$0.value.parents.contains(where:removed.contains) }
      for child in entries { nodes[child.id] = child }
      updatePresenters()
      signatures[node.id] = Self.signature(entries)
      return ["kind":"listed","rootId":rootID,"generation":generation,"nodeId":node.id,"entries":entries.map(\.json)]
    } catch { return MarkdownCore.failure(error) }
  }
  func state() async -> MarkdownJSON {
    do { try loadView() } catch { return blockedState(error) }
    var result: MarkdownJSON = ["kind":grant == nil ? (unavailable ? "permission-required" : "empty") : "ready",
      "generation":generation,"expanded":expanded,"width":width,"visible":visible]
    if !rootName.isEmpty { result["rootName"] = rootName }
    guard let grant = grant else { return result }
    let ticket = generation
    do {
      try grant.validate(); result["rootId"] = rootID
      if let current = current, grant.contains(current) {
        let relative = current.path.dropFirst(grant.canonical.path.count + 1).split(separator:"/")
        var parent = rootID
        var path = [rootID]
        var resolved = true
        for name in relative.dropLast() {
          let listed = await list(["rootId":rootID,"generation":ticket,"nodeId":parent])
          guard listed["kind"] as? String == "listed" else {
            if parent == rootID { result["kind"] = "blocked"; result["error"] = listed["error"] }
            resolved = false; break
          }
          guard let next = nodes.values.first(where: { $0.parents.last == parent && $0.directory && $0.url.lastPathComponent == String(name) }) else { resolved = false; break }
          parent = next.id; path.append(parent)
        }
        result["currentPath"] = path
        if resolved {
          let listed = await list(["rootId":rootID,"generation":ticket,"nodeId":parent])
          if listed["kind"] as? String == "listed" { result["currentNodeId"] = nodes.values.first(where: { $0.url == current })?.id }
          else if parent == rootID { result["kind"] = "blocked"; result["error"] = listed["error"] }
        }
      }
      try grant.validate()
      guard ticket == generation else { throw MarkdownError.invalid }
      return result
    } catch { return blockedState(error) }
  }
  private func blockedState(_ error: Error) -> MarkdownJSON {
    var value = MarkdownCore.failure(error)
    value["generation"] = generation; value["expanded"] = expanded; value["width"] = width; value["visible"] = visible
    return value
  }
  func poll() async -> Bool {
    guard let grant = grant else { return false }
    let ticket = generation
    do {
      for id in Set([rootID] + expanded) {
        guard let node = nodes[id], node.directory else { continue }
        let values = try await Self.children(grant,directory:node.url,rootID:rootID,parents:node.parents.compactMap { nodes[$0] } + [node])
        guard ticket == generation else { return false }
        if signatures[id] != Self.signature(values) { return true }
      }
    } catch { return ticket == generation }
    return false
  }
}
