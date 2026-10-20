const assert = require("node:assert/strict");
const {execFileSync, spawnSync} = require("node:child_process");
const {readFileSync, writeFileSync, mkdtempSync, rmSync} = require("node:fs");
const {tmpdir} = require("node:os");
const path = require("node:path");
const {test} = require("node:test");

const source = readFileSync(path.join(__dirname, "../siyuan-ios/ViewController.swift"), "utf8");
const compiler = process.env.SWIFTC || "swiftc";
const available = spawnSync(compiler, ["--version"], {windowsHide: true}).status === 0;

test("startup stays dark in either system appearance and hands off to the selected theme", {
    skip: available ? false : "Swift compiler unavailable; run on the iOS build host",
}, () => {
    const viewDidLoad = source.slice(source.indexOf("override func viewDidLoad()"));
    const startup = viewDidLoad.slice(viewDidLoad.indexOf("    // "), viewDidLoad.indexOf("    initKernel()"));
    const method = name => {
        const match = source.match(new RegExp(`  private func ${name}\\([^]*?\\n  }`));
        assert.ok(match, name);
        return match[0].replace("private func", "func");
    };
    const program = `import Foundation
enum UIUserInterfaceStyle { case light, dark }
struct UITraitCollection { var userInterfaceStyle: UIUserInterfaceStyle }
struct UIColor: Equatable {
  let red: Double, green: Double, blue: Double, alpha: Double
  static let systemBackground = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
  func resolvedColor(with traits: UITraitCollection) -> UIColor {
    traits.userInterfaceStyle == .dark ? UIColor(red: 0, green: 0, blue: 0, alpha: 1) : self
  }
}
class View { var backgroundColor: UIColor? }
class WebView: View {
  let scrollView = View()
  var navigationDelegate: Int?
  var removed = false
  func stopLoading() {}
  func removeFromSuperview() { removed = true }
}
class ViewController {
  static let syWebView = WebView()
  let view = View()
  var traitCollection = UITraitCollection(userInterfaceStyle: .light)
  var isDarkStyle = false
  var bootWebView: WebView?
  var pendingStatusBarAppearance: (color: UIColor, isDark: Bool)?
  func setNeedsStatusBarAppearanceUpdate() {}
  func start() { ${startup} }
  ${method("applyStatusBarAppearance")}
  ${method("removeBootWebView")}
}
let startupColor = UIColor(red: 30 / 255.0, green: 30 / 255.0, blue: 30 / 255.0, alpha: 1)
for system in [UIUserInterfaceStyle.light, .dark] {
  for darkTheme in [false, true] {
    let controller = ViewController()
    controller.traitCollection.userInterfaceStyle = system
    controller.start()
    precondition(controller.isDarkStyle && controller.view.backgroundColor == startupColor,
      "system appearance changed the startup background")
    precondition(ViewController.syWebView.backgroundColor == startupColor)
    precondition(ViewController.syWebView.scrollView.backgroundColor == startupColor)
    let boot = WebView()
    controller.bootWebView = boot
    let theme = darkTheme ? startupColor : UIColor.systemBackground
    controller.pendingStatusBarAppearance = (theme, darkTheme)
    precondition(controller.view.backgroundColor == startupColor)
    controller.removeBootWebView()
    precondition(boot.removed && controller.bootWebView == nil)
    precondition(controller.pendingStatusBarAppearance == nil)
    precondition(controller.view.backgroundColor == theme && controller.isDarkStyle == darkTheme)
    precondition(ViewController.syWebView.backgroundColor == theme)
    precondition(ViewController.syWebView.scrollView.backgroundColor == theme)
  }
}
print("startup background and selected-theme handoff passed")
`;
    const temporary = mkdtempSync(path.join(tmpdir(), "siyuan-startup-appearance-"));
    try {
        const file = path.join(temporary, "main.swift");
        const executable = path.join(temporary, process.platform === "win32" ? "test.exe" : "test");
        writeFileSync(file, program);
        execFileSync(compiler, ["-swift-version", "5", file, "-o", executable], {timeout: 60000, windowsHide: true});
        assert.match(execFileSync(executable, [], {encoding: "utf8", timeout: 15000, windowsHide: true}),
            /startup background and selected-theme handoff passed/);
    } finally {
        rmSync(temporary, {recursive: true, force: true});
    }
});

test("the system launch screen uses the same dark background as kernel startup", () => {
    const storyboard = readFileSync(path.join(__dirname, "../siyuan-ios/Base.lproj/LaunchScreen.storyboard"), "utf8");
    const color = storyboard.match(/<color key="backgroundColor"([^>]+)\/>/)[1];
    assert.doesNotMatch(color, /systemColor=/);
    for (const channel of ["red", "green", "blue"]) {
        const value = Number(color.match(new RegExp(`${channel}="([^"]+)"`))[1]);
        assert.ok(Math.abs(value - 30 / 255) < 1e-10, channel);
    }
    assert.match(color, /alpha="1"/);
});
