const assert = require("node:assert/strict");
const {execFileSync, spawnSync} = require("node:child_process");
const {readFileSync, writeFileSync, mkdtempSync, rmSync} = require("node:fs");
const {tmpdir} = require("node:os");
const path = require("node:path");
const {test} = require("node:test");

const source = readFileSync(path.join(__dirname, "../siyuan-ios/ViewController.swift"), "utf8");
const compiler = process.env.SWIFTC || "swiftc";
const available = spawnSync(compiler, ["--version"], {windowsHide: true}).status === 0;
const navigationStart = source.indexOf("  func webView(\n    _ webView: WKWebView, decidePolicyFor navigationAction:");
const responseStart = source.indexOf("  func webView(\n    _ webView: WKWebView, decidePolicyFor navigationResponse:");
assert.ok(navigationStart >= 0 && responseStart > navigationStart);
const navigation = source.slice(navigationStart, responseStart);
const method = name => {
    const match = source.match(new RegExp(`  private func ${name}\\([^]*?\\n  }`));
    assert.ok(match, name);
    return match[0].replace("private func", "func");
};

test("HTML iframe allowance follows explicit downloads and precedes external opening", () => {
    const download = navigation.indexOf("navigationAction.shouldPerformDownload");
    const allowance = navigation.indexOf("if isLocalHTMLAssetIFrameNavigation(webView, navigationAction)");
    const external = navigation.indexOf('starts(with: "http://127.0.0.1:6806/assets")');
    assert.ok(download >= 0 && allowance > download && external > allowance);
    assert.match(navigation.slice(allowance, external), /decisionHandler\(\.allow\)\s+return/);
    const response = source.slice(responseStart, source.indexOf("  func initKernel()", responseStart));
    assert.match(response, /Content-Disposition/);
    assert.match(response, /saveExportFile\(uri: assetPath, requestID: ""\)/);
});

test("only automatic local subframes are eligible and native bridge isolation is unchanged", () => {
    const predicate = method("isLocalHTMLAssetIFrameNavigation");
    assert.match(predicate, /webView === ViewController\.syWebView/);
    assert.match(predicate, /isLocalKernelURL\(mainURL\)/);
    assert.match(predicate, /mainURL\.user == nil, mainURL\.password == nil/);
    assert.match(predicate, /targetFrame\?\.isMainFrame == false/);
    assert.match(predicate, /navigationType == \.other/);
    assert.match(predicate, /!navigationAction\.shouldPerformDownload/);
    assert.match(source, /guard message\.webView === ViewController\.syWebView, message\.frameInfo\.isMainFrame/);
    assert.doesNotMatch(predicate, /evaluateJavaScript|loadHTMLString|allow-same-origin|allow-top-navigation/);
});

test("HTML iframe URL policy rejects ambiguous query and traversal syntax", () => {
    const predicate = method("isLocalHTMLAssetIFrameURL");
    assert.match(predicate, /isLocalKernelURL\(url\), url\.user == nil, url\.password == nil/);
    assert.match(predicate, /percentEncodedPath\.hasPrefix\("\/assets\/"\)/);
    assert.match(predicate, /removingPercentEncoding/);
    assert.match(predicate, /\$0 == "\." \|\| \$0 == "\.\."/);
    assert.match(predicate, /!query\.contains\(";"\)/);
    assert.match(predicate, /iframe\.count == 1/);
    assert.match(predicate, /download\.count <= 1/);
});

test("Swift URL policy and delegate preserve HTML embedding, download and external routing", {
    skip: available ? false : "Swift compiler unavailable; run on the iOS build host",
}, () => {
    // Compile the production methods, not a JavaScript approximation of Foundation URL parsing.
    // WebKit/UIKit stand-ins exercise routing only; they are not a device integration test.
    const program = `import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
enum WKNavigationType { case other, linkActivated, formSubmitted, reload, backForward }
enum WKNavigationActionPolicy: Equatable { case allow, cancel }
final class WKFrameInfo {
  let isMainFrame: Bool
  var request: URLRequest
  init(_ isMainFrame: Bool, _ url: String = "about:blank") {
    self.isMainFrame = isMainFrame
    request = URLRequest(url: URL(string: url)!)
  }
}
final class WKWebView { var url: URL? }
struct WKNavigationAction {
  var request: URLRequest
  var targetFrame: WKFrameInfo? = WKFrameInfo(false)
  var navigationType: WKNavigationType = .other
  var shouldPerformDownload = false
}
final class UIApplication {
  static let shared = UIApplication()
  var opened: [URL] = []
  var canOpen = true
  func canOpenURL(_ url: URL) -> Bool { canOpen }
  func open(_ url: URL, options: [String: String], completionHandler: ((Bool) -> Void)?) {
    opened.append(url)
  }
}
final class TaskStub { func cancel() {} }
final class ViewController {
  static let syWebView = WKWebView()
  var bootWebView: WKWebView?
  var bootProgressMonitorActive = false
  var bootProgressTask: TaskStub?
  var kernelBootCompleted = false
  var mainPageNavigationStarted = false
  var mainPageReady = false
  var saved: [String] = []
  func installStartupAppearance(in webView: WKWebView) {}
  func navigateToMainPage() {}
  func saveExportFile(uri: String, requestID: String) { saved.append(uri) }
  ${method("isLocalKernelURL")}
  ${method("isBootDocument")}
  ${method("localAssetDownloadPath")}
  ${method("isLocalHTMLAssetIFrameURL")}
  ${method("isLocalHTMLAssetIFrameNavigation")}
  ${navigation}
}
let controller = ViewController()
let base = "http://127.0.0.1:6806"
let valid = base + "/assets/component.html?iframe=true"
let positives = [
  valid,
  base + "/assets/linear-transform-20261111165645-yf6jl0k.html?iframe=true&v=2",
  base + "/assets/nested/DEMO.HTM?iframe=TRUE",
  base + "/assets/math%20demo.html?box=20261111123456-abcdefg&iframe=true#graph",
  base + "/assets/%E6%95%B0%E5%AD%A6.html?iframe=true",
  base + "/assets/math.html?%69frame=%74rue&download=false",
  base + "/assets/math.html?iframe=true&note=a%3Bb"
]
for value in positives {
  precondition(controller.isLocalHTMLAssetIFrameURL(URL(string: value)!), "valid URL rejected: " + value)
}
let negatives = [
  "https://127.0.0.1:6806/assets/a.html?iframe=true",
  "http://localhost:6806/assets/a.html?iframe=true",
  "http://127.0.0.1:6807/assets/a.html?iframe=true",
  "http://127.0.0.1/assets/a.html?iframe=true",
  "http://127.0.0.1.evil.invalid:6806/assets/a.html?iframe=true",
  "http://user@127.0.0.1:6806/assets/a.html?iframe=true",
  "http://user:password@127.0.0.1:6806/assets/a.html?iframe=true",
  base + "/assets-other/a.html?iframe=true",
  base + "/assets/?iframe=true",
  base + "/assets/a.svg?iframe=true",
  base + "/export/a.html?iframe=true",
  base + "/assets/../other.html?iframe=true",
  base + "/assets/%2e%2e/other.html?iframe=true",
  base + "/assets/./a.html?iframe=true",
  base + "/assets//a.html?iframe=true",
  base + "/assets/a%5Cb.html?iframe=true",
  base + "/assets/a%00b.html?iframe=true",
  base + "/assets/a.html",
  base + "/assets/a.html?iframe",
  base + "/assets/a.html?iframe=false",
  base + "/assets/a.html?IFRAME=true",
  base + "/assets/a.html?iframe=true&download=TRUE",
  base + "/assets/a.html?iframe=true&%64ownload=true",
  base + "/assets/a.html?iframe=false&iframe=true",
  base + "/assets/a.html?iframe=true&iframe=false",
  base + "/assets/a.html?iframe=true&iframe=true",
  base + "/assets/a.html?iframe=true&download=false&download=true",
  base + "/assets/a.html?iframe=true;download=true"
]
for value in negatives {
  precondition(!controller.isLocalHTMLAssetIFrameURL(URL(string: value)!), "unsafe URL allowed: " + value)
}

let webView = ViewController.syWebView
let mainURL = URL(string: base + "/stage/build/mobile/")!
webView.url = mainURL
func action(_ value: String = valid) -> WKNavigationAction {
  WKNavigationAction(request: URLRequest(url: URL(string: value)!))
}
func route(_ navigation: WKNavigationAction, in view: WKWebView = ViewController.syWebView)
  -> (WKNavigationActionPolicy, Int, Int) {
  UIApplication.shared.opened = []
  controller.saved = []
  var decisions: [WKNavigationActionPolicy] = []
  controller.webView(view, decidePolicyFor: navigation) { decisions.append($0) }
  precondition(decisions.count == 1, "navigation must settle exactly once")
  return (decisions[0], UIApplication.shared.opened.count, controller.saved.count)
}
precondition(route(action()) == (.allow, 0, 0), "automatic HTML iframe should stay embedded")
var candidate = action()
candidate.targetFrame = WKFrameInfo(true, mainURL.absoluteString)
precondition(route(candidate) == (.cancel, 1, 0), "main-frame attachments still open externally")
candidate.targetFrame = nil
precondition(route(candidate) == (.cancel, 1, 0), "new windows must not qualify as iframes")
candidate = action()
for kind in [WKNavigationType.linkActivated, .formSubmitted, .reload, .backForward] {
  candidate.navigationType = kind
  precondition(route(candidate) == (.cancel, 1, 0), "only automatic loads qualify")
}
candidate = action()
candidate.shouldPerformDownload = true
precondition(route(candidate) == (.cancel, 0, 1), "explicit download must retain Save As")
precondition(route(action(valid + "&download=true")) == (.cancel, 1, 0))
let other = WKWebView()
other.url = mainURL
precondition(route(action(), in: other) == (.cancel, 1, 0), "non-workspace webviews must not qualify")
controller.bootWebView = other
precondition(route(action(), in: other) == (.cancel, 1, 0), "boot iframe must not qualify")
for url in [nil, URL(string: "https://example.com"), URL(string: "http://user@127.0.0.1:6806/")] {
  webView.url = url
  precondition(route(action()) == (.cancel, 1, 0), "top-level context must be trusted")
}
webView.url = mainURL
precondition(route(action(base + "/export/file.zip")) == (.cancel, 1, 0))
candidate = action("https://example.com")
candidate.navigationType = .linkActivated
precondition(route(candidate) == (.cancel, 1, 0))
candidate = action(base + "/assets/file.pdf")
precondition(route(candidate) == (.cancel, 1, 0))
candidate = action(mainURL.absoluteString)
candidate.targetFrame = WKFrameInfo(true, mainURL.absoluteString)
precondition(route(candidate) == (.allow, 0, 0))
print("HTML iframe URL and navigation routing passed")
`;
    const temporary = mkdtempSync(path.join(tmpdir(), "siyuan-html-iframe-"));
    try {
        const file = path.join(temporary, "main.swift");
        const executable = path.join(temporary, process.platform === "win32" ? "test.exe" : "test");
        writeFileSync(file, program);
        execFileSync(compiler, ["-swift-version", "5", file, "-o", executable], {timeout: 60000, windowsHide: true});
        assert.match(execFileSync(executable, [], {encoding: "utf8", timeout: 15000, windowsHide: true}),
            /HTML iframe URL and navigation routing passed/);
    } finally {
        rmSync(temporary, {recursive: true, force: true});
    }
});
