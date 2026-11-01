import Foundation
import XCTest
@testable import MarkdownNative

final class MarkdownCoreTests: XCTestCase {
  func testStrictUTF8BOMAndNewlineChoice() throws {
    let (text, format) = try MarkdownCore.decode(Data([0xef,0xbb,0xbf] + Array("one\r\ntwo\n".utf8)))
    XCTAssertEqual(text, "one\ntwo\n")
    XCTAssertEqual(format["bom"] as? Bool, true)
    XCTAssertEqual(format["newline"] as? String, "\r\n")
    XCTAssertEqual(try MarkdownCore.encode(text, format: format), Data([0xef,0xbb,0xbf] + Array("one\r\ntwo\r\n".utf8)))
    XCTAssertThrowsError(try MarkdownCore.decode(Data([0xc0,0xaf])))
  }

  func testOnlyMarkdownFilesAndExplicitBlankLaunchAreAccepted() {
    XCTAssertTrue(MarkdownCore.accepts(URL(fileURLWithPath: "/tmp/a.MARKDOWN")))
    XCTAssertFalse(MarkdownCore.accepts(URL(string: "https://example.com/a.md")!))
    XCTAssertFalse(MarkdownCore.accepts(URL(fileURLWithPath: "/tmp/a.sy")))
    XCTAssertTrue(MarkdownCore.isLaunch(URL(string: "siyuan://markdown")!))
  }

  func testPreferenceSchemaRejectsUnknownFieldsAndInvalidModes() {
    XCTAssertTrue(MarkdownCore.validPreferences(["mode":"ir","theme":"system","fontSize":16]))
    XCTAssertFalse(MarkdownCore.validPreferences(["mode":"unexpected","theme":"system","fontSize":16]))
    XCTAssertFalse(MarkdownCore.validPreferences(["mode":"ir","theme":"system","fontSize":16,"remoteScripts":true]))
  }

  func testClearWatermarkRejectsLateDraftWithoutDeletingUnrecoveredRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MarkdownRecoveryStore(directory: directory)
    let draft: MarkdownJSON = ["sessionId":"test", "targetGeneration":0, "revision":2, "operationId":"draft",
      "content":"important", "format":["bom":false,"newline":"\n"]]
    try store.put(draft, host: nil)
    XCTAssertEqual((try store.read("test")?["draft"] as? MarkdownJSON)?["content"] as? String, "important")
    try store.clear(["sessionId":"test", "targetGeneration":0, "revision":2])
    try store.put(draft, host: nil)
    XCTAssertNil(try store.read("test")?["draft"])
    XCTAssertEqual(try store.read("test")?["cleared"] as? Bool, true)
  }

  func testOversizedReadDoesNotReturnPartialContent() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("12345".utf8).write(to: url)
    XCTAssertThrowsError(try MarkdownCore.read(url, maximum: 4))
  }

  func testDocumentSizeLimitCountsUTF8Bytes() throws {
    XCTAssertEqual(MarkdownCore.documentLimit, 8 * 1024 * 1024)
    let format: MarkdownJSON = ["bom":false,"newline":"\n"]
    XCTAssertEqual(try MarkdownCore.encode(String(repeating:"x", count:8 * 1024 * 1024), format:format).count, 8 * 1024 * 1024)
    XCTAssertThrowsError(try MarkdownCore.encode(String(repeating:"x", count:8 * 1024 * 1024 + 1), format:format))
    XCTAssertThrowsError(try MarkdownCore.decode(Data(repeating:0x61, count:8 * 1024 * 1024 + 1)))
  }

  func testRecoveryContentHasAnIndependentBudgetAndPreservesPriorRecordOnFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MarkdownRecoveryStore(directory: directory)
    let content = String(repeating:"x", count:MarkdownCore.documentLimit + 1)
    let format: MarkdownJSON = ["bom":false,"newline":"\n"]
    let draft: MarkdownJSON = ["sessionId":"oversized", "targetGeneration":0, "revision":1,
      "content":content,"format":format]
    try store.put(draft, host:nil)
    XCTAssertEqual((try store.read("oversized")?["draft"] as? MarkdownJSON)?["content"] as? String, content)
    XCTAssertThrowsError(try MarkdownCore.encode(content, format:format))
    XCTAssertThrowsError(try MarkdownCore.encode(String(repeating:"é", count:MarkdownCore.recoveryContentLimit / 2 + 1),
      format:format, maximum:MarkdownCore.recoveryContentLimit))
    var tooLarge = draft
    tooLarge["content"] = String(repeating:"x", count:MarkdownCore.recoveryContentLimit + 1)
    tooLarge["revision"] = 2
    XCTAssertThrowsError(try store.put(tooLarge, host:nil))
    XCTAssertEqual((try store.read("oversized")?["draft"] as? MarkdownJSON)?["content"] as? String, content)
  }

  func testPreferencePatchesReadLatestFileAndUnknownVersionIsNeverOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    let url = directory.appendingPathComponent("preferences.json")
    _ = try MarkdownCore.preferences(at:url, patch:["theme":"dark"])
    let merged = try MarkdownCore.preferences(at:url, patch:["fontSize":24])
    XCTAssertEqual(merged["theme"] as? String, "dark")
    XCTAssertEqual(merged["fontSize"] as? Int, 24)
    let unknown = try MarkdownCore.jsonData(["version":99,"preferences":merged])
    try unknown.write(to:url)
    XCTAssertThrowsError(try MarkdownCore.preferences(at:url, patch:["mode":"sv"]))
    XCTAssertEqual(try Data(contentsOf:url), unknown)
  }

  func testResourceGrantRejectsChangedGenerationAndRedirectedAuthorizedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let folder = root.appendingPathComponent("authorized")
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:outside, withIntermediateDirectories:true)
    let file = folder.appendingPathComponent("a.png")
    try Data("original".utf8).write(to:file)
    let directory = try MarkdownDirectoryGrant(folder)
    let grant = MarkdownResourceGrant(token:"token", url:file.resolvingSymlinksInPath().standardizedFileURL,
      identity:try MarkdownCore.fileIdentity(file), generation:1, directory:directory)
    XCTAssertNoThrow(try grant.validate(generation:1))
    XCTAssertThrowsError(try grant.validate(generation:2))
    try FileManager.default.moveItem(at:folder, to:root.appendingPathComponent("original"))
    try Data("outside".utf8).write(to:outside.appendingPathComponent("a.png"))
    try FileManager.default.createSymbolicLink(at:folder, withDestinationURL:outside)
    XCTAssertThrowsError(try directory.validate())
    XCTAssertThrowsError(try grant.validate(generation:1))
  }

  func testCloseFailureIsNotAcknowledgedAsDurableSuccess() throws {
    var closed = 0
    XCTAssertThrowsError(try MarkdownCore.synchronizeAndClose({}, close: { closed += 1; throw MarkdownError.unavailable }))
    XCTAssertEqual(closed, 1)
    XCTAssertThrowsError(try MarkdownCore.synchronizeAndClose({ throw MarkdownError.unavailable }, close: { closed += 1 }))
    XCTAssertEqual(closed, 2)
  }

  func testCorruptRecoveryRemainsOnDiskAndCannotBeOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MarkdownRecoveryStore(directory: directory)
    let target = directory.appendingPathComponent(MarkdownCore.hash(Data("session".utf8)) + ".json")
    let original = Data("unknown format".utf8)
    try original.write(to: target)
    XCTAssertEqual(try store.list().count, 0)
    XCTAssertEqual(store.corruptCount, 1)
    XCTAssertThrowsError(try store.put(["sessionId":"session", "targetGeneration":0, "revision":1, "content":"new"], host:nil))
    XCTAssertEqual(try Data(contentsOf: target), original)
  }
}
