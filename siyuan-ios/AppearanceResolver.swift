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

import UIKit

/// 读取内核持久化的外观配置（`<Documents>/siyuan/conf/conf.json`），解析出与思源主题方向一致的
/// `UIUserInterfaceStyle`。逻辑与前端 `Lg`/`xg` 一致：`modeOS`（跟随系统）时取系统外观，否则按
/// `mode`（0=亮/1=暗）。
///
/// 路径来源：内核 `util/working_mobile.go` 中 `ConfDir = WorkspaceDir/conf`，iOS 上 `WorkspaceDir = <Documents>/siyuan`。
enum AppearanceResolver {

  /// 解析应使用的界面外观方向，供闪念界面（`overrideUserInterfaceStyle`）使用。
  /// 配置不存在（如首次冷启动内核尚未写入）时退化为跟随系统。
  static func userInterfaceStyle() -> UIUserInterfaceStyle {
    guard let appearance = readAppearance() else {
      return UITraitCollection.current.userInterfaceStyle
    }
    let modeOS = appearance["modeOS"] as? Bool ?? false
    if modeOS {
      return UITraitCollection.current.userInterfaceStyle
    }
    return (appearance["mode"] as? Int ?? 0) == 1 ? .dark : .light
  }

  private static func readAppearance() -> [String: Any]? {
    let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let confPath = urls[0].path + "/siyuan/conf/conf.json"
    guard let data = FileManager.default.contents(atPath: confPath),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return root["appearance"] as? [String: Any]
  }
}
