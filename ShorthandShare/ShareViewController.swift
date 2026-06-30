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

class ShareViewController: UIViewController, UITextViewDelegate {

    private let textView = UITextView()
    private let placeholderLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("shorthand_label", comment: "")
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Submit", comment: ""),
            style: .done,
            target: self,
            action: #selector(submit))

        setupUI()
        loadSharedContent()
    }

    private func setupUI() {
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        placeholderLabel.text = NSLocalizedString("shorthand_placeholder", comment: "")
        placeholderLabel.font = UIFont.systemFont(ofSize: 16)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -5),
        ])
    }

    private func loadSharedContent() {
        guard let extensionContext = extensionContext else { return }
        let items = extensionContext.inputItems as? [NSExtensionItem] ?? []

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
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

    private func loadText(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (text, error) in
            guard let self = self, let text = text as? String else { return }
            DispatchQueue.main.async {
                self.placeholderLabel.isHidden = true
                self.textView.text += text
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
            }
        }
    }

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] (url, error) in
            guard let self = self, let url = url else { return }

            let rawName = url.lastPathComponent
            var baseName = Iosk.MobileFilepathBase(rawName)
            baseName = Iosk.MobileFilterUploadFileName(baseName)
            let fileName = Iosk.MobileAssetName(baseName)
            let assetsDir = self.shorthandsDir() + "assets/"
            try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true, attributes: nil)

            let destURL = URL(fileURLWithPath: assetsDir + fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)

            let link: String
            if typeIdentifier == UTType.image.identifier {
                link = "![" + fileName + "](assets/" + fileName + ")"
            } else {
                link = "[" + fileName + "](assets/" + fileName + ")"
            }

            DispatchQueue.main.async {
                self.placeholderLabel.isHidden = true
                self.textView.text += link + "\n\n"
            }
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

    private func shorthandsDir() -> String {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ld246.siyuan")
        return (containerURL?.path ?? NSTemporaryDirectory()) + "/home/.config/siyuan/shortcuts/shorthands/"
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}

