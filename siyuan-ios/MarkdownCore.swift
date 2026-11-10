import CryptoKit
import Foundation
import CoreFoundation
import Darwin

typealias MarkdownJSON = [String: Any]

enum MarkdownError: Error {
  case invalid, encoding, size, occupied(String), conflict(String), identityChanged, unavailable
}

enum MarkdownCore {
  static func initialPage(_ html: String, dark: Bool) -> String {
    guard dark, let range = html.range(of: "./appearance/themes/daylight/theme.css") else { return html }
    return html.replacingCharacters(in: range, with: "./appearance/themes/midnight/theme.css")
  }
  // IDs follow SiYuan's timestamp/suffix format; authority tokens keep 256 random bits.
  static func newID() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMMddHHmmss"
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    var random = SystemRandomNumberGenerator()
    let suffix = String((0..<7).map { _ in alphabet.randomElement(using: &random)! })
    return formatter.string(from: Date()) + "-" + suffix
  }

  static func token() -> String {
    var random = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &random)) }.joined()
  }

  static let documentLimit = 8 * 1024 * 1024
  static let recoveryContentLimit = 16 * 1024 * 1024
  static let recoveryLimit = 256 * 1024 * 1024
  static let recoveryCount = 1024
  static let scheme = "siyuan-markdown"

  static func validFonts(_ value: Any?) -> Bool {
    guard let value = value else { return true }
    guard let groups = value as? MarkdownJSON, Set(groups.keys) == ["global", "editor", "code"] else { return false }
    return groups.values.allSatisfy { group in
      guard let fonts = group as? [MarkdownJSON], fonts.count <= 64 else { return false }
      return fonts.allSatisfy { font in
        guard Set(font.keys) == ["family", "weight"], let family = font["family"] as? String,
          !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, family.count <= 256,
          let weight = font["weight"] as? Int else { return false }
        return (1...1000).contains(weight)
      }
    }
  }

  static func validPreferences(_ value: MarkdownJSON) -> Bool {
    Set(value.keys).isSubset(of: ["mode", "theme", "fontSize", "fonts", "sources", "independent"]) &&
      ["ir", "wysiwyg", "sv"].contains(value["mode"] as? String ?? "") &&
      ["system", "light", "dark"].contains(value["theme"] as? String ?? "") &&
      (9...72).contains(value["fontSize"] as? Int ?? 0) && validFonts(value["fonts"]) &&
      validAppearanceSources(value["sources"]) && validIndependentAppearance(value["independent"])
  }

  static func validAppearanceSources(_ value: Any?) -> Bool {
    guard let value = value else { return true }
    guard let sources = value as? MarkdownJSON, Set(sources.keys).isSubset(of: ["theme", "fontSize", "fonts"]) else { return false }
    return sources.values.allSatisfy { source in
      guard let id = source as? String else { return false }
      return id == "independent" || id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
  }

  static func validIndependentAppearance(_ value: Any?) -> Bool {
    guard let value = value else { return true }
    guard let independent = value as? MarkdownJSON,
      Set(independent.keys).isSubset(of: ["theme", "fontSize", "fonts"]) else { return false }
    if let theme = independent["theme"], !["system", "light", "dark"].contains(theme as? String ?? "") { return false }
    if let size = independent["fontSize"], !(9...72).contains(size as? Int ?? 0) { return false }
    return validFonts(independent["fonts"])
  }

  // 调用方串行读合并写，各窗口不以自己的旧快照覆盖其他窗口的偏好。
  static func preferences(at url: URL, patch: MarkdownJSON? = nil) throws -> MarkdownJSON {
    var value: MarkdownJSON = ["mode":"ir", "theme":"system", "fontSize":16]
    if FileManager.default.fileExists(atPath: url.path) {
      let envelope = try dictionary(JSONSerialization.jsonObject(with: Data(contentsOf:url)))
      guard envelope["version"] as? Int == 1, let saved = envelope["preferences"] as? MarkdownJSON,
        validPreferences(saved) else { throw MarkdownError.invalid }
      value = saved
    }
    guard let patch = patch else { return value }
    guard Set(patch.keys).isSubset(of:["mode", "theme", "fontSize", "fonts"]) else { throw MarkdownError.invalid }
    value.merge(patch) { _, new in new }
    return try replacePreferences(at: url, value: value)
  }

  static func replacePreferences(at url: URL, value: MarkdownJSON) throws -> MarkdownJSON {
    guard validPreferences(value) else { throw MarkdownError.invalid }
    try jsonData(["version":1, "preferences":value]).write(to:url, options:.atomic)
    let file = try FileHandle(forWritingTo:url)
    try synchronizeAndClose({ try file.synchronize() }, close:{ try file.close() })
    return value
  }

  static func persistResolvedPreferences(at url: URL, previous: MarkdownJSON, resolved: MarkdownJSON) throws {
    if !NSDictionary(dictionary: previous).isEqual(to: resolved) {
      _ = try replacePreferences(at: url, value: resolved)
    }
  }

  static func synchronizeAndClose(_ synchronize: () throws -> Void, close: () throws -> Void) throws {
    do { try synchronize() }
    catch { try? close(); throw error }
    try close()
  }

  static func accepts(_ url: URL) -> Bool {
    url.isFileURL && ["md", "markdown"].contains(url.pathExtension.lowercased())
  }

  static func isLaunch(_ url: URL) -> Bool {
    accepts(url) || (url.scheme == "siyuan" && url.host == "markdown")
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
  }

  static func dictionary(_ value: Any?) throws -> MarkdownJSON {
    guard let result = value as? MarkdownJSON else { throw MarkdownError.invalid }
    return result
  }

  static func counter(_ value: Any?) throws -> Int {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
      number.doubleValue.rounded(.down) == number.doubleValue
    else { throw MarkdownError.invalid }
    return number.intValue
  }

  static func failure(_ error: Error, indeterminate: Bool = false) -> MarkdownJSON {
    var code = "io"
    if let error = error as? MarkdownError {
      switch error {
      case .invalid: code = "protocol"
      case .encoding: code = "encoding"
      case .size: code = "size"
      case .identityChanged: code = "identity-changed"
      case .unavailable: code = "unavailable"
      default: break
      }
    } else {
      let error = error as NSError
      if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { code = "permission" }
      if error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { code = "deleted" }
      if error.code == NSFileWriteOutOfSpaceError { code = "space" }
    }
    return ["kind": indeterminate ? "indeterminate" : "blocked", "error": ["code": code, "recoverable": !["protocol", "encoding", "size"].contains(code)]]
  }

  static func decode(_ data: Data) throws -> (String, MarkdownJSON) {
    guard data.count <= documentLimit else { throw MarkdownError.size }
    let bom = data.starts(with: [0xef, 0xbb, 0xbf])
    guard let raw = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8), !raw.contains("\0")
    else { throw MarkdownError.encoding }
    let expression = try NSRegularExpression(pattern: "\\r\\n|\\r|\\n")
    let matches = expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
    var counts: [String: Int] = [:]
    var order: [String] = []
    for match in matches {
      let newline = (raw as NSString).substring(with: match.range)
      if counts[newline] == nil { order.append(newline) }
      counts[newline, default: 0] += 1
    }
    let selected = order.reduce("\n") { best, value in
      (counts[value, default: 0] > counts[best, default: 0] || best == "\n" && counts[best] == nil) ? value : best
    }
    // 相同计数时取首次出现的换行，不受字典迭代顺序影响。
    let newline = order.first(where: { counts[$0] == counts.values.max() }) ?? selected
    return (raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), ["bom": bom, "newline": newline])
  }

  static func encode(_ content: String, format: MarkdownJSON, maximum: Int = documentLimit) throws -> Data {
    guard let bom = format["bom"] as? Bool, let newline = format["newline"] as? String,
      ["\n", "\r\n", "\r"].contains(newline), !content.contains("\0")
    else { throw MarkdownError.invalid }
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var data = Data((bom ? "\u{feff}" : "").utf8)
    data.append(Data(normalized.replacingOccurrences(of: "\n", with: newline).utf8))
    guard data.count <= maximum else { throw MarkdownError.size }
    return data
  }

  struct Snapshot {
    let data: Data
    let physicalIdentity: String
    var baseline: String { MarkdownCore.hash(Data((physicalIdentity + ":" + MarkdownCore.hash(data)).utf8)) }
  }

  static func fileIdentity(_ url: URL) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber
    else { throw MarkdownError.unavailable }
    return "\(device):\(inode)"
  }

  static func directoryIdentity(_ url: URL) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber
    else { throw MarkdownError.unavailable }
    return "\(device):\(inode)"
  }

  static func read(_ url: URL, maximum: Int = documentLimit) throws -> Snapshot {
    let selected = url.resolvingSymlinksInPath().standardizedFileURL
    let before = try FileManager.default.attributesOfItem(atPath: selected.path)
    guard let size = before[.size] as? NSNumber, size.int64Value <= Int64(maximum) else { throw MarkdownError.size }
    let identity = try fileIdentity(selected)
    let file = try FileHandle(forReadingFrom: selected)
    defer { try? file.close() }
    var descriptor = stat()
    guard fstat(file.fileDescriptor, &descriptor) == 0,
      "\(descriptor.st_dev):\(descriptor.st_ino)" == identity,
      descriptor.st_mode & S_IFMT == S_IFREG else { throw MarkdownError.identityChanged }
    var bytes = Data()
    while true {
      let chunk = try file.read(upToCount: min(64 * 1024, maximum + 1 - bytes.count)) ?? Data()
      if chunk.isEmpty { break }
      bytes.append(chunk)
      guard bytes.count <= maximum else { throw MarkdownError.size }
    }
    let after = try FileManager.default.attributesOfItem(atPath: selected.path)
    var finished = stat()
    guard fstat(file.fileDescriptor, &finished) == 0, descriptor.st_size == finished.st_size,
      descriptor.st_mtimespec.tv_sec == finished.st_mtimespec.tv_sec,
      descriptor.st_mtimespec.tv_nsec == finished.st_mtimespec.tv_nsec,
      descriptor.st_ctimespec.tv_sec == finished.st_ctimespec.tv_sec,
      descriptor.st_ctimespec.tv_nsec == finished.st_ctimespec.tv_nsec else { throw MarkdownError.identityChanged }
    guard identity == (try fileIdentity(selected)), before[.modificationDate] as? Date == after[.modificationDate] as? Date,
      before[.size] as? NSNumber == after[.size] as? NSNumber, selected == url.resolvingSymlinksInPath().standardizedFileURL
    else { throw MarkdownError.identityChanged }
    return Snapshot(data: bytes, physicalIdentity: identity)
  }

  static func importImage(source: URL, destination: URL) async throws -> Snapshot {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Snapshot, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        var coordinationError: NSError?
        var result: Result<Snapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: [], error: &coordinationError) { input, output in
          result = Result {
            let snapshot = try read(input, maximum: 32 * 1024 * 1024)
            try snapshot.data.write(to: output, options: .withoutOverwriting)
            let file = try FileHandle(forWritingTo: output)
            try synchronizeAndClose({ try file.synchronize() }, close: { try file.close() })
            let copied = try read(output, maximum: 32 * 1024 * 1024)
            guard copied.data == snapshot.data else { throw MarkdownError.unavailable }
            return copied
          }
        }
        if let result = result { continuation.resume(with: result) }
        else { continuation.resume(throwing: coordinationError ?? MarkdownError.unavailable as NSError) }
      }
    }
  }
}

struct MarkdownDirectoryGrant {
  let selected: URL
  let canonical: URL
  let identity: String
  init(_ selected: URL) throws {
    self.selected = selected.standardizedFileURL
    canonical = selected.resolvingSymlinksInPath().standardizedFileURL
    identity = try MarkdownCore.directoryIdentity(canonical)
  }
  func validate() throws {
    guard selected.resolvingSymlinksInPath().standardizedFileURL == canonical,
      try MarkdownCore.directoryIdentity(canonical) == identity else { throw MarkdownError.identityChanged }
  }
  func contains(_ url: URL) -> Bool {
    url.path.hasPrefix(canonical.path.hasSuffix("/") ? canonical.path : canonical.path + "/")
  }
}

struct MarkdownResourceGrant {
  let token: String
  let url: URL
  let identity: String
  let generation: Int
  let directory: MarkdownDirectoryGrant?
  func validate(generation current: Int) throws {
    guard generation == current, url.resolvingSymlinksInPath().standardizedFileURL == url,
      try MarkdownCore.fileIdentity(url) == identity else { throw MarkdownError.identityChanged }
    if let directory = directory {
      try directory.validate()
      guard directory.contains(url) else { throw MarkdownError.invalid }
    }
  }
}

struct MarkdownStamp: Comparable {
  let generation: Int
  let revision: Int
  init(_ object: MarkdownJSON) throws {
    generation = try MarkdownCore.counter(object["targetGeneration"])
    revision = try MarkdownCore.counter(object["revision"])
  }
  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.generation == rhs.generation ? lhs.revision < rhs.revision : lhs.generation < rhs.generation
  }
}

// 宿主串行调用；更新和清理共用水位，未恢复记录不会自动过期或淘汰。
final class MarkdownRecoveryStore {
  let directory: URL
  private(set) var corruptCount = 0
  var afterWrite: (() throws -> Void)?
  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var excluded = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
  }
  private func file(_ session: String) -> URL { directory.appendingPathComponent(MarkdownCore.hash(Data(session.utf8)) + ".json") }

  func read(_ session: String) throws -> MarkdownJSON? {
    let url = file(session)
    if !FileManager.default.fileExists(atPath: url.path) { return nil }
    return try readFile(url)
  }

  private func readFile(_ url: URL) throws -> MarkdownJSON {
    let bytes = try MarkdownCore.read(url, maximum: MarkdownCore.recoveryLimit).data
    let envelope = try MarkdownCore.dictionary(JSONSerialization.jsonObject(with: bytes))
    guard envelope["version"] as? Int == 1, let payload = envelope["payload"] as? String,
      envelope["checksum"] as? String == MarkdownCore.hash(Data(payload.utf8))
    else { throw MarkdownError.invalid }
    let record = try MarkdownCore.dictionary(JSONSerialization.jsonObject(with: Data(payload.utf8)))
    let watermark = try MarkdownCore.dictionary(record["watermark"])
    _ = try MarkdownStamp(watermark)
    guard let session = watermark["sessionId"] as? String, !session.isEmpty, file(session) == url else { throw MarkdownError.invalid }
    if let draft = record["draft"] as? MarkdownJSON { try validateContent(draft) }
    if let intent = record["intent"] as? MarkdownJSON, let operation = intent["operation"] as? MarkdownJSON { try validateContent(operation) }
    return record
  }

  private func validateContent(_ draft: MarkdownJSON) throws {
    guard let content = draft["content"] as? String else { throw MarkdownError.invalid }
    let format = try MarkdownCore.dictionary(draft["format"] ?? (draft["target"] as? MarkdownJSON)?["format"])
    _ = try MarkdownCore.encode(content, format: format, maximum: MarkdownCore.recoveryContentLimit)
  }

  func list() throws -> [MarkdownJSON] {
    corruptCount = 0
    var records: [MarkdownJSON] = []
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
      do { records.append(try readFile(url)) }
      catch { corruptCount += 1 }
    }
    return records
  }

  func pruneCleared(active: Set<String>) throws {
    for record in try list() {
      guard record["cleared"] as? Bool == true, record["draft"] == nil, record["intent"] == nil,
        let stamp = record["watermark"] as? MarkdownJSON, let session = stamp["sessionId"] as? String,
        !active.contains(session) else { continue }
      try discard(session)
    }
  }

  func write(_ session: String, record: MarkdownJSON) throws {
    let watermark = try MarkdownCore.dictionary(record["watermark"])
    _ = try MarkdownStamp(watermark)
    guard watermark["sessionId"] as? String == session else { throw MarkdownError.invalid }
    let payload = String(decoding: try MarkdownCore.jsonData(record), as: UTF8.self)
    let bytes = try MarkdownCore.jsonData(["version": 1, "payload": payload, "checksum": MarkdownCore.hash(Data(payload.utf8))])
    let target = file(session)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }
    guard files.contains(target) || files.count < MarkdownCore.recoveryCount else { throw MarkdownError.size }
    var total = bytes.count
    for url in files where url != target { total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    guard total <= MarkdownCore.recoveryLimit else { throw MarkdownError.size }
    try bytes.write(to: target, options: .atomic)
    let handle = try FileHandle(forWritingTo: target)
    try MarkdownCore.synchronizeAndClose({ try handle.synchronize() }, close: { try handle.close() })
    try afterWrite?()
  }

  @discardableResult func put(_ draft: MarkdownJSON, host: MarkdownJSON?) throws -> Bool {
    guard let session = draft["sessionId"] as? String else { throw MarkdownError.invalid }
    try validateContent(draft)
    let stamp = try MarkdownStamp(draft)
    var record = try read(session) ?? [:]
    if let prior = record["watermark"] as? MarkdownJSON {
      let watermark = try MarkdownStamp(prior)
      if stamp < watermark || stamp == watermark && record["cleared"] as? Bool == true { return false }
    }
    record["watermark"] = ["sessionId": session, "targetGeneration": stamp.generation, "revision": stamp.revision]
    record["draft"] = draft
    record["cleared"] = false
    record["host"] = host
    record["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
    try write(session, record: record)
    return true
  }

  func clear(_ watermark: MarkdownJSON) throws {
    guard let session = watermark["sessionId"] as? String else { throw MarkdownError.invalid }
    let stamp = try MarkdownStamp(watermark)
    var record = try read(session) ?? [:]
    if let prior = record["watermark"] as? MarkdownJSON, stamp < (try MarkdownStamp(prior)) { return }
    record["watermark"] = watermark
    record["draft"] = nil
    record["cleared"] = true
    record["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
    try write(session, record: record)
  }

  func discard(_ session: String) throws { try FileManager.default.removeItem(at: file(session)) }
}
