# iOS 本地构建与调试

- 日常开发、问题复现和真机测试都从现有工程启动。在本仓库根目录运行 `open siyuan-ios.xcodeproj`，在 Xcode 中选择 `siyuan-ios` 和目标设备，按 ⌘R 构建并运行。命令行测试也使用这份工程。
- 工程使用本仓库的 `app/` 前端资源，并通过相对路径引用同级主仓库的 `../siyuan/kernel/ios/iosk.xcframework`。优先使用已有产物，缺少资源时按 [README.md](README.md) 补齐对应部分。
- 复用现有工作目录和 Xcode、Go 的构建缓存。不要为了常规构建或测试在临时目录复制两套源码、另建测试工程，或重新下载全套依赖。
