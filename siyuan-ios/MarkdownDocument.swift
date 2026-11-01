#if canImport(UIKit)
import UIKit

final class MarkdownDocument: UIDocument {
  private let lock = NSLock()
  private var pending: (data: Data, baseline: String, identity: String)?
  private var saveCompletion: ((Bool) -> Void)?
  var saveDriver: ((URL, UIDocument.SaveOperation, @escaping (Bool) -> Void) -> Void)?
  private(set) var lastError: Error?
  var onExternalChange: (() -> Void)?

  override func read(from url: URL) throws {
    let snapshot = try MarkdownCore.read(url)
    _ = try MarkdownCore.decode(snapshot.data)
  }

  override func load(fromContents contents: Any, ofType typeName: String?) throws {
    guard let bytes = contents as? Data else { throw MarkdownError.encoding }
    _ = try MarkdownCore.decode(bytes)
  }

  override func contents(forType typeName: String) throws -> Any {
    lock.lock()
    defer { lock.unlock() }
    guard let bytes = pending?.data else { throw MarkdownError.invalid }
    return bytes
  }

  override func writeContents(_ contents: Any, andAttributes additionalFileAttributes: [AnyHashable: Any]?,
    safelyTo url: URL, for saveOperation: UIDocument.SaveOperation) throws {
    lock.lock()
    let operation = pending
    lock.unlock()
    guard let operation = operation, let bytes = contents as? Data, bytes == operation.data else { throw MarkdownError.invalid }
    // 此钩子位于 UIDocument 的协调写入内，版本核验与实际写入共用协调访问。
    if saveOperation == .forCreating {
      guard operation.baseline == "missing" else { throw MarkdownError.invalid }
      try bytes.write(to: url, options: .withoutOverwriting)
      let handle = try FileHandle(forWritingTo: url)
      try MarkdownCore.synchronizeAndClose({ try handle.synchronize() }, close: { try handle.close() })
    } else {
      guard FileManager.default.isWritableFile(atPath: url.path) else { throw CocoaError(.fileWriteNoPermission) }
      let current = try MarkdownCore.read(url)
      guard current.physicalIdentity == operation.identity else { throw MarkdownError.identityChanged }
      guard current.baseline == operation.baseline else { throw MarkdownError.conflict(current.baseline) }
      try super.writeContents(contents, andAttributes: additionalFileAttributes, safelyTo: url, for: saveOperation)
    }
  }

  override func handleError(_ error: Error, userInteractionPermitted: Bool) {
    lock.lock()
    lastError = error
    lock.unlock()
    // 错误通知不是写入结束屏障，保留 pending，直到 save 的实际完成回调。
    super.handleError(error, userInteractionPermitted: false)
  }

  override func presentedItemDidChange() {
    super.presentedItemDidChange()
    DispatchQueue.main.async { [weak self] in self?.onExternalChange?() }
  }

  @MainActor func openDocument() async -> Bool {
    await withCheckedContinuation { continuation in open { continuation.resume(returning: $0) } }
  }

  @MainActor func closeDocument() async -> Bool {
    await withCheckedContinuation { continuation in close { continuation.resume(returning: $0) } }
  }

  func snapshot() async throws -> MarkdownCore.Snapshot {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        var coordinationError: NSError?
        var result: Result<MarkdownCore.Snapshot, Error>?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
          result = Result { try MarkdownCore.read(url) }
        }
        if let result = result { continuation.resume(with: result) }
        else { continuation.resume(throwing: coordinationError ?? MarkdownError.unavailable as NSError) }
      }
    }
  }

  @MainActor func saveSnapshot(_ data: Data, baseline: String, identity: String) async -> Bool {
    lock.lock()
    guard pending == nil else { lock.unlock(); return false }
    pending = (data, baseline, identity)
    lastError = nil
    lock.unlock()
    return await withCheckedContinuation { continuation in
      lock.lock()
      saveCompletion = { continuation.resume(returning: $0) }
      lock.unlock()
      let operation: UIDocument.SaveOperation = baseline == "missing" ? .forCreating : .forOverwriting
      let completion: (Bool) -> Void = { [weak self] success in
        self?.completeSave(success)
      }
      if let driver = saveDriver { driver(fileURL, operation, completion) }
      else { save(to: fileURL, for: operation, completionHandler: completion) }
    }
  }

  var hasPendingSave: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending != nil
  }

  private func completeSave(_ success: Bool) {
    lock.lock()
    guard let completion = saveCompletion else { lock.unlock(); return }
    saveCompletion = nil
    pending = nil
    lock.unlock()
    completion(success)
  }
}
#endif
