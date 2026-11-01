#if canImport(UIKit)
import UIKit
import XCTest
@testable import MarkdownNative

@MainActor final class MarkdownDocumentTests: XCTestCase {
  func testErrorNotificationDoesNotSettleAnInProgressSave() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    let document = MarkdownDocument(fileURL: url)
    var finish: ((Bool) -> Void)?
    var returned = false
    document.saveDriver = { _, _, completion in finish = completion }
    let saving = Task {
      let result = await document.saveSnapshot(Data("draft".utf8), baseline:"missing", identity:"missing")
      returned = true
      return result
    }
    while finish == nil { await Task.yield() }
    document.handleError(MarkdownError.unavailable, userInteractionPermitted:false)
    await Task.yield()
    XCTAssertFalse(returned)
    XCTAssertTrue(document.hasPendingSave)
    finish?(false)
    let result = await saving.value
    XCTAssertFalse(result)
    XCTAssertFalse(document.hasPendingSave)
  }

  func testCoordinatedWriteRejectsAnExternalVersion() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("old".utf8).write(to: url)
    let document = MarkdownDocument(fileURL: url)
    let opened = await document.openDocument()
    XCTAssertTrue(opened)
    let original = try await document.snapshot()
    try Data("external".utf8).write(to: url)
    let saved = await document.saveSnapshot(Data("local".utf8), baseline: original.baseline, identity: original.physicalIdentity)
    XCTAssertFalse(saved)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    _ = await document.closeDocument()
  }

  func testSuccessfulSaveCanBeReadWithOneBodyAndBaseline() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("old".utf8).write(to: url)
    let document = MarkdownDocument(fileURL: url)
    let opened = await document.openDocument()
    XCTAssertTrue(opened)
    let original = try await document.snapshot()
    let saved = await document.saveSnapshot(Data("new".utf8), baseline: original.baseline, identity: original.physicalIdentity)
    XCTAssertTrue(saved)
    let snapshot = try await document.snapshot()
    XCTAssertEqual(snapshot.data, Data("new".utf8))
    XCTAssertNotEqual(snapshot.baseline, original.baseline)
    _ = await document.closeDocument()
  }

  func testSaveAsReservesDestinationBeforeCreatingTheFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = MarkdownHost(directory: directory.appendingPathComponent("private"))
    let first = try await host.create()
    let second = try await host.create()
    let target = directory.appendingPathComponent("new.md")
    let grant = try await host.authorize(first, url: target, scope: directory, reserved: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    do {
      _ = try await host.authorize(second, url: target, scope: directory, reserved: true)
      XCTFail("Two sessions claimed one target")
    } catch MarkdownError.occupied(let owner) { XCTAssertEqual(owner, first.id) }
    await host.cancelCandidate(grant.handle, sessionID: first.id)
    _ = try await host.request("releaseSession", payload: ["sessionId":first.id,"targetGeneration":0], sessionID:first.id)
    _ = try await host.request("releaseSession", payload: ["sessionId":second.id,"targetGeneration":0], sessionID:second.id)
  }

  private func operation(_ session: MarkdownHost.Session, grant: MarkdownHost.Grant, sequence: Int, content: String) -> MarkdownJSON {
    var request: MarkdownJSON = ["sessionId":session.id, "operationId":"\(session.id):test:\(sequence)",
      "targetGeneration":session.generation + (grant.reservation == nil ? 0 : 1), "revision":sequence,
      "content":content, "target":grant.target, "expectedBaseline":grant.baseline]
    request["reservationId"] = grant.reservation
    return request
  }

  private func useSynchronousWriter(_ grant: MarkdownHost.Grant) {
    grant.document.saveDriver = { [weak document = grant.document] url, _, completion in
      do {
        guard let bytes = try document?.contents(forType:"net.daringfireball.markdown") as? Data else { throw MarkdownError.invalid }
        try bytes.write(to:url)
        completion(true)
      } catch { completion(false) }
    }
  }

  func testDraftFailurePreventsOriginalWriteAndActiveRecordsAreNotRecoverableOrDiscardable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let url = directory.appendingPathComponent("original.md")
    try Data("original".utf8).write(to:url)
    let store = try MarkdownRecoveryStore(directory:directory.appendingPathComponent("recovery"))
    let host = MarkdownHost(directory:directory, recovery:store)
    let session = try await host.create(url:url)
    let grant = try XCTUnwrap(session.grants[try XCTUnwrap(session.current)])
    var written = false
    grant.document.saveDriver = { _, _, completion in written = true; completion(true) }
    store.afterWrite = { throw MarkdownError.unavailable }
    let result = try await host.request("write", payload:operation(session, grant:grant, sequence:1, content:"new"), sessionID:session.id) as? MarkdownJSON
    XCTAssertEqual(result?["kind"] as? String, "blocked")
    XCTAssertFalse(written)
    XCTAssertEqual(try String(contentsOf:url, encoding:.utf8), "original")
    XCTAssertEqual(try host.recoveries().count, 0)
    XCTAssertThrowsError(try host.discard(session.id))
    store.afterWrite = nil
    _ = try await host.request("releaseSession", payload:["sessionId":session.id,"targetGeneration":0], sessionID:session.id)
    XCTAssertEqual(try host.recoveries().count, 1)
  }

  func testCompletedWritesDoNotRetainTasksAndOldOperationIDsCannotReplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let url = directory.appendingPathComponent("document.md")
    try Data("start".utf8).write(to:url)
    let host = MarkdownHost(directory:directory.appendingPathComponent("private"))
    let session = try await host.create(url:url)
    let grant = try XCTUnwrap(session.grants[try XCTUnwrap(session.current)])
    useSynchronousWriter(grant)
    let first = operation(session, grant:grant, sequence:1, content:"1")
    for index in 1...24 {
      let result = try await host.request("write", payload:operation(session, grant:grant, sequence:index, content:String(index)), sessionID:session.id) as? MarkdownJSON
      XCTAssertEqual(result?["kind"] as? String, "committed")
    }
    XCTAssertEqual(session.operations.count, 16)
    XCTAssertTrue(session.operations.values.allSatisfy { $0.task == nil })
    let replay = try await host.request("write", payload:first, sessionID:session.id) as? MarkdownJSON
    XCTAssertEqual(replay?["kind"] as? String, "blocked")
    XCTAssertEqual(try String(contentsOf:url, encoding:.utf8), "24")
    _ = try await host.request("releaseSession", payload:["sessionId":session.id,"targetGeneration":0], sessionID:session.id)
  }

  func testSaveAsLostDurableAcknowledgementMigratesLateDraftAndKeepsReservation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = try MarkdownRecoveryStore(directory:directory.appendingPathComponent("recovery"))
    let host = MarkdownHost(directory:directory, recovery:store)
    let session = try await host.create()
    let grant = try await host.authorize(session, url:directory.appendingPathComponent("target.md"), scope:directory, reserved:true)
    useSynchronousWriter(grant)
    let request = operation(session, grant:grant, sequence:1, content:"saved")
    _ = try await host.request("reserveSaveAs", payload:["sessionId":session.id,"operationId":request["operationId"]!,"target":grant.target], sessionID:session.id)
    _ = try await host.request("prepareSaveAs", payload:["operation":request], sessionID:session.id)
    let receipt = try await host.request("write", payload:request, sessionID:session.id) as! MarkdownJSON
    XCTAssertEqual(receipt["kind"] as? String, "committed")
    do {
      _ = try await host.request("releaseSaveAs", payload:["sessionId":session.id,"operationId":request["operationId"]!,"reservationId":grant.reservation!], sessionID:session.id)
      XCTFail("A written destination was released before binding")
    } catch { }
    let transfer: MarkdownJSON = ["operation":request, "receipt":receipt, "nextTargetGeneration":1]
    store.afterWrite = { throw MarkdownError.unavailable }
    let uncertain = try await host.request("commitSaveAs", payload:transfer, sessionID:session.id) as? MarkdownJSON
    XCTAssertEqual(uncertain?["kind"] as? String, "indeterminate")
    XCTAssertEqual(session.generation, 0)
    XCTAssertNotNil(grant.reservation)
    store.afterWrite = nil
    _ = try await host.request("putDraft", payload:["sessionId":session.id,"operationId":"\(session.id):test:2", "targetGeneration":0,
      "revision":2,"content":"new input","format":["bom":false,"newline":"\n"]], sessionID:session.id)
    let saved = try XCTUnwrap(store.read(session.id)?["draft"] as? MarkdownJSON)
    XCTAssertEqual(saved["targetGeneration"] as? Int, 1)
    XCTAssertEqual(saved["content"] as? String, "new input")
    let committed = try await host.request("commitSaveAs", payload:transfer, sessionID:session.id) as? MarkdownJSON
    XCTAssertEqual(committed?["kind"] as? String, "committed")
    XCTAssertEqual(session.generation, 1)
    XCTAssertEqual(session.current, grant.handle)
    let repeated = try await host.request("commitSaveAs", payload:transfer, sessionID:session.id) as? MarkdownJSON
    XCTAssertEqual(repeated?["kind"] as? String, "committed")
    _ = try await host.request("clearDraft", payload:["sessionId":session.id,"targetGeneration":1,"revision":2], sessionID:session.id)
    _ = try await host.request("putDraft", payload:["sessionId":session.id,"operationId":"\(session.id):test:3", "targetGeneration":0,
      "revision":3,"content":"late after clear","format":["bom":false,"newline":"\n"]], sessionID:session.id)
    XCTAssertEqual((try store.read(session.id)?["draft"] as? MarkdownJSON)?["content"] as? String, "late after clear")
    _ = try await host.request("releaseSession", payload:["sessionId":session.id,"targetGeneration":1], sessionID:session.id)
  }

  func testRendererTerminationCopiesLatestDraftBeforeReleasingOriginalSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = try MarkdownRecoveryStore(directory:directory.appendingPathComponent("recovery"))
    let host = MarkdownHost(directory:directory, recovery:store)
    let original = try await host.create()
    let draft: MarkdownJSON = ["sessionId":original.id,"operationId":"\(original.id):test:1", "targetGeneration":0,
      "revision":3,"content":"recover this","format":["bom":false,"newline":"\n"]]
    _ = try await host.request("putDraft", payload:draft, sessionID:original.id)
    store.afterWrite = { throw MarkdownError.unavailable }
    do { _ = try await host.recoverTerminatedRenderer(original); XCTFail("Copy failure was acknowledged") }
    catch { }
    XCTAssertNotNil(host.sessions[original.id])
    XCTAssertNotNil(try store.read(original.id)?["draft"])
    store.afterWrite = nil
    let recovered = try await host.recoverTerminatedRenderer(original)
    XCTAssertEqual(recovered.initial, "recover this")
    XCTAssertNil(recovered.current)
    XCTAssertNil(host.sessions[original.id])
    XCTAssertNotNil(try store.read(original.id)?["draft"])
    XCTAssertNotNil(try store.read(recovered.id)?["draft"])
    _ = try await host.request("releaseSession", payload:["sessionId":recovered.id,"targetGeneration":0], sessionID:recovered.id)
  }

  func testRecoveryUsesNewerPreparedBodyAndPreservesSourceRecord() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = try MarkdownRecoveryStore(directory:directory.appendingPathComponent("recovery"))
    try store.put(["sessionId":"source", "targetGeneration":0, "revision":1, "content":"older",
      "format":["bom":false,"newline":"\n"]], host:nil)
    var record = try XCTUnwrap(store.read("source"))
    record["intent"] = ["operation":["sessionId":"source", "targetGeneration":1, "revision":2,
      "content":"newer", "target":["format":["bom":false,"newline":"\n"]]]]
    try store.write("source", record:record)
    let host = MarkdownHost(directory:directory, recovery:store)
    let recovered = try await host.restore("source")
    XCTAssertEqual(recovered.initial, "newer")
    XCTAssertNil(recovered.current)
    XCTAssertNotNil(try store.read("source"))
    _ = try await host.request("releaseSession", payload:["sessionId":recovered.id,"targetGeneration":0], sessionID:recovered.id)
  }

  func testRecoveryCanOpenAnOversizedPrivateDraftWithoutWritingAnOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = try MarkdownRecoveryStore(directory:directory.appendingPathComponent("recovery"))
    let content = String(repeating:"x", count:MarkdownCore.documentLimit + 1)
    try store.put(["sessionId":"source", "targetGeneration":0, "revision":1, "content":content,
      "format":["bom":false,"newline":"\n"]], host:nil)
    let host = MarkdownHost(directory:directory, recovery:store)
    let recovered = try await host.restore("source")
    XCTAssertEqual(recovered.initial, content)
    XCTAssertNil(recovered.current)
    XCTAssertNotNil(try store.read("source"))
    _ = try await host.request("releaseSession", payload:["sessionId":recovered.id,"targetGeneration":0], sessionID:recovered.id)
  }
}
#endif
