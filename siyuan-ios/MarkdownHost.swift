#if canImport(UIKit)
import UIKit

@MainActor final class MarkdownHost {
  static let shared = MarkdownHost()

  final class Grant {
    let handle = MarkdownCore.newID()
    let identity = MarkdownCore.newID()
    let owner: String
    let document: MarkdownDocument
    let url: URL
    let scope: URL
    let scoped: Bool
    let bookmark: Data?
    var aliases: Set<String>
    var baseline: String
    var physicalIdentity: String
    var format: MarkdownJSON
    var reservation: String?
    var prepared: String?
    var preparedFingerprint: String?
    var operationID: String?
    var written = false
    var uncertain: MarkdownJSON?
    let initialContent: String
    init(owner: String, url: URL, scope: URL, document: MarkdownDocument, snapshot: MarkdownCore.Snapshot?, format: MarkdownJSON) {
      self.owner = owner
      self.url = url
      self.scope = scope
      scoped = scope.startAccessingSecurityScopedResource()
      bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      self.document = document
      baseline = snapshot?.baseline ?? "missing"
      physicalIdentity = snapshot?.physicalIdentity ?? "missing"
      self.format = format
      initialContent = (try? snapshot.map { try MarkdownCore.decode($0.data).0 }) ?? ""
      aliases = ["path:" + url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()]
      if let snapshot = snapshot { aliases.insert("file:" + snapshot.physicalIdentity) }
    }
    var target: MarkdownJSON {
      ["handle": handle, "identity": identity, "displayName": url.lastPathComponent, "baseline": baseline,
       "writable": FileManager.default.isWritableFile(atPath: baseline == "missing" ? url.deletingLastPathComponent().path : url.path),
       "format": format, "capabilities": ["persistentPermission": bookmark != nil, "conditionalWrite": false,
         "atomicReplace": false, "coordinatedAccess": true]]
    }
    var hostData: MarkdownJSON { ["bookmark": bookmark?.base64EncodedString() ?? "", "displayName": url.lastPathComponent] }
    func stop() { if scoped { scope.stopAccessingSecurityScopedResource() } }
  }

  final class Session {
    final class Operation {
      let fingerprint: String
      var task: Task<MarkdownJSON, Never>?
      var result: MarkdownJSON?
      init(_ fingerprint: String) { self.fingerprint = fingerprint }
    }
    let id = MarkdownCore.newID()
    var generation = 0
    var current: String?
    var initial = ""
    var format: MarkdownJSON = ["bom": false, "newline": "\n"]
    var recovered: MarkdownJSON?
    var restoredBaseline: String?
    var grants: [String: Grant] = [:]
    var operations: [String: Operation] = [:]
    var operationOrder: [String] = []
    var instanceID: String?
    var lastWriteSequence = 0
    var selecting = false
    var committedTransfers: [String: MarkdownJSON] = [:]
    var pending = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    var closing = false
    var onExternalChange: (() -> Void)?
    var durableTransfer: (operation: MarkdownJSON, generation: Int)?
    var unknownTransfer = false
    var transferring = false
    var commitTasks: [String: Task<MarkdownJSON, Never>] = [:]
    var commitFingerprints: [String: String] = [:]
    var commitOrder: [String] = []
    func settled() {
      pending -= 1
      if pending == 0 { let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() } }
    }
    func idle() async {
      if pending == 0 { return }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  private(set) var sessions: [String: Session] = [:]
  private var claims: [String: String] = [:]
  let directory: URL
  private var recovery: MarkdownRecoveryStore?
  init(directory providedDirectory: URL? = nil, recovery providedRecovery: MarkdownRecoveryStore? = nil) {
    directory = providedDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MarkdownEditor", isDirectory: true)
    recovery = providedRecovery ?? (try? MarkdownRecoveryStore(directory: directory.appendingPathComponent("recovery", isDirectory: true)))
    var root = directory
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    try? root.setResourceValues(excluded)
  }
  private func store() throws -> MarkdownRecoveryStore {
    guard let store = recovery else { throw MarkdownError.unavailable }
    return store
  }

  func preferences(patch: MarkdownJSON? = nil) throws -> MarkdownJSON {
    _ = try store()
    return try MarkdownCore.preferences(at:directory.appendingPathComponent("preferences.json"), patch:patch)
  }

  func create(url: URL? = nil, scope: URL? = nil) async throws -> Session {
    let session = Session()
    guard sessions[session.id] == nil, try store().read(session.id) == nil else { throw MarkdownError.invalid }
    sessions[session.id] = session
    do {
      if let url = url {
        let grant = try await authorize(session, url: url, scope: scope ?? url, reserved: false)
        session.current = grant.handle
        session.initial = grant.initialContent
        session.format = grant.format
      }
      return session
    } catch {
      for grant in session.grants.values { await remove(grant) }
      sessions.removeValue(forKey: session.id)
      throw error
    }
  }

  func authorize(_ session: Session, url: URL, scope: URL, reserved: Bool, format: MarkdownJSON? = nil) async throws -> Grant {
    guard !session.closing, MarkdownCore.accepts(url) else { throw MarkdownError.invalid }
    if reserved {
      guard !session.selecting, !session.grants.values.contains(where: { $0.reservation != nil }) else { throw MarkdownError.invalid }
      session.selecting = true
    }
    defer { if reserved { session.selecting = false } }
    session.pending += 1
    defer { session.settled() }
    let access = scope.startAccessingSecurityScopedResource()
    defer { if access { scope.stopAccessingSecurityScopedResource() } }
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    let pathKey = "path:" + canonical.path.lowercased()
    if let owner = claims[pathKey] { throw MarkdownError.occupied(owner) }
    claims[pathKey] = session.id
    let document = MarkdownDocument(fileURL: canonical)
    do {
      var snapshot: MarkdownCore.Snapshot?
      if FileManager.default.fileExists(atPath: canonical.path) {
        guard await document.openDocument() else { throw document.lastError ?? MarkdownError.unavailable }
        snapshot = try await document.snapshot()
        if let owner = claims["file:" + snapshot!.physicalIdentity] { throw MarkdownError.occupied(owner) }
      } else if !reserved { throw MarkdownError.unavailable }
      guard !session.closing else { throw MarkdownError.invalid }
      let decoded = try snapshot.map { try MarkdownCore.decode($0.data) }
      let grant = Grant(owner: session.id, url: canonical, scope: scope, document: document,
        snapshot: snapshot, format: format ?? decoded?.1 ?? ["bom": false, "newline": "\n"])
      _ = try MarkdownCore.encode("", format: grant.format)
      if reserved { grant.reservation = MarkdownCore.newID() }
      if let reservation = grant.reservation, session.grants.values.contains(where: { $0.reservation == reservation }) { throw MarkdownError.invalid }
      guard session.grants[grant.handle] == nil else { throw MarkdownError.invalid }
      for alias in grant.aliases { claims[alias] = session.id }
      session.grants[grant.handle] = grant
      document.onExternalChange = { [weak session] in session?.onExternalChange?() }
      return grant
    } catch {
      if document.documentState != .closed { _ = await document.closeDocument() }
      if claims[pathKey] == session.id { claims.removeValue(forKey: pathKey) }
      throw error
    }
  }

  private func remove(_ grant: Grant) async {
    if grant.document.documentState != .closed { _ = await grant.document.closeDocument() }
    for alias in grant.aliases where claims[alias] == grant.owner { claims.removeValue(forKey: alias) }
    sessions[grant.owner]?.grants.removeValue(forKey: grant.handle)
    grant.stop()
  }

  private func checked(_ request: MarkdownJSON, sessionID: String, candidate: Bool = false) throws -> (Session, Grant) {
    guard request["sessionId"] as? String == sessionID, let session = sessions[sessionID], !session.closing, !session.transferring,
      let target = request["target"] as? MarkdownJSON, let handle = target["handle"] as? String,
      let grant = session.grants[handle], grant.identity == target["identity"] as? String,
      try MarkdownCore.counter(request["targetGeneration"]) == session.generation + (candidate ? 1 : 0),
      candidate ? grant.reservation != nil : session.current == handle
    else { throw MarkdownError.invalid }
    _ = try sequence(request, session: session)
    return (session, grant)
  }

  private func sequence(_ request: MarkdownJSON, session: Session) throws -> Int {
    guard let id = request["operationId"] as? String else { throw MarkdownError.invalid }
    let parts = id.components(separatedBy: ":")
    guard parts.count == 3, parts[0] == session.id, parts[1].range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
      let number = Int(parts[2]), number > 0, number <= 9_007_199_254_740_991, String(number) == parts[2],
      session.instanceID == nil || session.instanceID == parts[1] else { throw MarkdownError.invalid }
    session.instanceID = parts[1]
    return number
  }

  private func trimOperations(_ session: Session) {
    let protected = Set(session.grants.values.compactMap { $0.reservation == nil ? nil : $0.operationID })
    for id in session.operationOrder where session.operations.count > 16 {
      if let operation = session.operations[id], operation.task == nil,
        operation.result?["kind"] as? String != "indeterminate", !protected.contains(id) { session.operations.removeValue(forKey: id) }
    }
    session.operationOrder.removeAll { session.operations[$0] == nil }
  }

  func cancelCandidate(_ handle: String, sessionID: String) async {
    guard let session = sessions[sessionID], let grant = session.grants[handle], grant.reservation != nil,
      !grant.written, grant.uncertain == nil, grant.prepared == nil, grant.operationID == nil, session.pending == 0 else { return }
    await remove(grant)
  }

  func request(_ action: String, payload: MarkdownJSON, sessionID: String) async throws -> Any {
    guard payload["sessionId"] as? String == sessionID || (payload["operation"] as? MarkdownJSON)?["sessionId"] as? String == sessionID,
      let session = sessions[sessionID], !session.closing else { throw MarkdownError.invalid }
    switch action {
    case "read":
      do {
        let (_, grant) = try checked(payload, sessionID: sessionID)
        session.pending += 1
        defer { session.settled() }
        let snapshot = try await grant.document.snapshot()
        guard snapshot.physicalIdentity == grant.physicalIdentity else { throw MarkdownError.identityChanged }
        let (content, format) = try MarkdownCore.decode(snapshot.data)
        var target = grant.target
        target["baseline"] = snapshot.baseline
        target["format"] = format
        return ["kind": "read", "content": content, "target": target]
      } catch { return MarkdownCore.failure(error) }
    case "write": return await write(payload, sessionID: sessionID)
    case "reconcileWrite": return await reconcile(payload, sessionID: sessionID)
    case "reserveSaveAs":
      _ = try sequence(payload, session: session)
      guard let target = payload["target"] as? MarkdownJSON, let handle = target["handle"] as? String,
        let grant = session.grants[handle], target["identity"] as? String == grant.identity,
        let reservation = grant.reservation, let operationID = payload["operationId"] as? String,
        grant.operationID == nil || grant.operationID == operationID else { throw MarkdownError.invalid }
      grant.operationID = operationID
      return ["kind": "reserved", "reservation": ["id": reservation, "target": grant.target]]
    case "prepareSaveAs":
      let operation = try MarkdownCore.dictionary(payload["operation"])
      let (_, grant) = try checked(operation, sessionID: sessionID, candidate: true)
      guard operation["reservationId"] as? String == grant.reservation,
        let operationID = operation["operationId"] as? String, !grant.written,
        grant.operationID == operationID,
        grant.prepared == nil || grant.prepared == operationID else { throw MarkdownError.invalid }
      var record = try store().read(sessionID) ?? [:]
      if record["watermark"] == nil {
        record["watermark"] = ["sessionId": sessionID, "targetGeneration": session.generation, "revision": operation["revision"] ?? 0]
      }
      record["intent"] = payload.merging(["host": grant.hostData]) { _, new in new }
      record["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
      try store().write(sessionID, record: record)
      grant.prepared = operationID
      grant.preparedFingerprint = MarkdownCore.hash(try MarkdownCore.jsonData(operation))
      return NSNull()
    case "commitSaveAs": return await commit(payload, sessionID: sessionID)
    case "releaseSaveAs":
      guard let reservation = payload["reservationId"] as? String,
        let grant = session.grants.values.first(where: { $0.reservation == reservation }),
        grant.operationID == payload["operationId"] as? String,
        !grant.written, grant.uncertain == nil, session.pending == 0 else { throw MarkdownError.invalid }
      if var record = try store().read(sessionID) {
        record["intent"] = nil
        try store().write(sessionID, record: record)
      }
      grant.prepared = nil
      await remove(grant)
      return NSNull()
    case "putDraft":
      _ = try sequence(payload, session: session)
      var draft = payload
      let generation = try MarkdownCore.counter(draft["targetGeneration"])
      guard !session.unknownTransfer,
        generation == session.generation || generation == (session.durableTransfer?.generation ?? -1) - 1 else { throw MarkdownError.invalid }
      var grant = session.current.flatMap { session.grants[$0] }
      if let transfer = session.durableTransfer, generation == transfer.generation - 1 {
        draft["targetGeneration"] = transfer.generation
        draft["target"] = transfer.operation["target"]
        grant = (transfer.operation["target"] as? MarkdownJSON).flatMap { $0["handle"] as? String }.flatMap { session.grants[$0] }
      }
      try persistDraft(draft, session: session, grant: grant)
      return NSNull()
    case "clearDraft":
      guard !session.unknownTransfer, try MarkdownCore.counter(payload["targetGeneration"]) == session.generation,
        session.durableTransfer == nil || session.durableTransfer?.generation == session.generation else { throw MarkdownError.invalid }
      try store().clear(payload)
      // 保留最近一次代次映射，迟到的旧目标草稿仍须迁移后落盘，不能因 clear 回执丢弃新输入。
      if (session.recovered?["revision"] as? Int ?? -1) <= (payload["revision"] as? Int ?? -1) { session.recovered = nil }
      return NSNull()
    case "releaseSession":
      guard try MarkdownCore.counter(payload["targetGeneration"]) == session.generation,
        !session.grants.values.contains(where: { $0.uncertain != nil || $0.reservation != nil && ($0.written || $0.prepared != nil) })
      else { throw MarkdownError.invalid }
      session.closing = true
      await session.idle()
      guard !session.grants.values.contains(where: { $0.uncertain != nil || $0.reservation != nil && ($0.written || $0.prepared != nil) }) else {
        session.closing = false
        throw MarkdownError.invalid
      }
      for grant in Array(session.grants.values) { await remove(grant) }
      sessions.removeValue(forKey: sessionID)
      try? store().pruneCleared(active: Set(sessions.keys))
      return NSNull()
    default: throw MarkdownError.invalid
    }
  }

  private func persistDraft(_ draft: MarkdownJSON, session: Session, grant: Grant?) throws {
    if try store().put(draft, host: grant?.hostData) {
      session.initial = draft["content"] as? String ?? session.initial
      session.format = draft["format"] as? MarkdownJSON ?? session.format
      session.recovered = ["revision": draft["revision"] ?? 0, "targetGeneration": session.generation]
    }
  }

  private func write(_ request: MarkdownJSON, sessionID: String) async -> MarkdownJSON {
    do {
      let candidate = request["reservationId"] != nil
      let (session, grant) = try checked(request, sessionID: sessionID, candidate: candidate)
      guard let operationID = request["operationId"] as? String, !operationID.isEmpty,
        let baseline = request["expectedBaseline"] as? String, let content = request["content"] as? String,
        let target = request["target"] as? MarkdownJSON, let format = target["format"] as? MarkdownJSON,
        grant.uncertain == nil, !candidate || grant.reservation == request["reservationId"] as? String && grant.prepared == operationID
      else { throw MarkdownError.invalid }
      _ = try MarkdownCore.counter(request["revision"])
      let fingerprint = MarkdownCore.hash(try MarkdownCore.jsonData(request))
      if let prior = session.operations[operationID] {
        guard prior.fingerprint == fingerprint else { throw MarkdownError.invalid }
        if let task = prior.task { return await task.value }
        return prior.result ?? MarkdownCore.failure(MarkdownError.invalid)
      }
      let sequence = try sequence(request, session: session)
      guard sequence > session.lastWriteSequence, !candidate || grant.preparedFingerprint == fingerprint else { throw MarkdownError.invalid }
      guard session.pending == 0 else { throw MarkdownError.unavailable }
      let bytes = try MarkdownCore.encode(content, format: format)
      session.lastWriteSequence = sequence
      session.pending += 1
      let operation = Session.Operation(fingerprint)
      session.operations[operationID] = operation
      session.operationOrder.append(operationID)
      let task = Task { () -> MarkdownJSON in
        defer { session.settled() }
        if !candidate {
          var draft = request
          draft["format"] = format
          do { try self.persistDraft(draft, session: session, grant: grant) }
          catch { return MarkdownCore.failure(error) }
        }
        let success = await grant.document.saveSnapshot(bytes, baseline: baseline, identity: grant.physicalIdentity)
        do {
          let snapshot = try await grant.document.snapshot()
          if success && snapshot.data == bytes {
            self.accept(snapshot, grant: grant, format: format)
            let receipt: MarkdownJSON = ["kind": "committed", "baseline": snapshot.baseline, "durability": "provider"]
            return receipt
          }
          if let failure = grant.document.lastError as? MarkdownError, case .conflict(let current) = failure {
            return ["kind": "conflict", "baseline": current]
          }
          if snapshot.baseline == baseline { return MarkdownCore.failure(grant.document.lastError ?? MarkdownError.unavailable) }
        } catch { }
        grant.uncertain = request
        return MarkdownCore.failure(grant.document.lastError ?? MarkdownError.unavailable, indeterminate: true)
      }
      operation.task = task
      let result = await task.value
      operation.result = result
      operation.task = nil
      trimOperations(session)
      return result
    } catch { return MarkdownCore.failure(error) }
  }

  private func accept(_ snapshot: MarkdownCore.Snapshot, grant: Grant, format: MarkdownJSON) {
    for alias in grant.aliases where claims[alias] == grant.owner { claims.removeValue(forKey: alias) }
    grant.aliases = ["path:" + grant.url.path.lowercased(), "file:" + snapshot.physicalIdentity]
    for alias in grant.aliases { claims[alias] = grant.owner }
    grant.baseline = snapshot.baseline
    grant.physicalIdentity = snapshot.physicalIdentity
    grant.format = format
    grant.written = true
    sessions[grant.owner]?.restoredBaseline = nil
  }

  private func reconcile(_ request: MarkdownJSON, sessionID: String) async -> MarkdownJSON {
    do {
      let (session, grant) = try checked(request, sessionID: sessionID, candidate: request["reservationId"] != nil)
      guard let previous = grant.uncertain, try MarkdownCore.jsonData(previous) == MarkdownCore.jsonData(request),
        session.pending == 0, let operationID = request["operationId"] as? String,
        let content = request["content"] as? String, let target = request["target"] as? MarkdownJSON,
        let format = target["format"] as? MarkdownJSON else { throw MarkdownError.invalid }
      session.pending += 1
      defer { session.settled() }
      let snapshot = try await grant.document.snapshot()
      if snapshot.data == (try MarkdownCore.encode(content, format: format)) {
        accept(snapshot, grant: grant, format: format)
        grant.uncertain = nil
        let receipt: MarkdownJSON = ["kind": "committed", "baseline": snapshot.baseline, "durability": "provider"]
        session.operations[operationID]?.result = receipt
        trimOperations(session)
        return receipt
      }
      if snapshot.baseline == request["expectedBaseline"] as? String {
        grant.uncertain = nil
        let result = MarkdownCore.failure(MarkdownError.unavailable)
        session.operations[operationID]?.result = result
        trimOperations(session)
        return result
      }
      return MarkdownCore.failure(MarkdownError.unavailable, indeterminate: true)
    } catch { return MarkdownCore.failure(error, indeterminate: true) }
  }

  private func commit(_ request: MarkdownJSON, sessionID: String) async -> MarkdownJSON {
    guard let session = sessions[sessionID], let operation = request["operation"] as? MarkdownJSON,
      let operationID = operation["operationId"] as? String else { return MarkdownCore.failure(MarkdownError.invalid) }
    guard let bytes = try? MarkdownCore.jsonData(request) else { return MarkdownCore.failure(MarkdownError.invalid) }
    let fingerprint = MarkdownCore.hash(bytes)
    if let prior = session.commitFingerprints[operationID], prior != fingerprint { return MarkdownCore.failure(MarkdownError.invalid) }
    session.commitFingerprints[operationID] = fingerprint
    if let task = session.commitTasks[operationID] { return await task.value }
    let task = Task { await self.commitWork(request, sessionID: sessionID) }
    session.commitTasks[operationID] = task
    let result = await task.value
    session.commitTasks.removeValue(forKey: operationID)
    if session.committedTransfers[operationID] == nil && !session.grants.values.contains(where: { $0.operationID == operationID }) {
      session.commitFingerprints.removeValue(forKey:operationID)
    }
    return result
  }

  private func commitWork(_ request: MarkdownJSON, sessionID: String) async -> MarkdownJSON {
    do {
      let operation = try MarkdownCore.dictionary(request["operation"])
      guard let session = sessions[sessionID], let operationID = operation["operationId"] as? String else { throw MarkdownError.invalid }
      if let result = session.committedTransfers[operationID] { return result }
      let (_, grant) = try checked(operation, sessionID: sessionID, candidate: true)
      guard grant.written, grant.uncertain == nil, let receipt = session.operations[operationID]?.result, receipt["kind"] as? String == "committed",
        let requestedReceipt = request["receipt"] as? MarkdownJSON,
        try MarkdownCore.jsonData(receipt) == MarkdownCore.jsonData(requestedReceipt),
        try MarkdownCore.counter(request["nextTargetGeneration"]) == session.generation + 1 else { throw MarkdownError.invalid }
      session.transferring = true
      defer { session.transferring = false }
      await session.idle()
      let next = session.generation + 1
      var record = try store().read(sessionID) ?? [:]
      if var draft = record["draft"] as? MarkdownJSON {
        draft["targetGeneration"] = next
        draft["target"] = grant.target
        record["draft"] = draft
        record["watermark"] = ["sessionId": sessionID, "targetGeneration": next, "revision": draft["revision"] ?? 0]
      }
      record["host"] = grant.hostData
      record["intent"] = nil
      record["committedOperation"] = operationID
      do { try store().write(sessionID, record: record) }
      catch {
        if let saved = try? store().read(sessionID), saved["committedOperation"] as? String == operationID {
          session.durableTransfer = (operation, next)
          session.unknownTransfer = false
        } else if let saved = try? store().read(sessionID), let stamp = saved["watermark"] as? MarkdownJSON,
          (try? MarkdownCore.counter(stamp["targetGeneration"])) == session.generation {
          session.unknownTransfer = false
        } else {
          session.unknownTransfer = true
        }
        throw error
      }
      session.durableTransfer = (operation, next)
      session.unknownTransfer = false
      let old = session.current.flatMap { session.grants[$0] }
      session.current = grant.handle
      session.generation = next
      grant.reservation = nil
      grant.prepared = nil
      if let old = old { await remove(old) }
      let result: MarkdownJSON = ["kind": "committed", "target": grant.target]
      session.committedTransfers[operationID] = result
      session.commitOrder.append(operationID)
      while session.commitOrder.count > 16 {
        let retired = session.commitOrder.removeFirst()
        session.committedTransfers.removeValue(forKey: retired)
        session.commitFingerprints.removeValue(forKey: retired)
      }
      trimOperations(session)
      return result
    } catch { return MarkdownCore.failure(error, indeterminate: true) }
  }

  func recoveries() throws -> [MarkdownJSON] {
    try store().list().compactMap { record in
      guard let stamp = record["watermark"] as? MarkdownJSON, let id = stamp["sessionId"] as? String,
        sessions[id] == nil, record["draft"] != nil || record["intent"] != nil else { return nil }
      let draft = record["draft"] as? MarkdownJSON
      let target = draft?["target"] as? MarkdownJSON
      return ["id": id, "displayName": target?["displayName"] ?? "Markdown", "updatedAt": record["updatedAt"] ?? 0]
    }
  }

  var hasCorruptRecoveries: Bool { (recovery?.corruptCount ?? 0) > 0 }

  func recoverTerminatedRenderer(_ source: Session) async throws -> Session {
    guard sessions[source.id] === source, !source.closing else { throw MarkdownError.invalid }
    await source.idle()
    let record = try store().read(source.id)
    let intent = (record?["intent"] as? MarkdownJSON)?["operation"] as? MarkdownJSON
    var draft = record?["draft"] as? MarkdownJSON
    if let intent = intent, (intent["revision"] as? Int ?? -1) > (draft?["revision"] as? Int ?? -1) { draft = intent }
    let recovered = try await create()
    let content = draft?["content"] as? String ?? source.initial
    let format = draft?["format"] as? MarkdownJSON ?? (draft?["target"] as? MarkdownJSON)?["format"] as? MarkdownJSON ?? source.format
    let revision = max(1, draft?["revision"] as? Int ?? 1)
    do {
      try persistDraft(["sessionId":recovered.id, "targetGeneration":0, "revision":revision,
        "operationId":"\(recovered.id):recovery:1", "content":content,"format":format], session:recovered, grant:nil)
    } catch { sessions.removeValue(forKey:recovered.id); throw error }
    // 新副本先落盘，原记录继续保留；未决写入的旧授权仍占用，不能因 WebKit 崩溃解除。
    if !source.grants.values.contains(where: { $0.uncertain != nil || $0.reservation != nil && ($0.written || $0.prepared != nil) }) {
      _ = try await request("releaseSession", payload:["sessionId":source.id,"targetGeneration":source.generation], sessionID:source.id)
    }
    return recovered
  }

  func restore(_ id: String) async throws -> Session {
    guard sessions[id] == nil, let record = try store().read(id) else { throw MarkdownError.invalid }
    let intent = record["intent"] as? MarkdownJSON
    let candidate = intent?["operation"] as? MarkdownJSON
    var selected = record["draft"] as? MarkdownJSON
    var savedHost = record["host"] as? MarkdownJSON
    if let candidate = candidate, (candidate["revision"] as? Int ?? -1) > (selected?["revision"] as? Int ?? -1) {
      selected = candidate
      savedHost = intent?["host"] as? MarkdownJSON
    }
    guard var draft = selected, let content = draft["content"] as? String else { throw MarkdownError.invalid }
    let revision = try MarkdownCore.counter(draft["revision"])
    let format = draft["format"] as? MarkdownJSON ?? (draft["target"] as? MarkdownJSON)?["format"] as? MarkdownJSON ?? ["bom":false,"newline":"\n"]
    _ = try MarkdownCore.encode(content, format:format, maximum:MarkdownCore.recoveryContentLimit)
    let session = try await create()
    session.initial = content
    session.format = format
    session.recovered = ["revision": revision, "targetGeneration": 0]
    let oldTarget = draft["target"] as? MarkdownJSON
    if let encoded = savedHost?["bookmark"] as? String, let bookmark = Data(base64Encoded: encoded), !bookmark.isEmpty {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
        let grant = try? await authorize(session, url: url, scope: url, reserved: false, format: session.format) {
        session.current = grant.handle
        // 原文件已变更时沿用恢复草稿的旧基线，使下一次保存进入冲突处理。
        session.restoredBaseline = oldTarget?["baseline"] as? String
        var target = grant.target
        target["baseline"] = session.restoredBaseline ?? grant.baseline
        draft["target"] = target
      } else { draft["target"] = nil }
    } else { draft["target"] = nil }
    draft["sessionId"] = session.id
    draft["targetGeneration"] = 0
    draft["format"] = session.format
    do { try store().put(draft, host: session.current.flatMap { session.grants[$0]?.hostData }) }
    catch {
      for grant in Array(session.grants.values) { await remove(grant) }
      sessions.removeValue(forKey: session.id)
      throw error
    }
    return session
  }

  func discard(_ id: String) throws {
    guard sessions[id] == nil else { throw MarkdownError.invalid }
    try store().discard(id)
  }
}
#endif
