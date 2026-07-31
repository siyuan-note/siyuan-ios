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

import Foundation

/// App Intent（iOS 16+ 快捷指令 / Siri）与 `SceneDelegate` 之间的单元素请求队列。
///
/// `AppIntent.perform()` 被调用时 app 可能尚未激活、root VC 可能仍为冷启动占位，直接弹 UI 会与
/// 既有冷启动 root-VC 替换逻辑竞争。故 `perform()` 仅入队，由 `SceneDelegate.sceneDidBecomeActive`
/// 出队并复用现成的 `presentShorthand(text:)` 完成展示。
///
/// 仅在 app 进程内生效（基于 `UserDefaults.standard`）。对 iOS 15 无害：无人入队，出队恒为 `nil`。
enum ShorthandLauncher {

  private static let pendingKey = "pendingShorthandFromIntent"
  private static let textKey = "pendingShorthandFromIntentText"

  /// 入队一个闪念请求。`text` 为空字符串表示打开空白编辑器。
  static func enqueue(text: String) {
    UserDefaults.standard.set(true, forKey: pendingKey)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      UserDefaults.standard.removeObject(forKey: textKey)
    } else {
      UserDefaults.standard.set(trimmed, forKey: textKey)
    }
  }

  /// 出队并消费。返回 `nil` 表示无待处理请求；非 `nil` 表示待呈现文本（空串 = 空白编辑器）。
  static func consume() -> String? {
    guard UserDefaults.standard.bool(forKey: pendingKey) else { return nil }
    UserDefaults.standard.set(false, forKey: pendingKey)
    let text = UserDefaults.standard.string(forKey: textKey) ?? ""
    UserDefaults.standard.removeObject(forKey: textKey)
    return text
  }
}
