/*
 * SiYuan - 源于思考，饮水思源
 * Copyright (c) 2020-present, b3log.org
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import AppIntents

// MARK: - App Intents（iOS 16+）

/// 注册「闪念速记」为系统级快捷指令（「快捷指令」App / Siri / Spotlight / 锁屏调用）。
/// 应用最低部署版本为 iOS 15，故整体标注 `@available(iOS 16.0, *)`：iOS 15 用户回落到
/// 既有的 Home Screen Quick Action + `NSUserActivity` 体验，无破坏性变更。
@available(iOS 16.0, *)
struct ShorthandAppShortcuts: AppShortcutsProvider {

  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenShorthandIntent(),
      phrases: [
        "用 \(.applicationName) 记闪念",
        "用 \(.applicationName) 速记",
        "在 \(.applicationName) 新建闪念",
        "Open a shorthand in \(.applicationName)",
        "New shorthand in \(.applicationName)",
        "Open \(.applicationName) shorthand",
      ],
      shortTitle: "shorthand_label",
      systemImageName: "square.and.pencil"
    )
  }
}

/// 「闪念速记」App Intent：拉起 App 打开闪念编辑器，可选预填文本。
///
/// `content` 为可选自由文本：Siri 语音短语触发时不带参数 → 打开空白编辑器（与 Home Screen Quick
/// Action 一致）；在「快捷指令」App 中把本 intent 加入快捷指令、并前置「听写文本」动作接到 `content`，
/// 即可实现「语音听写 → 直接进闪念编辑器」的组合（这是 Apple 官方与第三方笔记类 App 处理可选自由
/// 文本的标准做法，避免自由文本作为 Siri 短语占位符在真机上「变量不可用」的问题）。
///
/// `perform()` 仅通过 `ShorthandLauncher.enqueue(text:)` 入队，由 `SceneDelegate.sceneDidBecomeActive`
/// 出队并复用现成的 `presentShorthand(text:)` 完成展示（自动获得追加/去重/捐赠 activity 行为），
/// 避免在 root VC 尚未就绪的冷启动阶段直接弹 UI 引发时序竞争。
@available(iOS 16.0, *)
struct OpenShorthandIntent: AppIntent {

  static var title: LocalizedStringResource = "shorthand_label"
  static var description = IntentDescription("shorthand_intent_description")
  static var openAppWhenRun: Bool = true

  /// 可选预填文本。省略时打开空白编辑器。
  @Parameter(title: "shorthand_intent_content_param", description: "shorthand_intent_content_param")
  var content: String?

  func perform() async throws -> some IntentResult {
    ShorthandLauncher.enqueue(text: content ?? "")
    return .result()
  }
}
