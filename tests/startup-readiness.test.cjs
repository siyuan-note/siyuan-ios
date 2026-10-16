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
