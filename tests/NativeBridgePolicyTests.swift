// Run tests/run-native-bridge-tests.sh on a machine with Swift installed.
// The runner prepends the actual Foundation-only policy from ViewController.swift.
let app = URL(string: "http://127.0.0.1:6806/stage/build/mobile/?v=1")!
var checks = 0
func check(_ condition: Bool, _ label: String) {
  precondition(condition, label)
  checks += 1
}
func accepts(
  installed: Bool = true, expectedView: Bool = true, expectedController: Bool = true,
  expectedDelegate: Bool = true, main: Bool = true,
  scheme: String = "http", host: String = "127.0.0.1", port: Int = 6806,
  committed: URL? = app, current: URL? = app, sender: URL? = app
) -> Bool {
  NativeBridgePolicy.acceptsMessage(
    policyInstalled: installed, expectedWebView: expectedView,
    expectedController: expectedController, expectedDelegate: expectedDelegate,
    isMainFrame: main, scheme: scheme, host: host, port: port,
    committedURL: committed, currentURL: current, senderURL: sender)
}
for path in ["/stage/build/mobile/", "/stage/build/app/", "/stage/build/desktop/",
             "/stage/build/mobile/index.html", "/check-auth"] {
  check(NativeBridgePolicy.isTrustedDocument(URL(string: "http://127.0.0.1:6806" + path)), path)
}
for value in ["https://127.0.0.1:6806/stage/build/mobile/",
              "http://localhost:6806/stage/build/mobile/",
              "http://127.0.0.1:6807/stage/build/mobile/",
              "http://127.0.0.1:6806.evil.test/stage/build/mobile/",
              "http://user@127.0.0.1:6806/stage/build/mobile/",
              "http://127.0.0.1:6806/assets/stage/build/mobile/",
              "http://127.0.0.1:6806/stage/build/mobile/plugin.html",
              "http://127.0.0.1:6806/stage/build/mobile/%69ndex.html",
              "http://127.0.0.1:6806/appearance/boot/index.html",
              "http://127.0.0.1:6806/check-auth/extra", "about:blank"] {
  check(!NativeBridgePolicy.isTrustedDocument(URL(string: value)), value)
}
check(accepts(), "legitimate main document bridge")
check(!accepts(installed: false), "policy not installed")
check(!accepts(expectedView: false), "boot/print/other web view")
check(!accepts(expectedController: false), "other content controller")
check(!accepts(expectedDelegate: false), "navigation policy replaced")
check(!accepts(main: false), "iframe, even at the exact same origin")
check(!accepts(scheme: "https"), "wrong security origin scheme")
check(!accepts(host: "evil.test"), "remote frame security origin")
check(!accepts(host: ""), "opaque frame security origin")
check(!accepts(port: 80), "wrong security origin port")
check(!accepts(committed: nil), "navigation/recovery revoked old document")
check(!accepts(current: URL(string: "http://127.0.0.1:6806/check-auth")), "stale UI page")
check(!accepts(sender: URL(string: "http://127.0.0.1:6806/check-auth")), "old sender")
check(!accepts(sender: nil), "missing sender URL")
check(!accepts(sender: URL(string: "http://127.0.0.1:6806/assets/evil.html")), "local untrusted HTML")
check(accepts(current: URL(string: app.absoluteString + "#block")), "hash navigation remains usable")
check(accepts(), "trusted re-commit restores normal bridge")

func navigation(
  source: Bool? = nil, target: Bool? = true, url: URL? = app,
  boot: Bool = false, nativeLoad: Bool = true
) -> NativeBridgePolicy.NavigationSourcePolicy {
  NativeBridgePolicy.navigationSourcePolicy(
    sourceIsMainFrame: source, targetIsMainFrame: target, requestURL: url,
    isBootWebView: boot, isNativeLoad: nativeLoad)
}
// 原生首次加载、启动重试和根路径重定向不依赖来源框架。
for path in ["/", "/stage/build/mobile/", "/stage/build/app/", "/stage/build/desktop/",
             "/stage/build/mobile/index.html", "/check-auth"] {
  check(navigation(url: URL(string: "http://127.0.0.1:6806" + path)) == .inspect, "native load " + path)
}
let bootURL = URL(string: "http://127.0.0.1:6806/appearance/boot/index.html?v=3.8.7&appearance=0")!
check(navigation(url: bootURL, boot: true) == .inspect, "native boot load/retry")
check(navigation(source: true, nativeLoad: false) == .inspect, "main-page navigation keeps existing policy")
check(navigation(source: true, target: nil, nativeLoad: false) == .inspect, "main-page external link keeps existing policy")
// 子框架即使使用主页面地址，也不能进入原生导航处理。
for boot in [false, true] {
  check(navigation(source: false, target: false, boot: boot) == .allowSubframe, "subframe self-navigation")
  check(navigation(source: false, target: true, boot: boot) == .cancel, "subframe cannot target main frame")
  check(navigation(source: false, target: nil, boot: boot) == .cancel, "subframe cannot open new window")
  check(navigation(target: false, boot: boot) == .cancel, "missing source cannot act as subframe")
  check(navigation(target: nil, boot: boot) == .cancel, "missing source cannot open new window")
}
check(navigation(nativeLoad: false) == .cancel, "missing source cannot trigger links, forms, or downloads")
check(navigation(url: nil) == .cancel, "missing request URL")
check(navigation(boot: true) == .cancel, "missing source cannot promote boot view")
check(navigation(url: bootURL) == .cancel, "main view cannot load boot document")
for value in ["https://127.0.0.1:6806/stage/build/mobile/",
              "http://localhost:6806/stage/build/mobile/",
              "http://127.0.0.1:6807/stage/build/mobile/",
              "http://127.0.0.1:6806.evil.test/stage/build/mobile/",
              "http://user@127.0.0.1:6806/stage/build/mobile/",
              "http://user:password@127.0.0.1:6806/appearance/boot/index.html",
              "http://127.0.0.1:6806/assets/file.html",
              "http://127.0.0.1:6806/export/file.html",
              "http://127.0.0.1:6806/stage/build/mobile/plugin.html",
              "http://127.0.0.1:6806/stage/build/mobile/%69ndex.html",
              "http://127.0.0.1:6806/appearance/boot/%69ndex.html",
              "http://127.0.0.1:6806/appearance/boot/index.html/extra",
              "https://example.com/", "about:blank"] {
  for boot in [false, true] {
    check(navigation(url: URL(string: value), boot: boot) == .cancel, "untrusted source-less navigation " + value)
  }
}
print("Native bridge policy: \(checks) checks passed")
