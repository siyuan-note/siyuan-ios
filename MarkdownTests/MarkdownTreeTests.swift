import Foundation
import XCTest
@testable import MarkdownNative

@MainActor final class MarkdownTreeTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    return root
  }
  func testDirectoryGrantFiltersAndNaturallySortsRealFiles() async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
    let docs = base.appendingPathComponent("docs")
    try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:docs.appendingPathComponent("folder"),withIntermediateDirectories:true)
    for name in ["10.md","2.MARKDOWN","hidden.txt","photo.png"] { try Data("text".utf8).write(to:docs.appendingPathComponent(name)) }
    let tree = MarkdownTree(storage:base.appendingPathComponent("view.json"))
    try await tree.choose(docs)
    await tree.follow(docs.appendingPathComponent("2.MARKDOWN"))
    let state = await tree.state()
    let location: MarkdownJSON = ["rootId":state["rootId"]!,"generation":state["generation"]!,"nodeId":state["rootId"]!]
    let listing = await tree.list(location)
    let entries = try XCTUnwrap(listing["entries"] as? [MarkdownJSON])
    XCTAssertEqual(entries.compactMap { $0["name"] as? String }, ["folder","2.MARKDOWN","10.md"])
    let current = try XCTUnwrap(state["currentNodeId"] as? String)
    let file = try tree.file(["rootId":state["rootId"]!,"generation":state["generation"]!,"nodeId":current])
    XCTAssertEqual(file.0,docs.appendingPathComponent("2.MARKDOWN"))
    XCTAssertEqual(file.1,docs)
    try tree.saveView(["rootId":state["rootId"]!,"generation":state["generation"]!,"expanded":[state["rootId"]!],"width":320,"visible":false])
    let other = MarkdownTree(storage:base.appendingPathComponent("view.json"))
    try await other.choose(docs)
    let restored = await other.state()
    XCTAssertEqual(restored["width"] as? Int,320)
    XCTAssertEqual(restored["visible"] as? Bool,false)
    XCTAssertEqual(restored["rootId"] as? String,state["rootId"] as? String)
  }
  func testRevokedDirectoryAndStaleGenerationNeverOpenNodes() async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
    let docs = base.appendingPathComponent("docs")
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
    try Data("private".utf8).write(to:outside.appendingPathComponent("secret.md"))
    try FileManager.default.createSymbolicLink(at:docs.appendingPathComponent("escape"),withDestinationURL:outside)
    let tree = MarkdownTree(storage:base.appendingPathComponent("view.json"))
    try await tree.choose(docs)
    let state = await tree.state()
    let location: MarkdownJSON = ["rootId":state["rootId"]!,"generation":state["generation"]!,"nodeId":state["rootId"]!]
    let listing = await tree.list(location)
    XCTAssertEqual((listing["entries"] as? [MarkdownJSON])?.count,0)
    try await tree.choose(outside)
    let stale = await tree.list(location)
    XCTAssertEqual(stale["kind"] as? String,"blocked")
    try FileManager.default.moveItem(at:outside,to:base.appendingPathComponent("moved"))
    try FileManager.default.createSymbolicLink(at:outside,withDestinationURL:docs)
    let changed = await tree.state()
    XCTAssertEqual(changed["kind"] as? String,"blocked")
  }
  func testUnknownTreeViewIsPreservedAndCannotBeOverwritten() async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
    let file = base.appendingPathComponent("view.json")
    let original = Data("{\"version\":99,\"unrecognized\":true}".utf8)
    try original.write(to:file)
    let tree = MarkdownTree(storage:file)
    XCTAssertThrowsError(try tree.saveView(["width":300]))
    do { try await tree.choose(base); XCTFail("unknown preference schema must remain untouched") } catch {}
    XCTAssertEqual(try Data(contentsOf:file),original)
  }
  func testManualRootOnlyFollowsOutsideSaveAs() async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
    let original = base.appendingPathComponent("original")
    let next = base.appendingPathComponent("next")
    try FileManager.default.createDirectory(at:original,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:next,withIntermediateDirectories:true)
    let a = original.appendingPathComponent("a.md"), b = next.appendingPathComponent("b.md")
    try Data("a".utf8).write(to:a); try Data("b".utf8).write(to:b)
    let tree = MarkdownTree(storage:base.appendingPathComponent("view.json"))
    try await tree.choose(original)
    let selected = await tree.state()
    await tree.follow(b)
    let unchanged = await tree.state()
    XCTAssertEqual(unchanged["rootId"] as? String,selected["rootId"] as? String)
    await tree.follow(a,authorizedDirectory:original,afterSaveAs:true)
    let inside = await tree.state()
    XCTAssertEqual(inside["rootId"] as? String,selected["rootId"] as? String)
    await tree.follow(b,authorizedDirectory:next,afterSaveAs:true)
    let moved = await tree.state()
    XCTAssertNotEqual(moved["rootId"] as? String,selected["rootId"] as? String)
    XCTAssertNotNil(moved["currentNodeId"])
  }
  func testDeletedCurrentFileAndReplacedSubdirectoryLeaveRootNavigable() async throws {
    let base = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
    let docs = base.appendingPathComponent("docs")
    let sub = docs.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at:sub,withIntermediateDirectories:true)
    let current = docs.appendingPathComponent("a.md")
    let sibling = docs.appendingPathComponent("b.md")
    try Data("current".utf8).write(to:current)
    try Data("sibling".utf8).write(to:sibling)
    let tree = MarkdownTree(storage:base.appendingPathComponent("view.json"))
    await tree.follow(current,authorizedDirectory:docs)
    let original = await tree.state()
    XCTAssertNotNil(original["currentNodeId"])
    try FileManager.default.removeItem(at:current)
    let deleted = await tree.state()
    XCTAssertEqual(deleted["kind"] as? String,"ready")
    XCTAssertNil(deleted["currentNodeId"])
    XCTAssertEqual(deleted["rootId"] as? String,original["rootId"] as? String)
    let subFile = sub.appendingPathComponent("current.md")
    try Data("nested".utf8).write(to:subFile)
    await tree.follow(subFile)
    let selected = await tree.state()
    XCTAssertNotNil(selected["currentNodeId"])
    try FileManager.default.moveItem(at:sub,to:base.appendingPathComponent("moved"))
    try FileManager.default.createSymbolicLink(at:sub,withDestinationURL:base.appendingPathComponent("moved"))
    let replaced = await tree.state()
    XCTAssertEqual(replaced["kind"] as? String,"ready")
    XCTAssertNil(replaced["currentNodeId"])
    let listing = await tree.list(["rootId":original["rootId"]!,"generation":original["generation"]!,"nodeId":original["rootId"]!])
    let entries = try XCTUnwrap(listing["entries"] as? [MarkdownJSON])
    XCTAssertEqual(entries.compactMap { $0["name"] as? String },["b.md"])
    let selectedFile = try tree.file(["rootId":original["rootId"]!,"generation":original["generation"]!,"nodeId":entries[0]["id"]!])
    XCTAssertEqual(selectedFile.0,sibling)
  }
}
