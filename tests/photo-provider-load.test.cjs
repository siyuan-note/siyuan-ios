const assert = require("node:assert/strict");
const {execFileSync, spawnSync} = require("node:child_process");
const {readFileSync, writeFileSync, mkdtempSync, rmSync, realpathSync} = require("node:fs");
const {tmpdir} = require("node:os");
const path = require("node:path");
const {test} = require("node:test");

const compiler = process.env.SWIFTC || "swiftc";
const available = spawnSync(compiler, ["--version"], {windowsHide: true}).status === 0;

test("photo loading cancels Progress and settles its continuation once", {
    skip: available ? false : "Swift compiler unavailable; run on the iOS build host",
}, () => {
    const root = realpathSync(tmpdir());
    const temporary = mkdtempSync(path.join(root, "siyuan-photo-provider-"));
    try {
        const source = readFileSync(path.join(__dirname, "../siyuan-ios/ViewController.swift"), "utf8");
        const start = source.indexOf("private final class PhotoProviderLoad<Value>");
        const end = source.indexOf("\nprivate final class PhotoResourceRead", start);
        assert.ok(start > 0 && end > start);
        const program = `import Foundation
import Dispatch
${source.slice(start, end)}
@main struct ProviderLoadTests {
  static func main() async throws {
    let early = PhotoProviderLoad<Int>()
    early.cancel()
    do {
      let _: Int = try await withCheckedThrowingContinuation { continuation in
        precondition(!early.setContinuation(continuation))
      }
      fatalError("early cancellation was ignored")
    } catch is CancellationError {}
    let lateProgress = Progress(totalUnitCount: 1)
    early.setProgress(lateProgress)
    precondition(lateProgress.isCancelled)
    early.finish(.success(1))

    let stalled = PhotoProviderLoad<Int>()
    let progress = Progress(totalUnitCount: 1)
    do {
      let _: Int = try await withCheckedThrowingContinuation { continuation in
        precondition(stalled.setContinuation(continuation))
        stalled.setProgress(progress)
        stalled.cancel()
        // Progress 取消后不回调，等待也必须立即结束。
      }
      fatalError("stalled loading retained its continuation")
    } catch is CancellationError {}
    precondition(progress.isCancelled)
    stalled.finish(.success(2))
    stalled.cancel()

    let completed = PhotoProviderLoad<Int>()
    let completedProgress = Progress(totalUnitCount: 1)
    let value: Int = try await withCheckedThrowingContinuation { continuation in
      precondition(completed.setContinuation(continuation))
      completed.finish(.success(3))
      completed.setProgress(completedProgress)
      completed.cancel()
      completed.finish(.success(4))
    }
    precondition(value == 3 && !completedProgress.isCancelled)

    for _ in 0..<500 {
      let racing = PhotoProviderLoad<Int>()
      let progress = Progress(totalUnitCount: 1)
      do {
        let value: Int = try await withCheckedThrowingContinuation { continuation in
          precondition(racing.setContinuation(continuation))
          racing.setProgress(progress)
          DispatchQueue.global().async { racing.finish(.success(5)) }
          DispatchQueue.global().async { racing.cancel(); racing.finish(.success(6)) }
        }
        precondition(value == 5)
      } catch is CancellationError {
        precondition(progress.isCancelled)
      }
    }
    print("provider cancellation and completion races passed")
  }
}
`;
        const file = path.join(temporary, "ProviderLoadTests.swift");
        const executable = path.join(temporary, process.platform === "win32" ? "test.exe" : "test");
        writeFileSync(file, program);
        execFileSync(compiler, ["-swift-version", "5", "-parse-as-library", file, "-o", executable], {timeout: 60000, windowsHide: true});
        const output = execFileSync(executable, [], {encoding: "utf8", timeout: 15000, windowsHide: true});
        assert.match(output, /provider cancellation and completion races passed/);
    } finally {
        assert.equal(path.dirname(path.resolve(temporary)), root);
        assert.ok(path.basename(temporary).startsWith("siyuan-photo-provider-"));
        rmSync(temporary, {recursive: true, force: true});
    }
});
