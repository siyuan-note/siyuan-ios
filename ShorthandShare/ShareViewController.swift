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
import UniformTypeIdentifiers
import Iosk

/// 分享扩展版的「闪念速记」。UI 与主 App 的 `ShorthandViewController` 对齐，
/// 但存储落在 App Group 容器（`group.com.ld246.siyuan`），由主 App 回前台时搬运；
/// 关闭使用 `extensionContext` 而非 `dismiss`。
class ShareViewController: UIViewController, UITextViewDelegate {

    private let textView = ShorthandTextView()
    private let titleLabel = UILabel()
    private let submitButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("shorthand_label", comment: "")
        // 由 storyboard 的 navigationController 托管，改用自定义标题栏后隐藏系统导航栏
        navigationController?.setNavigationBarHidden(true, animated: false)
        // 默认卡片样式，强制全屏，与主 App 闪念呈现一致
        navigationController?.modalPresentationStyle = .fullScreen
        view.backgroundColor = .systemBackground
        setupUI()
        loadSharedContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshSubmitButton()
        textView.becomeFirstResponder()
    }

    private func setupUI() {
        // Title bar：[取消] [标题(居中)] [提交]
        let titleBar = UIStackView(arrangedSubviews: [cancelButton, titleLabel, submitButton])
        titleBar.axis = .horizontal
        titleBar.alignment = .center
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleBar)

        cancelButton.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.text = NSLocalizedString("shorthand_label", comment: "")
        titleLabel.font = UIFont.boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        submitButton.setTitle(NSLocalizedString("Submit", comment: ""), for: .normal)
        submitButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
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

    private func loadSharedContent() {
        guard let extensionContext = extensionContext else { return }
        let items = extensionContext.inputItems as? [NSExtensionItem] ?? []

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    loadURL(from: provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                    loadHtml(from: provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    loadText(from: provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    loadFile(from: provider, typeIdentifier: UTType.image.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    loadFile(from: provider, typeIdentifier: UTType.movie.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    loadFile(from: provider, typeIdentifier: UTType.audio.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    loadFile(from: provider, typeIdentifier: UTType.data.identifier)
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self, let url = item as? URL else { return }
            if url.isFileURL {
                self.appendFile(from: url)
                return
            }
            let link = "<" + url.absoluteString + ">"
            DispatchQueue.main.async {
                self.placeholderLabel.isHidden = true
                self.textView.text += link
                self.refreshSubmitButton()
            }
        }
    }

    private func loadText(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (text, error) in
            guard let self = self, let text = text as? String else { return }
            DispatchQueue.main.async {
                self.placeholderLabel.isHidden = true
                self.textView.text += text
                self.refreshSubmitButton()
            }
        }
    }

    private func loadHtml(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.html.identifier, options: nil) { [weak self] (html, error) in
            guard let self = self, let html = html as? String else { return }
            let displayText = Iosk.MobileHTML2Markdown(html) ?? html
            DispatchQueue.main.async {
                self.placeholderLabel.isHidden = true
                self.textView.text += displayText
                self.refreshSubmitButton()
            }
        }
    }

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] (url, error) in
            guard let self = self, let url = url else { return }
            self.appendFile(from: url, typeIdentifier: typeIdentifier)
        }
    }

    /// 将分享来源的临时文件复制到闪念资源目录，避免保存随后失效的 file:// 地址。
    private func appendFile(from url: URL, typeIdentifier: String? = nil) {
        let rawName = url.lastPathComponent
        var baseName = Iosk.MobileFilepathBase(rawName)
        baseName = Iosk.MobileFilterUploadFileName(baseName)
        let fileName = Iosk.MobileAssetName(baseName)
        let assetsDir = shorthandsDir() + "assets/"
        try? FileManager.default.createDirectory(
            atPath: assetsDir, withIntermediateDirectories: true, attributes: nil)

        let destURL = URL(fileURLWithPath: assetsDir + fileName)
        try? FileManager.default.copyItem(at: url, to: destURL)

        let contentType = typeIdentifier.flatMap(UTType.init)
            ?? UTType(filenameExtension: url.pathExtension)
        let link: String
        if contentType?.conforms(to: .image) == true {
            link = "![" + fileName + "](assets/" + fileName + ")"
        } else {
            link = "[" + fileName + "](assets/" + fileName + ")"
        }

        DispatchQueue.main.async {
            self.placeholderLabel.isHidden = true
            self.textView.text += link + "\n\n"
            self.refreshSubmitButton()
        }
    }

    @objc private func submit() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            dismissExtension()
            return
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let filePath = shorthandsDir() + String(timestamp) + ".md"

        try? FileManager.default.createDirectory(atPath: shorthandsDir(), withIntermediateDirectories: true, attributes: nil)

        do {
            try text.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            print("shorthand write failed: \(error)")
        }

        dismissExtension()
    }

    @objc private func cancel() {
        dismissExtension()
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// 分享扩展进程的 Documents 落不到主 App 容器，故写入 App Group 共享容器，
    /// 由主 App `SceneDelegate.moveSharedShorthands()` 在回前台时搬运到工作空间对应目录。
    private func shorthandsDir() -> String {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ld246.siyuan")
        return (containerURL?.path ?? NSTemporaryDirectory()) + "/home/.config/siyuan/shortcuts/shorthands/"
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshSubmitButton()
    }
}

/// 与主 App `ShorthandTextView` 行为一致：粘贴 HTML 时自动转 Markdown。
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
