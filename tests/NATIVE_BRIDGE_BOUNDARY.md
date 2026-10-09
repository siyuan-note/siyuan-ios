# iOS shared-map native boundary

Base: official `siyuan-note/siyuan-ios` main, `23bf741d644ed7ce7fd7986a5de75f41fc9e94c9`.
The remote has no `dev` branch. No native map or additional map WebView is introduced.

## Contract

The shared Web host may await:

```js
await window.webkit.messageHandlers.getAVMapNativeBoundary.postMessage(null)
// { version: 1, enabled: true }
```

This is a native reply handler, not a user-agent guess or a static JavaScript marker.
The handler uses the same authorization gate as all thirteen existing native handlers.
A response is returned only when the navigation delegate and message receiver are installed,
the originating WebView is the main app WebView, the real WebKit frame is the main frame,
its security origin is exactly `http://127.0.0.1:6806`, and its document URL matches the
committed, currently displayed, allowlisted application/authentication document.
Do not cache an affirmative result across documents or use it to attest network isolation.

The boot and print WebViews remain separate and receive neither the app's handlers nor
this capability. A subframe can navigate itself, but cannot promote itself into the main
frame/new window, open an external app, initiate a native asset download, or activate the
boot-to-main transition. Main-frame redirects must finish at an allowlisted app document.

The gate is revoked for top-level provisional navigation, programmatic reload/recovery,
and WebContent process termination; a trusted commit restores it. A native notification
callback already in progress is also bound to the navigation generation. Hash-only changes
keep the same document usable. Existing bridge names and message payloads are unchanged.

## Threat-model limit

`WKFrameInfo` does not supply a cryptographically unique document-instance identifier.
The unchanged legacy payload format cannot distinguish every already-queued message from
an earlier *trusted main document* at the exact same URL after a later same-URL commit.
This change does not claim that stronger property. It does reject messages during the
revoked interval, stale different-URL messages, other WebViews, and every non-main frame
regardless of its origin. Opaque remote map frames cannot call the main-frame bridge.

This does not add cookie/network isolation. WKWebView has no credentialless iframe API.
The shared host must independently apply its locked CSP and sandboxed opaque iframe design.
No permission to call kernel APIs or to carry ambient credentials follows from this capability.

## Automated checks

- `python3 -m unittest discover -s tests -p 'test_*.py' -v`: source-wiring checks only.
- `tests/run-native-bridge-tests.sh`: runs the actual extracted Foundation-only Swift policy
  against trusted UI, authentication, spoofed origins, opaque frames, subframes, print/boot
  views, local untrusted HTML, stale URLs, revoked navigation, and hash navigation.
  Exit 77 explicitly means Swift is unavailable, not success.
- Xcode build and real WKWebView behavior must be checked on macOS/iOS. No Swift compiler,
  Xcode, iOS simulator, or physical-device connection was available in this Linux workspace.

## Required simulator/device checks before release

1. Launch normally on iPhone and iPad; test mobile/app layout, `/check-auth`, boot retry,
   watchdog recovery, background/foreground, reload, back/forward, and WebContent termination.
   The trusted main document must receive the capability after each successful commit.
2. Verify all existing actions from the real main page, including status bar, clipboard,
   openLink, export V1/V2, purchase, print, exit, notifications/cancel, vibrate, OIDC, and
   startKernelFast wherever the frontend still uses it. Use sandbox purchase testing.
3. In same-origin, cross-origin, opaque sandboxed, and `about:blank` child frames, attempt
   every native handler and the capability. None must cause a native side effect or an
   affirmative reply, including children with a copied capability result.
4. From those frames attempt `_top`, `_blank`, `window.open`, top location replacement,
   native asset downloads, and a link with a real user gesture. No native/main-page action
   may occur. Ordinary iframe self-navigation must still work.
5. Navigate the main document to untrusted local assets/plugins and external pages,
   including redirects, encoded paths, alternate ports/hosts, and origin-prefix lookalikes.
   They must not become privileged app documents.
6. Queue a main-page capability/action while starting navigation, fail/cancel that navigation,
   then recover and repeat. Check revoked and stale different-URL messages are denied and
   the newly committed trusted document works. Verify normal hash navigation still works.
7. Exercise remote map loading with the shared host's explicit confirmation, CSP, and opaque
   sandbox. Assert cookies/kernel endpoints/storage cannot be reached under that separate
   host policy. This repository's capability alone is not evidence for those network claims.
