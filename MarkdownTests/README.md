# Standalone Markdown native checks

The repository's Node checks validate bridge coverage, target membership, startup routing, and existing workspace regressions:

```text
node --test tests/*.test.cjs
```

On macOS with Swift installed, run `swift test` from this repository to execute the codec, recovery watermark, corruption preservation, and bounded-read tests. The package excludes UIKit implementations on macOS.

Open `Package.swift` in Xcode and run the `MarkdownNative` package tests on an installed iOS Simulator to include `MarkdownDocumentTests`. These cover actual UIDocument reads and writes, plus injected completion and persistence failures in the native host. They do not start the SiYuan kernel.

Device acceptance still needs Files providers, iCloud offline and delayed writes, security-scoped permission renewal, IME/background transitions, external replacement, and WKWebView content process termination. A provider save receipt does not confirm cloud upload.

The standalone scene avoids workspace and kernel startup. The app still links the Go framework in the same iOS process, so process termination affects all scenes; recovery depends on drafts already persisted in the private Markdown directory. This directory is excluded from OS backup and is not synchronized by SiYuan or encrypted by notebook encryption.

Windows-only source parsing and Node checks cannot establish Swift type correctness, iOS SDK compatibility, or device acceptance.
