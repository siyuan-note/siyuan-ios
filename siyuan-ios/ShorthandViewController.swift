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

import Iosk
import UIKit
import UniformTypeIdentifiers

class ShorthandViewController: UIViewController {

  /// 作为 root VC 关闭（提交或取消）时发出，由 SceneDelegate 接管挂起应用，
  /// 下次激活由 sceneDidBecomeActive 兜底恢复主界面。
  static let didSubmitAsRootNotification = Notification.Name("ShorthandDidSubmitAsRoot")

  private let textView = ShorthandTextView()
  private let titleLabel = UILabel()
  private let submitButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let placeholderLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    applyAppearance()
    setupUI()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 无内容时确保提交按钮置灰，覆盖冷启动 root VC / present / URL scheme 等各入口
    refreshSubmitButton()
    textView.becomeFirstResponder()
  }

  /// 读取内核持久化的 appearance 配置，使界面与思源主题保持一致。
  private func applyAppearance() {
    view.overrideUserInterfaceStyle = AppearanceResolver.userInterfaceStyle()
  }

  private func setupUI() {
    // Title bar：[取消] [标题(居中)] [提交]
    let titleBar = UIStackView(arrangedSubviews: [cancelButton, titleLabel, submitButton])
    titleBar.axis = .horizontal
    titleBar.alignment = .center
    titleBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleBar)

    cancelButton.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
    cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
    cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
    cancelButton.setContentHuggingPriority(.required, for: .horizontal)
    cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

    titleLabel.text = NSLocalizedString("shorthand_label", comment: "")
    titleLabel.font = UIFont.boldSystemFont(ofSize: 18)
    titleLabel.textAlignment = .center
    // 让标题在取消/提交按钮之间居中
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    submitButton.setTitle(NSLocalizedString("Submit", comment: ""), for: .normal)
    submitButton.addTarget(self, action: #selector(onSubmit), for: .touchUpInside)
    submitButton.setTitleColor(.white, for: .normal)
    submitButton.setTitleColor(.lightText, for: .disabled)
    submitButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
    submitButton.layer.cornerRadius = 6
    submitButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    submitButton.setContentHuggingPriority(.required, for: .horizontal)
    refreshSubmitButton()

    // Separator
    let separator = UIView()
    separator.backgroundColor = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(separator)

    // Text view
    textView.font = UIFont.systemFont(ofSize: 16)
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(textView)

    // Placeholder
    placeholderLabel.text = NSLocalizedString("shorthand_placeholder", comment: "")
    placeholderLabel.font = UIFont.systemFont(ofSize: 16)
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.numberOfLines = 0
    view.addSubview(placeholderLabel)

    NSLayoutConstraint.activate([
      titleBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      titleBar.heightAnchor.constraint(equalToConstant: 56),

      submitButton.heightAnchor.constraint(equalToConstant: 36),

      separator.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 0.5),

      textView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      textView.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

      placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
      placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -5),
    ])
  }

  /// 根据当前文本是否有非空内容，统一刷新提交按钮的可用态、样式与占位提示。
  private func refreshSubmitButton() {
    let hasContent = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    submitButton.isEnabled = hasContent
    submitButton.backgroundColor = hasContent ? .systemBlue : .systemGray3
    placeholderLabel.isHidden = !textView.text.isEmpty
  }

  func appendText(_ text: String) {
    textView.text += text
    refreshSubmitButton()
  }

  @objc private func onSubmit() {
    let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let workspaceBaseDir = urls[0].path
    let shorthandsDir = workspaceBaseDir + "/home/.config/siyuan/shortcuts/shorthands/"

    try? FileManager.default.createDirectory(
      atPath: shorthandsDir, withIntermediateDirectories: true, attributes: nil)

    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    let filePath = shorthandsDir + String(timestamp) + ".md"

    do {
      try text.write(toFile: filePath, atomically: true, encoding: .utf8)
    } catch {
      print("shorthand write failed: \(error)")
    }

    textView.text = ""
    placeholderLabel.isHidden = false
    refreshSubmitButton()

    exitShorthand()
  }

  /// 取消：不保存，关闭闪念。
  /// present 场景直接 dismiss 回到主界面；root VC（冷启动）场景挂起应用，
  /// 下次激活由 sceneDidBecomeActive 兜底恢复主界面。
  @objc private func onCancel() {
    exitShorthand()
  }

  /// 关闭闪念界面：present 出来的则 dismiss，作为 root 的则交由 SceneDelegate 挂起并恢复主界面。
  private func exitShorthand() {
    if presentingViewController != nil {
      dismiss(animated: true)
    } else {
      NotificationCenter.default.post(name: Self.didSubmitAsRootNotification, object: nil)
    }
  }
}

extension ShorthandViewController: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    refreshSubmitButton()
  }
}

class ShorthandTextView: UITextView {
  override func paste(_ sender: Any?) {
    let pasteboard = UIPasteboard.general
    if pasteboard.contains(pasteboardTypes: [UTType.html.identifier]) {
      if let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier),
        let html = String(data: htmlData, encoding: .utf8)
      {
        let md = Iosk.MobileHTML2Markdown(html)
        if !md.isEmpty {
          insertText(md)
          return
        }
      }
    }
    super.paste(sender)
  }
}
