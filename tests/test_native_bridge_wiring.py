"""Source-wiring checks only. These do not replace Swift or WKWebView integration tests."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).parents[1] / 'siyuan-ios/ViewController.swift').read_text()

class NativeBridgeWiring(unittest.TestCase):
    def test_common_guard_precedes_every_existing_dispatch(self):
        self.assertRegex(SOURCE, r'guard acceptsNativeBridgeMessage\(userContentController, message\) else \{ return \}\s+switch ScriptMessageName')
        self.assertEqual(SOURCE.count('switch ScriptMessageName'), 1)

    def test_all_registered_legacy_handlers_still_have_cases(self):
        names = re.findall(r'self, name: ScriptMessageName\.(\w+)\.rawValue', SOURCE)
        self.assertEqual(len(names), 13)
        for name in names:
            self.assertIn('case .' + name + ':', SOURCE)

    def test_capability_is_native_reply_with_same_gate(self):
        self.assertIn('addScriptMessageHandler(\n      self, contentWorld: .page, name: Self.mapBoundaryHandlerName)', SOURCE)
        self.assertRegex(SOURCE, r'guard message.name == Self.mapBoundaryHandlerName,\s+acceptsNativeBridgeMessage')
        self.assertIn('let capability: [String: Any] = ["version": 1, "enabled": true]', SOURCE)
        self.assertIn('replyHandler(capability, nil)', SOURCE)

    def test_real_webkit_source_metadata_is_used(self):
        for source in ['message.webView === webView', 'message.frameInfo.isMainFrame',
                       'message.frameInfo.securityOrigin', 'message.frameInfo.request.url',
                       'controller === webView.configuration.userContentController',
                       'webView.navigationDelegate === self']:
            self.assertIn(source, SOURCE)

    def test_subframes_exit_before_native_navigation_side_effects(self):
        start = SOURCE.index('decidePolicyFor navigationAction:')
        end = SOURCE.index('decidePolicyFor navigationResponse:')
        body = SOURCE[start:end]
        gate = body.index('if !navigationAction.sourceFrame.isMainFrame')
        self.assertIn('navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel', body)
        self.assertLess(gate, body.index('navigationAction.shouldPerformDownload'))
        self.assertLess(gate, body.index('navigateToMainPage()'))
        self.assertLess(gate, body.index('UIApplication.shared.open'))

    def test_only_top_response_can_download(self):
        self.assertIn('if webView === ViewController.syWebView, navigationResponse.isForMainFrame,', SOURCE)

    def test_commit_and_provisional_navigation_update_lifetime(self):
        self.assertIn('committedBridgeDocument = NativeBridgePolicy.isTrustedDocument(webView.url) ? webView.url : nil', SOURCE)
        self.assertRegex(SOURCE, r'didStartProvisionalNavigation navigation: WKNavigation!\) \{\s+if webView === ViewController.syWebView \{ revokeNativeBridgeDocument\(\) \}')
        self.assertIn('revokeNativeBridgeDocument()\n    ViewController.syWebView.load', SOURCE)
        self.assertIn('revokeNativeBridgeDocument()\n    mainPageReady = false\n    webViewRecoveryScheduled = true', SOURCE)

    def test_deinit_revokes_policy(self):
        self.assertRegex(SOURCE, r'deinit \{\s+revokeNativeBridgeDocument\(\)\s+nativeBridgePolicyInstalled = false')

    def test_async_notification_does_not_target_new_document(self):
        self.assertIn('self.bridgeNavigationGeneration == generation', SOURCE)

if __name__ == '__main__':
    unittest.main()
