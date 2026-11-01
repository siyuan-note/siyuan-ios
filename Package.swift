// swift-tools-version: 5.7
import PackageDescription

let package = Package(
  name: "MarkdownNative",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "MarkdownNative", targets: ["MarkdownNative"])],
  targets: [
    .target(name: "MarkdownNative", path: "siyuan-ios", sources: ["MarkdownCore.swift", "MarkdownTree.swift", "MarkdownDocument.swift", "MarkdownHost.swift"]),
    .testTarget(name: "MarkdownNativeTests", dependencies: ["MarkdownNative"], path: "MarkdownTests")
  ]
)
