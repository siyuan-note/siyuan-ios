# 📘 思源笔记iOS完整打包流程

**版本**: v1.0  
**更新时间**: 2026年2月16日  
**适用版本**: SiYuan 3.5.x  
**验证状态**: ✅ 已验证可用

---

## 📋 目录

1. [前提条件](#前提条件)
2. [完整打包步骤](#完整打包步骤)
3. [iOS内核编译详解](#ios内核编译详解)
4. [一键自动化脚本](#一键自动化脚本)
5. [快速更新流程](#快速更新流程)
6. [验证方法](#验证方法)
7. [故障排除](#故障排除)
8. [技术原理](#技术原理)
9. [资源统计](#资源统计)
10. [多语言支持](#多语言支持)

---

## 🔧 前提条件

### 必需工具

| 工具 | 版本要求 | 安装命令 |
|------|----------|----------|
| **Go** | >= 1.20 | `brew install go` |
| **gomobile** | latest | `go install golang.org/x/mobile/cmd/gomobile@latest` |
| **pnpm** | >= 8.0 | `brew install pnpm` |
| **Xcode** | >= 15.0 | App Store 下载 |
| **Command Line Tools** | - | `xcode-select --install` |

### 环境检查

```bash
# 检查Go版本
go version  # 应该 >= 1.20

# 检查CGO
go env CGO_ENABLED  # 必须是 1

# 检查gomobile
~/go/bin/gomobile version

# 检查pnpm
pnpm --version

# 检查Xcode
xcode-select -p  # 应该输出: /Applications/Xcode.app/Contents/Developer
```

### 初始化gomobile（首次使用）

```bash
~/go/bin/gomobile init
```

---

## 🎯 完整打包步骤

### 步骤1: 删除iOS项目中的旧资源

```bash
cd /Users/rysisun/Documents/siyuan/siyuan-ios/app
rm -rf *
```

**目的**: 确保无旧文件残留，避免资源冲突

---

### 步骤2: 重新编译前端移动版

```bash
cd /Users/rysisun/Documents/siyuan/siyuan/app

# 确保依赖已安装
pnpm install

# 生产环境编译
pnpm run build:mobile
```

**输出**: 
- `stage/build/mobile/index.html` (3.5KB)
- `stage/build/mobile/main.js` (1.7MB)
- `stage/build/mobile/base.css` (140KB)

**编译时间**: 约3-5秒  
**优化效果**: 比开发模式小 **85%**

---

### ⭐ 步骤3: 重新编译iOS内核（关键步骤）

```bash
cd /Users/rysisun/Documents/siyuan/siyuan/kernel

# 使用gomobile交叉编译iOS内核
~/go/bin/gomobile bind \
  --tags fts5 \
  -ldflags '-s -w' \
  -v \
  -o ./ios/iosk.xcframework \
  -target=ios \
  ./mobile/
```

**重要参数**:
- `--tags fts5`: 启用SQLite FTS5全文搜索支持
- `-ldflags '-s -w'`: 优化二进制大小
  - `-s`: 去除符号表（减少约20%大小）
  - `-w`: 去除DWARF调试信息（再减少约10%大小）
- `-v`: 显示详细编译过程
- `-o ./ios/iosk.xcframework`: 输出XCFramework格式
- `-target=ios`: 同时编译真机(arm64)和模拟器(arm64+x86_64)架构
- `./mobile/`: Go移动端绑定包路径

**编译时间**: 约1.5分钟（首次可能更长）  
**输出大小**: 285MB  
**架构支持**:
- ✅ ios-arm64: iPhone/iPad真机（A系列芯片）
- ✅ arm64-simulator: Apple Silicon Mac上的模拟器
- ✅ x86_64-simulator: Intel Mac上的模拟器

---

### 步骤4: 复制内核到iOS项目

```bash
# 删除旧framework
rm -rf /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework

# 复制新编译的framework
cp -R /Users/rysisun/Documents/siyuan/siyuan/kernel/ios/iosk.xcframework \
      /Users/rysisun/Documents/siyuan/siyuan-ios/
```

**验证**:
```bash
ls -la /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework/
# 应该看到: Info.plist, ios-arm64/, ios-arm64_x86_64-simulator/

du -sh /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework
# 应该显示: 285M
```

---

### 步骤5: 拷贝前端资源（包括多语言）

```bash
cd /Users/rysisun/Documents/siyuan/siyuan/app
cp -R appearance stage guide changelogs \
      /Users/rysisun/Documents/siyuan/siyuan-ios/app/
```

**拷贝内容**:
- `appearance/` (16MB) - 外观、主题、**15种语言**
- `stage/` (34MB) - 编译后的前端文件
- `guide/` (16MB) - 用户指南
- `changelogs/` (2.2MB) - 更新日志

**验证多语言**:
```bash
ls /Users/rysisun/Documents/siyuan/siyuan-ios/app/appearance/langs/*.json | wc -l
# 应该输出: 15
```

---

### 步骤6: 重新编译iOS应用

```bash
cd /Users/rysisun/Documents/siyuan/siyuan-ios

xcodebuild -project siyuan-ios.xcodeproj \
  -scheme siyuan-ios \
  -sdk iphonesimulator \
  -configuration Debug \
  clean build
```

**编译时间**: 约12-15秒  
**输出**: `BUILD SUCCEEDED`

---

### 步骤7: 启动模拟器

```bash
# 启动模拟器
xcrun simctl boot "iPhone 17 Pro Max"

# 打开模拟器窗口
open -a Simulator
```

---

### 步骤8: 安装并运行应用

```bash
# 停止旧应用
xcrun simctl terminate "iPhone 17 Pro Max" com.ld246.siyuan 2>/dev/null || true

# 安装新应用
xcrun simctl install "iPhone 17 Pro Max" \
  "/Users/rysisun/Library/Developer/Xcode/DerivedData/siyuan-ios-adeicoigpcvwfpgzzmjyfbhdwopk/Build/Products/Debug-iphonesimulator/siyuan-ios.app"

# 启动应用
xcrun simctl launch "iPhone 17 Pro Max" com.ld246.siyuan
```

**验证运行**:
```bash
# 检查进程
ps aux | grep siyuan-ios | grep -v grep

# 检查端口
lsof -i :6806

# 测试API
curl http://127.0.0.1:6806/api/system/version
```

---

## 📊 各步骤耗时统计

| 步骤 | 操作 | 预计时间 |
|------|------|----------|
| 1 | 删除旧资源 | 1秒 |
| 2 | 编译前端 | 3-5秒 |
| **3** | **编译iOS内核** | **60-100秒** ⏰ |
| 4 | 复制内核 | 2-3秒 |
| 5 | 拷贝资源 | 3-5秒 |
| 6 | 编译iOS应用 | 12-15秒 |
| 7 | 启动模拟器 | 3-5秒 |
| 8 | 安装运行 | 5-8秒 |
| **总计** | | **2-3分钟** |

**最耗时的步骤**: iOS内核编译（gomobile）

---

## 🔧 iOS内核编译详解

### Framework结构

```
iosk.xcframework/
├── Info.plist                      # Framework元数据
├── ios-arm64/                      # 真机架构 (iPhone/iPad)
│   └── Iosk.framework/
│       ├── Headers/
│       ├── Info.plist
│       ├── Iosk (二进制, ~142MB)
│       └── Modules/
└── ios-arm64_x86_64-simulator/     # 模拟器架构
    └── Iosk.framework/
        ├── Headers/
        ├── Info.plist
        ├── Iosk (二进制, ~143MB，包含arm64+x86_64)
        └── Modules/
```

### XCFramework格式说明

- **XCFramework**: Apple推荐的跨架构Framework格式
- **优势**: 
  - 一个文件同时支持真机和模拟器
  - 自动选择合适的架构
  - 不需要手动lipo合并
  - 支持不同平台（iOS、macOS、watchOS等）

### 何时需要重新编译内核

#### 必须重新编译 ✅
1. 修改了Go内核代码（kernel/目录下的.go文件）
2. 升级了Go版本
3. 修改了编译标签或链接参数
4. 首次配置iOS开发环境

#### 不需要重新编译 ❌
1. 仅修改了前端代码（app/src/目录）
2. 仅修改了Swift代码（siyuan-ios/目录）
3. 仅修改了资源文件（appearance、stage等）
4. 仅修改了配置文件

### 内核开发流程

```
1. 修改Go代码 (kernel/*.go)
   ↓
2. 编译iOS内核 (gomobile bind, ~1.5分钟)
   ↓
3. 复制到iOS项目 (cp iosk.xcframework)
   ↓
4. 编译iOS应用 (xcodebuild, ~15秒)
   ↓
5. 安装运行测试 (xcrun simctl)
```

### 示例：添加新API

**步骤1**: 修改Go代码
```go
// kernel/mobile/kernel.go
func NewAPI() string {
    return "Hello from new API"
}
```

**步骤2**: 重新编译内核
```bash
cd /Users/rysisun/Documents/siyuan/siyuan/kernel
~/go/bin/gomobile bind --tags fts5 -ldflags '-s -w' -v \
  -o ./ios/iosk.xcframework -target=ios ./mobile/
```

**步骤3**: 复制到iOS项目
```bash
rm -rf /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework
cp -R ./ios/iosk.xcframework /Users/rysisun/Documents/siyuan/siyuan-ios/
```

**步骤4**: 在Swift中调用
```swift
// ViewController.swift
import Iosk

let result = IoskNewAPI()
print(result)  // 输出: "Hello from new API"
```

---

## 🤖 一键自动化脚本

保存为 `rebuild-ios-full.sh`:

```bash
#!/bin/bash
set -e

echo "🚀 开始完整iOS打包流程..."
echo ""

# 1. 清空旧资源
echo "🗑️  [1/8] 清空旧资源..."
cd /Users/rysisun/Documents/siyuan/siyuan-ios/app
rm -rf *

# 2. 编译前端
echo "📦 [2/8] 编译前端（生产模式）..."
cd /Users/rysisun/Documents/siyuan/siyuan/app
pnpm run build:mobile

# 3. 编译iOS内核
echo "🔧 [3/8] 编译iOS内核（gomobile，约1.5分钟）..."
cd /Users/rysisun/Documents/siyuan/siyuan/kernel
~/go/bin/gomobile bind \
  --tags fts5 \
  -ldflags '-s -w' \
  -v \
  -o ./ios/iosk.xcframework \
  -target=ios \
  ./mobile/

# 4. 复制内核
echo "📲 [4/8] 复制内核到iOS项目..."
rm -rf /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework
cp -R ./ios/iosk.xcframework /Users/rysisun/Documents/siyuan/siyuan-ios/

# 5. 拷贝前端资源
echo "📋 [5/8] 拷贝前端资源（包括多语言）..."
cd /Users/rysisun/Documents/siyuan/siyuan/app
cp -R appearance stage guide changelogs /Users/rysisun/Documents/siyuan/siyuan-ios/app/

# 6. 验证多语言
echo "🌍 [6/8] 验证多语言..."
LANG_COUNT=$(ls /Users/rysisun/Documents/siyuan/siyuan-ios/app/appearance/langs/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "   ✓ 发现 $LANG_COUNT 种语言文件"

# 7. 编译iOS应用
echo "🔨 [7/8] 编译iOS应用..."
cd /Users/rysisun/Documents/siyuan/siyuan-ios
xcodebuild -project siyuan-ios.xcodeproj \
  -scheme siyuan-ios \
  -sdk iphonesimulator \
  -configuration Debug \
  clean build

# 8. 启动并安装
echo "📱 [8/8] 启动模拟器并安装应用..."
xcrun simctl boot "iPhone 17 Pro Max" 2>/dev/null || echo "   模拟器已运行"
open -a Simulator
sleep 3

xcrun simctl terminate "iPhone 17 Pro Max" com.ld246.siyuan 2>/dev/null || true
xcrun simctl install "iPhone 17 Pro Max" \
  "/Users/rysisun/Library/Developer/Xcode/DerivedData/siyuan-ios-adeicoigpcvwfpgzzmjyfbhdwopk/Build/Products/Debug-iphonesimulator/siyuan-ios.app"

xcrun simctl launch "iPhone 17 Pro Max" com.ld246.siyuan

echo ""
echo "🎉 ================================"
echo "✅ 完成！应用已成功运行"
echo "   - iOS内核: 285MB (真机+模拟器)"
echo "   - 前端资源: 68.2MB"
echo "   - 语言支持: $LANG_COUNT 种"
echo "   - 编译模式: Production"
echo "🎉 ================================"
```

**使用方法**:
```bash
cd /Users/rysisun/Documents/siyuan/siyuan-ios
chmod +x rebuild-ios-full.sh
./rebuild-ios-full.sh
```

**预计总时间**: 约2-3分钟

---

## ⚡ 快速更新流程

### 场景1: 仅修改了Go内核代码

```bash
# 1. 编译内核
cd /Users/rysisun/Documents/siyuan/siyuan/kernel
~/go/bin/gomobile bind --tags fts5 -ldflags '-s -w' -v \
  -o ./ios/iosk.xcframework -target=ios ./mobile/

# 2. 复制内核
rm -rf /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework
cp -R ./ios/iosk.xcframework /Users/rysisun/Documents/siyuan/siyuan-ios/

# 3. 编译iOS应用
cd /Users/rysisun/Documents/siyuan/siyuan-ios
xcodebuild -project siyuan-ios.xcodeproj -scheme siyuan-ios build

# 4. 安装运行
xcrun simctl install "iPhone 17 Pro Max" \
  "/Users/rysisun/Library/Developer/Xcode/DerivedData/siyuan-ios-*/Build/Products/Debug-iphonesimulator/siyuan-ios.app"
xcrun simctl launch "iPhone 17 Pro Max" com.ld246.siyuan
```

**耗时**: 约2分钟

---

### 场景2: 仅修改了前端代码

```bash
# 1. 编译前端
cd /Users/rysisun/Documents/siyuan/siyuan/app
pnpm run build:mobile

# 2. 拷贝stage
rm -rf /Users/rysisun/Documents/siyuan/siyuan-ios/app/stage
cp -R stage /Users/rysisun/Documents/siyuan/siyuan-ios/app/

# 3. 编译iOS应用
cd /Users/rysisun/Documents/siyuan/siyuan-ios
xcodebuild -project siyuan-ios.xcodeproj -scheme siyuan-ios build

# 4. 安装运行
xcrun simctl install "iPhone 17 Pro Max" \
  "/Users/rysisun/Library/Developer/Xcode/DerivedData/siyuan-ios-*/Build/Products/Debug-iphonesimulator/siyuan-ios.app"
xcrun simctl launch "iPhone 17 Pro Max" com.ld246.siyuan
```

**耗时**: 约20秒

---

### 场景3: 仅修改了Swift代码

```bash
# 1. 编译iOS应用
cd /Users/rysisun/Documents/siyuan/siyuan-ios
xcodebuild -project siyuan-ios.xcodeproj -scheme siyuan-ios build

# 2. 安装运行
xcrun simctl install "iPhone 17 Pro Max" \
  "/Users/rysisun/Library/Developer/Xcode/DerivedData/siyuan-ios-*/Build/Products/Debug-iphonesimulator/siyuan-ios.app"
xcrun simctl launch "iPhone 17 Pro Max" com.ld246.siyuan

# 或者直接在Xcode中 Command + R
```

**耗时**: 约15秒

---

### 场景4: 仅更新多语言

```bash
cd /Users/rysisun/Documents/siyuan/siyuan/app
rm -rf /Users/rysisun/Documents/siyuan/siyuan-ios/app/appearance/langs
cp -R appearance/langs /Users/rysisun/Documents/siyuan/siyuan-ios/app/appearance/

cd /Users/rysisun/Documents/siyuan/siyuan-ios
xcodebuild -project siyuan-ios.xcodeproj -scheme siyuan-ios build
xcrun simctl install "iPhone 17 Pro Max" \
  "/Users/rysisun/Library/Developer/Xcode/DerivedData/siyuan-ios-*/Build/Products/Debug-iphonesimulator/siyuan-ios.app"
```

**耗时**: 约15秒

---

## 🔍 验证方法

### 验证内核编译成功

```bash
# 检查文件存在
ls /Users/rysisun/Documents/siyuan/siyuan/kernel/ios/iosk.xcframework

# 检查大小
du -sh /Users/rysisun/Documents/siyuan/siyuan/kernel/ios/iosk.xcframework
# 应该约285MB

# 检查架构
ls /Users/rysisun/Documents/siyuan/siyuan/kernel/ios/iosk.xcframework/
# 应该看到: ios-arm64/, ios-arm64_x86_64-simulator/

# 检查二进制架构
lipo -info iosk.xcframework/ios-arm64/Iosk.framework/Iosk
lipo -info iosk.xcframework/ios-arm64_x86_64-simulator/Iosk.framework/Iosk
```

---

### 验证内核已复制

```bash
ls -la /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework/
du -sh /Users/rysisun/Documents/siyuan/siyuan-ios/iosk.xcframework
```

---

### 验证资源完整

```bash
# 检查多语言（应该15个）
ls /Users/rysisun/Documents/siyuan/siyuan-ios/app/appearance/langs/*.json | wc -l

# 检查前端编译文件
ls /Users/rysisun/Documents/siyuan/siyuan-ios/app/stage/build/mobile/
# 应该看到: index.html, main.js, base.css

# 检查所有资源目录
ls -lh /Users/rysisun/Documents/siyuan/siyuan-ios/app/
# 应该看到: appearance/, stage/, guide/, changelogs/
```

---

### 验证应用运行

```bash
# 检查进程
ps aux | grep siyuan-ios | grep -v grep

# 检查端口
lsof -i :6806

# 测试API版本
curl http://127.0.0.1:6806/api/system/version
# 应该返回: {"code":0,"msg":"","data":"3.5.2"}

# 测试启动进度
curl http://127.0.0.1:6806/api/system/bootProgress
# 应该返回: {"code":0,"msg":"","data":{"details":"...","progress":100}}

# 截图验证界面
xcrun simctl io "iPhone 17 Pro Max" screenshot ~/Desktop/siyuan-ios-screenshot.png
```

---

## 🐛 故障排除

### Q1: gomobile编译失败

**错误信息**: `command not found: gomobile`

**解决**:
```bash
# 安装gomobile
go install golang.org/x/mobile/cmd/gomobile@latest

# 初始化gomobile
~/go/bin/gomobile init
```

**其他可能错误**:
- CGO未启用: `export CGO_ENABLED=1`
- Go版本过低: 升级到最新版Go (`brew upgrade go`)
- Xcode未安装: 安装完整的Xcode

---

### Q2: 内核编译超时

**原因**: 首次编译需要下载依赖，时间较长  
**解决**: 耐心等待，通常1-3分钟

**如果一直卡住**:
```bash
# 清理Go缓存
go clean -cache -modcache

# 重新下载依赖
cd /Users/rysisun/Documents/siyuan/siyuan/kernel
go mod download

# 重试编译
~/go/bin/gomobile bind --tags fts5 -ldflags '-s -w' -v \
  -o ./ios/iosk.xcframework -target=ios ./mobile/
```

---

### Q3: CGO编译错误

```bash
# 确保CGO已启用
export CGO_ENABLED=1

# 检查验证
go env CGO_ENABLED  # 应该输出: 1

# 永久设置
echo 'export CGO_ENABLED=1' >> ~/.zshrc
source ~/.zshrc
```

---

### Q4: 找不到iOS SDK

```bash
# 安装Xcode Command Line Tools
xcode-select --install

# 验证Xcode路径
xcode-select -p
# 输出: /Applications/Xcode.app/Contents/Developer

# 如果路径不对，重新设置
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

### Q5: 架构不匹配错误

**错误信息**: `framework not found for architecture`

**检查framework架构**:
```bash
lipo -info iosk.xcframework/ios-arm64/Iosk.framework/Iosk
lipo -info iosk.xcframework/ios-arm64_x86_64-simulator/Iosk.framework/Iosk
```

**解决**: 确保使用 `-target=ios` 而不是单独的架构

---

### Q6: 多语言不显示

**检查**:
```bash
ls /Users/rysisun/Documents/siyuan/siyuan-ios/app/appearance/langs/
# 应该看到15个.json文件
```

**解决**: 重新拷贝appearance目录

---

### Q7: 前端文件缺失

**错误**: `404 Not Found` for `/appearance/boot/index.html`

**检查**:
```bash
ls /Users/rysisun/Documents/siyuan/siyuan-ios/app/stage/build/mobile/
# 应该看到: index.html, main.js, base.css
```

**解决**: 确保执行了 `pnpm run build:mobile` (不是 `dev:mobile`)

---

### Q8: 应用白屏

**可能原因**:
1. stage/build/mobile/ 目录不存在
2. 使用了dev版本而非build版本
3. 资源路径不对
4. 内核未启动（6806端口未监听）

**解决**: 执行完整重新打包流程

---

### Q9: iOS应用编译失败

**清理缓存**:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/siyuan-ios-*
cd /Users/rysisun/Documents/siyuan/siyuan-ios
xcodebuild clean
```

**重新编译**:
```bash
xcodebuild -project siyuan-ios.xcodeproj \
  -scheme siyuan-ios \
  -sdk iphonesimulator \
  -configuration Debug \
  clean build
```

---

### Q10: 端口占用（6806）

**错误**: `bind: address already in use`

**检查占用**:
```bash
lsof -i :6806
```

**解决**:
```bash
# 终止占用进程
kill -9 <PID>

# 或终止所有思源内核进程
pkill -f "SiYuan-Kernel"
```

---

## 🎓 技术原理

### Go Mobile绑定原理

```
Swift代码
  ↓ (import Iosk)
Objective-C桥接层
  ↓ (Generated by gomobile)
C接口层 (FFI)
  ↓ (CGO)
Go内核代码
```

1. **CGO桥接**: Go代码通过CGO编译为C兼容的动态库
2. **Objective-C封装**: gomobile自动生成Objective-C接口
3. **Swift调用**: Swift通过桥接头文件调用Objective-C接口

---

### Swift调用Go函数示例

**Swift代码** (ViewController.swift):
```swift
import Iosk

// 调用Go函数启动内核
Iosk.MobileStartKernel(
    "ios",                          // container
    Bundle.main.resourcePath,       // appDir
    urls[0].path,                   // workspaceBaseDir
    TimeZone.current.identifier,    // timezoneID
    getIP(),                        // localIPs
    "zh_CN",                        // lang
    UIDevice.current.systemVersion  // osVer
)
```

**对应的Go函数** (kernel/mobile/kernel.go):
```go
func StartKernel(container, appDir, workspaceBaseDir, 
                 timezoneID, localIPs, lang, osVer string) {
    // 内核启动逻辑
    util.BootMobile(container, appDir, workspaceBaseDir, lang)
    model.InitConf()
    model.InitAppearance()
    go server.Serve(false, model.Conf.CookieKey)
    // ...
}
```

---

### 资源加载机制

```
1. iOS应用启动
   ↓
2. Swift初始化内核 (MobileStartKernel)
   ↓
3. Go内核读取 Bundle.main.resourcePath/app/
   ↓
4. 设置 WorkingDir = appDir/app
   ↓
5. InitAppearance() 复制资源到 ConfDir
   ↓
6. HTTP服务器启动（6806端口）
   ↓
7. WKWebView加载 http://127.0.0.1:6806/appearance/boot/index.html
```

---

### 编译产物对比

| 项目 | 大小 | 包含内容 | 备注 |
|------|------|----------|------|
| **Android内核** | ~150MB | kernel.aar (arm64) | 仅真机架构 |
| **iOS内核** | **285MB** | iosk.xcframework | 真机+模拟器 |
| **桌面版内核** | ~98MB | SiYuan-Kernel | 单架构二进制 |

**为什么iOS内核更大？**
1. 包含两种架构: arm64(真机) + arm64/x86_64(模拟器)
2. XCFramework格式: 包含完整的Framework结构和头文件
3. Go运行时: 每个架构都包含完整的Go运行时

---

## 📊 资源统计

### iOS项目资源分布

```
iosk.xcframework/  285 MB   (80.6%)  ← Go内核
├── ios-arm64/            142 MB   (真机)
└── ios-arm64_x86_64/     143 MB   (模拟器)

app/               68.2 MB  (19.4%)  ← 前端资源
├── appearance/    16 MB   (4.5%)   ← 含15种语言
├── stage/         34 MB   (9.6%)   ← 编译后前端
├── guide/         16 MB   (4.5%)   ← 用户指南
└── changelogs/    2.2 MB  (0.6%)   ← 更新日志

─────────────────────────────────────
总计:              353 MB
```

---

### 前端编译对比

| 模式 | 命令 | main.js | 总大小 | 加载速度 |
|------|------|---------|--------|----------|
| **开发模式** | `pnpm run dev:mobile` | 10.7 MB | 11 MB | 慢 |
| **生产模式** | `pnpm run build:mobile` | 1.7 MB | 1.8 MB | 快 |
| **优化效果** | - | ↓ **85%** | ↓ 84% | ✅ |

---

### 产物清单

完整打包后的iOS项目包含：

```
siyuan-ios/
├── iosk.xcframework/          ⭐ 285MB (Go内核)
│   ├── Info.plist
│   ├── ios-arm64/            (iPhone/iPad真机)
│   │   └── Iosk.framework/
│   │       ├── Headers/
│   │       ├── Iosk (二进制)
│   │       └── Modules/
│   └── ios-arm64_x86_64-simulator/ (模拟器)
│       └── Iosk.framework/
│           ├── Headers/
│           ├── Iosk (二进制)
│           └── Modules/
│
├── app/                       ⭐ 68.2MB (前端资源)
│   ├── appearance/           (16MB)
│   │   ├── boot/
│   │   ├── emojis/
│   │   ├── fonts/
│   │   ├── icons/
│   │   ├── langs/            ← 15种语言
│   │   └── themes/
│   ├── stage/                (34MB)
│   │   ├── build/mobile/     ← 编译后的前端
│   │   ├── images/
│   │   ├── protyle/
│   │   └── auth.html
│   ├── guide/                (16MB)
│   └── changelogs/           (2.2MB)
│
├── siyuan-ios/               (Swift源码)
│   ├── AppDelegate.swift
│   ├── ViewController.swift
│   ├── Info.plist
│   └── Assets.xcassets/
│
└── siyuan-ios.xcodeproj/     (Xcode项目)

总大小: 约353MB
```

---

## 🌍 多语言支持

### 支持的语言列表

应用支持以下15种语言：

1. 🇸🇦 **阿拉伯语** (ar_SA.json)
2. 🇩🇪 **德语** (de_DE.json)
3. 🇺🇸 **英语** (en_US.json) - 默认回退语言
4. 🇪🇸 **西班牙语** (es_ES.json)
5. 🇫🇷 **法语** (fr_FR.json)
6. 🇮🇱 **希伯来语** (he_IL.json)
7. 🇮🇹 **意大利语** (it_IT.json)
8. 🇯🇵 **日语** (ja_JP.json)
9. 🇰🇷 **韩语** (ko_KR.json)
10. 🇵🇱 **波兰语** (pl_PL.json)
11. 🇧🇷 **葡萄牙语（巴西）** (pt_BR.json)
12. 🇷🇺 **俄语** (ru_RU.json)
13. 🇹🇷 **土耳其语** (tr_TR.json)
14. 🇹🇼 **繁体中文** (zh_CHT.json)
15. 🇨🇳 **简体中文** (zh_CN.json)

---

### 语言文件位置

```
siyuan-ios/app/appearance/langs/
├── ar_SA.json    (阿拉伯语, ~85KB)
├── de_DE.json    (德语, ~78KB)
├── en_US.json    (英语, ~75KB)
├── es_ES.json    (西班牙语, ~82KB)
├── fr_FR.json    (法语, ~84KB)
├── he_IL.json    (希伯来语, ~79KB)
├── it_IT.json    (意大利语, ~79KB)
├── ja_JP.json    (日语, ~88KB)
├── ko_KR.json    (韩语, ~82KB)
├── pl_PL.json    (波兰语, ~81KB)
├── pt_BR.json    (葡萄牙语, ~80KB)
├── ru_RU.json    (俄语, ~91KB)
├── tr_TR.json    (土耳其语, ~78KB)
├── zh_CHT.json   (繁体中文, ~73KB)
└── zh_CN.json    (简体中文, ~72KB)

总大小: 约1.2MB
```

---

### 语言检测逻辑

iOS应用根据系统语言自动选择界面语言：

```swift
// ViewController.swift
let systemLang = Locale.preferredLanguages[0].prefix(2)
let lang = systemLang == "zh" ? "zh_CN" : "en_US"

Iosk.MobileStartKernel(
    "ios",
    Bundle.main.resourcePath,
    workspaceDir,
    timezone,
    localIP,
    lang,  // ← 传递给Go内核
    osVersion
)
```

---

## ✅ 验证清单

### 编译前检查

- [ ] Go已安装且版本>=1.20
- [ ] CGO_ENABLED=1
- [ ] gomobile已安装并初始化
- [ ] Xcode已安装（>= 15.0）
- [ ] Command Line Tools已安装
- [ ] pnpm已安装
- [ ] kernel/mobile/目录存在
- [ ] app/目录存在

---

### 内核编译后检查

- [ ] iosk.xcframework已生成
- [ ] 大小约285MB
- [ ] 包含ios-arm64目录（真机）
- [ ] 包含ios-arm64_x86_64-simulator目录（模拟器）
- [ ] Info.plist存在且格式正确
- [ ] 已复制到siyuan-ios/目录

---

### 资源拷贝后检查

- [ ] app/appearance/目录存在
- [ ] app/appearance/langs/包含15个.json文件
- [ ] app/stage/build/mobile/目录存在
- [ ] app/stage/build/mobile/index.html存在
- [ ] app/guide/目录存在
- [ ] app/changelogs/目录存在

---

### iOS应用编译后检查

- [ ] 编译成功（BUILD SUCCEEDED）
- [ ] siyuan-ios.app已生成
- [ ] 代码签名完成
- [ ] 无编译错误
- [ ] DerivedData中包含Debug-iphonesimulator/siyuan-ios.app

---

### 运行验证

- [ ] 应用成功安装到模拟器
- [ ] 应用成功启动
- [ ] 进程存在（ps aux可以找到）
- [ ] 内核服务正常（6806端口监听）
- [ ] API响应正常（version接口返回正确）
- [ ] 启动进度100%
- [ ] 界面正常显示（认证/登录界面）
- [ ] 中文本地化正常
- [ ] 无崩溃或闪退
- [ ] 无错误日志

---

## 🎯 重要提示

### ⚠️ 关键注意事项

1. **步骤3（编译内核）是关键步骤**
   - 必须使用gomobile编译
   - 不能跳过
   - 每次修改kernel代码都要执行
   - 编译时间较长（1.5分钟），请耐心等待

2. **步骤顺序不能颠倒**
   - 先编译前端和内核
   - 再拷贝资源
   - 最后编译iOS应用

3. **必须完全清空旧资源**
   - 使用 `rm -rf *` 而不是单独删除
   - 确保多语言等资源是最新的

4. **内核编译依赖项**
   - Go >= 1.20
   - CGO_ENABLED=1
   - gomobile已安装
   - Xcode完整安装

5. **使用生产编译**
   - 前端: `pnpm run build:mobile` (不是 dev:mobile)
   - 体积小85%，加载更快

---

### 🎯 何时需要完整重新打包

#### 必须完整打包 ✅
- 修改了Go内核代码
- 修改了前端代码
- 更新了多语言文件
- 长时间未更新，需要同步最新代码
- 出现资源不一致问题
- 首次配置开发环境

#### 可以部分更新 ⚡
- 仅修改Swift UI代码 → 只编译iOS应用（15秒）
- 仅修改样式 → 只更新appearance（10秒）
- 仅测试不同配置 → 不需要重新编译

---

## 📈 完整流程图

```
┌─────────────────────────────────────────┐
│  步骤1: 删除旧资源                       │
│  rm -rf siyuan-ios/app/*                │
│  ⏱️  1秒                                 │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  步骤2: 编译前端                         │
│  pnpm run build:mobile                  │
│  📦 输出: 1.7MB (压缩85%)                │
│  ⏱️  3-5秒                               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  ⭐ 步骤3: 编译iOS内核（关键）           │
│  gomobile bind ... -target=ios          │
│  🔧 输出: 285MB XCFramework              │
│  ⏱️  60-100秒 (最耗时)                   │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  步骤4: 复制内核到iOS项目                │
│  cp iosk.xcframework siyuan-ios/        │
│  ⏱️  2-3秒                               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  步骤5: 拷贝前端资源                     │
│  cp appearance stage guide changelogs   │
│  📋 包含: 15种语言 + 编译后前端           │
│  ⏱️  3-5秒                               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  步骤6: 编译iOS应用                      │
│  xcodebuild ... clean build             │
│  🔨 输出: siyuan-ios.app                 │
│  ⏱️  12-15秒                             │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  步骤7: 启动模拟器                       │
│  xcrun simctl boot "iPhone 17 Pro Max"  │
│  ⏱️  3-5秒                               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  步骤8: 安装并运行应用                   │
│  xcrun simctl install/launch            │
│  🎉 应用成功运行                         │
│  ⏱️  5-8秒                               │
└─────────────────────────────────────────┘

总耗时: 2-3分钟
```

---

## 🎊 总结

### 完整打包流程包含

✅ **8个关键步骤**
1. 删除旧资源
2. 编译前端（生产模式）
3. ⭐ 编译iOS内核（gomobile）
4. 复制内核到iOS项目
5. 拷贝前端资源
6. 编译iOS应用
7. 启动模拟器
8. 安装并运行

### 核心成就

- ✅ Go内核成功编译（285MB，支持真机+模拟器）
- ✅ 前端生产编译（体积减少85%）
- ✅ 15种语言完整支持
- ✅ 所有资源最新版本
- ✅ 一键自动化脚本
- ✅ 4种快速更新场景
- ✅ 完整验证清单
- ✅ 详细故障排除

### 最终产物

```
iOS应用: siyuan-ios.app
  - 内核: 285MB (真机+模拟器)
  - 前端: 68.2MB (15语言+资源)
  - 总大小: 353MB
  - 运行状态: 稳定无闪退
  - 界面显示: 正常
  - API响应: 正常
```

---

## 📚 相关文档

- **环境配置**: `iOS开发环境配置完成.md`
- **模拟器配置**: `模拟器配置说明.md`
- **快速开始**: `快速开始.md`
- **运行报告**: `运行成功报告.md`

---

## 🚀 快速开始

**首次使用**:
```bash
# 1. 确保环境已配置
go version && ~/go/bin/gomobile version && pnpm --version

# 2. 运行一键脚本
cd /Users/rysisun/Documents/siyuan/siyuan-ios
chmod +x rebuild-ios-full.sh
./rebuild-ios-full.sh
```

**日常开发**:
- 修改Go代码 → 使用"场景1: 仅更新内核"（2分钟）
- 修改前端代码 → 使用"场景2: 仅更新前端"（20秒）
- 修改Swift代码 → 使用"场景3: 仅更新Swift"（15秒）

---

**文档版本**: v1.0  
**最后更新**: 2026年2月16日  
**验证状态**: ✅ 已在iPhone 17 Pro Max模拟器验证通过  
**维护者**: SiYuan iOS Team

---

**下次打包时，请参考本文档按步骤执行！** 🎉

特别注意 **步骤3** 的iOS内核编译，这是新增的关键步骤！
