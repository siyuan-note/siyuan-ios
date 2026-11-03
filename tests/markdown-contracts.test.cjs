const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const {test} = require("node:test");

const read = name => readFileSync(join(__dirname, "..", name), "utf8");
const host = read("siyuan-ios/MarkdownHost.swift");
const container = read("siyuan-ios/MarkdownViewController.swift");

test("network rules allow image loads while retaining CSP and native navigation restrictions", () => {
    const source = container.match(/let rules = """([\s\S]*?)"""/)[1];
    const rules = JSON.parse(source);
    assert.equal(rules[0].action.type, "block");
    assert.deepEqual(rules[1].trigger["resource-type"], ["image"]);
    assert.equal(rules[1].action.type, "ignore-previous-rules");
    assert.equal(rules[0].trigger["url-filter"], "^https?://");
    assert.equal(rules[1].trigger["url-filter"], "^https?://");
    assert.match(container, /img-src [^;]*http: https:/);
    assert.match(container, /connect-src 'none'; media-src 'none'; frame-src 'none'/);
});

test("standalone parser uses one exact bundled alias without widening the generic asset root", () => {
    assert.match(container, /percentEncodedPath == "\/vditor\/dist\/js\/lute\/lute\.min\.js"/);
    assert.match(container, /sharedLute \? Self\.appDirectory : Self\.assets/);
    assert.match(container, /sharedLute \? "stage\/protyle\/js\/lute\/lute\.min\.js" : String\(url\.path\.dropFirst\(\)\)/);
    assert.match(container, /guard Self\.inside\(root, file\) else/);
});

test("every shared bridge action is routed in the independent native container", () => {
    for (const action of ["bootstrap", "new", "open", "save-as", "cancel-save-as", "authorize-resources", "resource", "insert-image", "link", "preferences", "confirm", "confirm-close", "recoveries", "recover", "discard-recovery", "state", "response", "tree-state", "tree-list", "tree-choose-root", "tree-save-view", "tree-prepare-open", "tree-commit-open", "tree-cancel-open"]) {
        assert.ok(container.includes(`case "${action}"`), `Missing native action ${action}`);
    }
    for (const action of ["read", "write", "reconcileWrite", "reserveSaveAs", "prepareSaveAs", "commitSaveAs", "releaseSaveAs", "putDraft", "clearDraft", "releaseSession"]) {
        assert.ok(host.includes(`case "${action}"`), `Missing host action ${action}`);
    }
    assert.match(container, /__siyuanMarkdownResponse/);
    assert.match(container, /__siyuanMarkdownCommand/);
    assert.match(container, /command\("background"\)/);
});

test("native Markdown sources are part of the application target and do not start the kernel", () => {
    const project = read("siyuan-ios.xcodeproj/project.pbxproj");
    const sources = project.match(/\/\* Begin PBXSourcesBuildPhase section \*\/([\s\S]*?)\/\* End PBXSourcesBuildPhase section \*\//)[1];
    for (const name of ["MarkdownCore", "MarkdownTree", "MarkdownDocument", "MarkdownHost", "MarkdownSceneDelegate", "MarkdownViewController"]) {
        assert.ok(sources.includes(`${name}.swift in Sources`), `${name} must be compiled`);
        assert.doesNotMatch(read(`siyuan-ios/${name}.swift`), /import Iosk|MobileStartKernel|loadFileURL\(/);
    }
    const app = read("siyuan-ios/AppDelegate.swift");
    const configuration = app.slice(app.indexOf("configurationForConnecting"), app.indexOf("didDiscardSceneSessions"));
    assert.ok(configuration.indexOf("MarkdownSceneDelegate.self") < configuration.indexOf("ORTEnv("));
    assert.match(configuration, /configuration\.storyboard = nil/);
});

test("native scheme and message capabilities are restricted independently of workspace WebKit", () => {
    assert.match(container, /configuration\.websiteDataStore = \.nonPersistent\(\)/);
    assert.match(container, /message\.webView === webView, message\.frameInfo\.isMainFrame/);
    assert.match(container, /message\.frameInfo\.securityOrigin\.host == containerID/);
    assert.match(container, /message\.frameInfo\.request\.url\?\.path == "\/index\.html"/);
    assert.match(container, /connect-src 'none'; media-src 'none'; frame-src 'none'/);
    assert.match(container, /imageFiles\[url\] != nil \|\| directory != nil/);
    assert.match(container, /try grant\.validate\(generation:session\.generation\)/);
    assert.match(container, /try owner\.validateResource\(grant\)/);
    assert.match(container, /owner\.invalidateResource\(grant\)/);
    const workspace = read("siyuan-ios/ViewController.swift");
    assert.match(workspace, /name: "openMarkdownEditor"/);
    assert.doesNotMatch(workspace, /name: "siyuanMarkdown"/);
});

test("tree switching keeps the container origin, reserves before close and rejects stale document results", () => {
    assert.match(container, /let containerID: String/);
    assert.match(container, /private\(set\) var session: MarkdownHost\.Session/);
    assert.match(container, /MarkdownHost\.shared\.create\(url:url,scope:scope\)/);
    assert.match(container, /MarkdownHost\.shared\.sessions\[session\.id\] == nil/);
    assert.match(container, /treeCommitted == ticket/);
    assert.match(container, /documentEpoch \+= 1; self\.session = candidate\.session/);
    assert.match(container, /epoch == documentEpoch \|\| action == "tree-commit-open"/);
    assert.match(container, /resourceGeneration = -1; synchronizeResources\(\)/);
    assert.match(container, /await cancelTreeCandidate\(\)/);
    const tree = read("siyuan-ios/MarkdownTree.swift");
    assert.match(tree, /NSFileCoordinator\.addFilePresenter/);
    assert.match(tree, /Task\.detached\(priority:\.utility\)/);
    assert.match(tree, /files\.count <= 10_000/);
    assert.match(tree, /node\.parents\.count < 64/);
    assert.match(tree, /value\["version"\] as\? Int == 1/);
    assert.match(tree, /expanded\.count <= 256/);
    assert.match(tree, /roots\.count <= 16/);
    assert.match(tree, /\.numeric,\.caseInsensitive/);
    assert.doesNotMatch(tree, /imageFiles|resourceDirectories/);
});

test("private recovery budget, preferences and resource lifetimes remain native contracts", () => {
    const core = read("siyuan-ios/MarkdownCore.swift");
    assert.match(core, /documentLimit = 8 \* 1024 \* 1024/);
    assert.match(core, /recoveryContentLimit = 16 \* 1024 \* 1024/);
    assert.match(host, /maximum:MarkdownCore\.recoveryContentLimit/);
    assert.match(core, /maximum: MarkdownCore\.recoveryContentLimit/);
    assert.match(container, /MarkdownHost\.shared\.preferences\(patch:patch\)/);
    assert.match(container, /guard resourceGeneration != session\.generation/);
    assert.match(core, /selected\.resolvingSymlinksInPath\(\)\.standardizedFileURL == canonical/);
    assert.match(core, /MarkdownCore\.directoryIdentity\(canonical\) == identity/);
});

test("Markdown file types are alternate in-place handlers and the scene has no workspace storyboard", () => {
    const plist = read("siyuan-ios/Info.plist");
    assert.match(plist, /<key>LSSupportsOpeningDocumentsInPlace<\/key>\s*<true\/>/);
    assert.match(plist, /<key>LSHandlerRank<\/key>\s*<string>Alternate<\/string>/);
    assert.match(plist, /<string>md<\/string><string>markdown<\/string>/);
    const scene = plist.match(/<dict>\s*<key>UISceneConfigurationName<\/key>\s*<string>Markdown Configuration<\/string>([\s\S]*?)<\/dict>/)[1];
    assert.match(scene, /MarkdownSceneDelegate/);
    assert.doesNotMatch(scene, /UISceneStoryboardFile|<string>Main<\/string>/);
    assert.ok(plist.indexOf("<string>Default Configuration</string>") < plist.indexOf("<string>Markdown Configuration</string>"),
        "ordinary launches must retain the workspace as their default scene");
});

test("mixed language dictionaries keep string UI labels alongside nested kernel translations", () => {
    assert.match(container, /languageObject\.compactMapValues \{ \$0 as\? String \}/);
    assert.doesNotMatch(container, /JSONSerialization\.jsonObject\(with: bytes\) as\? \[String: String\]/);
});

test("workspace exit remains deferred while Markdown opens or sessions are pending", () => {
    const workspace = read("siyuan-ios/ViewController.swift");
    const exit = workspace.slice(workspace.indexOf("case .exit:"), workspace.indexOf("case .sendNotification:"));
    assert.match(exit, /MarkdownLauncher\.requestWorkspaceExit \{/);
    const launcher = read("siyuan-ios/MarkdownSceneDelegate.swift");
    assert.match(launcher, /guard pending\.isEmpty, !opening, MarkdownHost\.shared\.sessions\.isEmpty else \{ return \}/);
    assert.match(container, /MarkdownLauncher\.finishDeferredExit\(\)/);
});

test("navigation appearance clears a stale Done button and guards non-modal roots before session release", () => {
    const appear = container.slice(container.indexOf("override func viewDidAppear"), container.indexOf("override func viewDidDisappear"));
    assert.match(appear, /else \{ navigationItem\.leftBarButtonItem = nil \}/);
    const close = container.slice(container.indexOf("@objc private func closeEditor"), container.indexOf("func notify"));
    assert.ok(close.indexOf("guard let navigation") < close.indexOf('command("close")'));
    assert.match(close, /navigation\.viewControllers\.first !== self \|\| navigation\.presentingViewController != nil/);
});

test("Save As can follow a manual root, deferring that follow while a tree candidate is reserved", () => {
    const tree = read("siyuan-ios/MarkdownTree.swift");
    assert.match(tree, /if manual && !afterSaveAs \{ return \}/);
    assert.match(container, /if treeCandidate != nil \{ treeFollowAfterCancel = true \}/);
    assert.match(container, /authorizedDirectory:current\?\.scope, afterSaveAs:true/);
    const cancel = container.slice(container.indexOf("private func cancelTreeCandidate"), container.indexOf("private func prepareTreeOpen"));
    assert.match(cancel, /await tree\.follow[^\n]+\n\s+notify\("tree-change"\)/);
});


test("tree public IDs use SiYuan IDs with stable saved expansion mappings", () => {
    const tree = read("siyuan-ios/MarkdownTree.swift");
    assert.match(tree, /let value = MarkdownCore\.newID\(\)/);
    assert.ok(tree.includes('previous?["nodeIds"] as? [String:String] ?? [:]'));
    assert.ok(tree.includes('Set(ids.values).union([rootID])'));
    assert.ok(tree.includes('!ids.values.contains(id)'));
    assert.ok(tree.includes('item["nodeIds"] = nodeIDs.filter { values.contains($0.value) }'));
});

test("the initial bundled index and transparent scroll surface honor saved appearance", () => {
    assert.match(container, /if url\.path == "\/index\.html", let html = String\(data: bytes, encoding: \.utf8\)/);
    assert.match(container, /MarkdownCore\.initialPage\(html, dark: owner\.effectiveDark\)/);
    assert.match(container, /webView\?\.scrollView\.backgroundColor = background/);
    assert.match(container, /return theme == "dark" \|\| theme == "system" && traitCollection\.userInterfaceStyle == \.dark/);
    assert.match(container, /webView\.isOpaque = false/);
});
