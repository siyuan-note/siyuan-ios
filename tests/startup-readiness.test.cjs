const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const {test} = require("node:test");
const {runInNewContext} = require("node:vm");

const source = readFileSync(join(__dirname, "../siyuan-ios/ViewController.swift"), "utf8");
const monitor = source.slice(source.indexOf("private func pollMainPageReadiness"));
const script = monitor.match(/evaluateJavaScript\("""([\s\S]*?)"""\)/)[1];
const status = (isReady, failed, pathname = "/stage/build/mobile/", stage = "") => JSON.parse(JSON.stringify(runInNewContext(script, {
    window: {siyuan: isReady === undefined ? undefined : {isReady}},
    location: {pathname},
    document: {documentElement: {getAttribute: name => name === "data-startup-stage" ? stage : failed ? "failed" : "loading"}},
})));

test("HTML navigation alone does not acknowledge frontend startup", () => {
    assert.deepEqual(status(undefined, false), {ready: false, failed: false, stage: ""});
    assert.deepEqual(status(false, false), {ready: false, failed: false, stage: ""});
    const navigation = source.slice(source.indexOf("func webView(_ webView: WKWebView, didFinish"),
        source.indexOf("func webView(_ webView: WKWebView, didFail"));
    assert.doesNotMatch(navigation, /removeBootWebView\(/, "the original boot page remains until the readiness poll succeeds");
});

test("frontend completion and visible failure stop native startup monitoring separately", () => {
    assert.deepEqual(status(true, false), {ready: true, failed: false, stage: ""});
    assert.deepEqual(status(false, true), {ready: false, failed: true, stage: ""});
});

test("the authentication page can be used before application initialization", () => {
    assert.deepEqual(status(undefined, false, "/check-auth"), {ready: true, failed: false, stage: ""});
});

test("startup progress is available for renewing the native deadline", () => {
    assert.deepEqual(status(false, false, "/stage/build/mobile/", "engine"), {ready: false, failed: false, stage: "engine"});
});

test("foreground activation and manual retry share the recovery gate after cold boot", () => {
    const manualRetry = source.slice(source.indexOf("case .startKernelFast:"), source.indexOf("case .changeStatusBar:"));
    const foreground = source.slice(source.indexOf("@objc func willEnterForeground"), source.indexOf("private func recoverKernelIfNeeded"));
    const recovery = source.slice(source.indexOf("private func recoverKernelIfNeeded"), source.indexOf("private static func probeKernel"));
    assert.match(manualRetry, /recoverKernelIfNeeded\(\)/);
    assert.match(foreground, /recoverKernelIfNeeded\(\)/);
    assert.match(recovery, /guard kernelBootCompleted, !ViewController\.kernelRecoveryInProgress else \{ return \}\s+ViewController\.kernelRecoveryInProgress = true\s+ViewController\.probeKernel/);
    assert.match(recovery, /guard !reachable else \{\s+ViewController\.kernelRecoveryInProgress = false\s+return\s+\}[\s\S]*Iosk\.MobileStartKernelFast/);
    assert.equal((source.match(/Iosk\.MobileStartKernelFast\(/g) || []).length, 1);
});

test("recovery waits for the asynchronous listener or a deadline before accepting another retry", () => {
    const recovery = source.slice(source.indexOf("private func recoverKernelIfNeeded"), source.indexOf("@objc func protectedDataDidBecomeUnavailable"));
    const wait = recovery.slice(recovery.indexOf("private static func waitForKernelRecovery"));
    assert.match(recovery, /Iosk\.MobileStartKernelFast[^\n]+\n\s+ViewController\.waitForKernelRecovery\(until: ProcessInfo\.processInfo\.systemUptime \+ \d+\)/);
    assert.match(wait, /if reachable \|\| ProcessInfo\.processInfo\.systemUptime >= deadline \{\s+kernelRecoveryInProgress = false\s+return\s+\}/);
    assert.match(wait, /DispatchQueue\.main\.asyncAfter[\s\S]*waitForKernelRecovery\(until: deadline\)/);
});
