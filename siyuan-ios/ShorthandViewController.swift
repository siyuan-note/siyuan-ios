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

  private let textView = ShorthandTextView()
  private let titleLabel = UILabel()
  private let submitButton = UIButton(type: .system)
  private let placeholderLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    setupUI()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    textView.becomeFirstResponder()
  }

  private func setupUI() {
    // Title bar
    let titleBar = UIStackView(arrangedSubviews: [titleLabel, submitButton])
    titleBar.axis = .horizontal
    titleBar.alignment = .center
    titleBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleBar)

    titleLabel.text = NSLocalizedString("shorthand_label", comment: "")
    titleLabel.font = UIFont.boldSystemFont(ofSize: 18)

    submitButton.setTitle(NSLocalizedString("Submit", comment: ""), for: .normal)
    submitButton.addTarget(self, action: #selector(onSubmit), for: .touchUpInside)
    submitButton.isEnabled = false
    submitButton.setTitleColor(.white, for: .normal)
    submitButton.setTitleColor(.white, for: .disabled)
    submitButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
    submitButton.layer.cornerRadius = 6
    submitButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    submitButton.setContentHuggingPriority(.required, for: .horizontal)
    updateSubmitButtonState()

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

  private func updateSubmitButtonState() {
    if submitButton.isEnabled {
      submitButton.backgroundColor = .systemBlue
    } else {
      submitButton.backgroundColor = .systemGray3
    }
  }

  func appendText(_ text: String) {
    textView.text += text
    submitButton.isEnabled = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    updateSubmitButtonState()
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
    submitButton.isEnabled = false
    placeholderLabel.isHidden = false

    if presentingViewController != nil {
      dismiss(animated: true)
    } else {
      UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }
  }
}

extension ShorthandViewController: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    submitButton.isEnabled = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    updateSubmitButtonState()
    placeholderLabel.isHidden = !textView.text.isEmpty
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
