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
print("Native bridge policy: \(checks) checks passed")
