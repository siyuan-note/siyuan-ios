/*
 * SiYuan - From thought to insight, with agents
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
    private let draftStore = ShorthandDraftStore(fileName: "share.md")
    private let attachmentQueue = DispatchQueue(label: "com.ld246.siyuan.shorthand-attachments")
    private var attachmentState = ShorthandAttachmentState.active
    private var loadingProgresses: [Progress] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var pendingSharedItemCount = 0
    private var isFinishing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("shorthand_label", comment: "")
        // 由 storyboard 的 navigationController 托管，改用自定义标题栏后隐藏系统导航栏
        navigationController?.setNavigationBarHidden(true, animated: false)
        // 默认卡片样式，强制全屏，与主 App 闪念呈现一致
        navigationController?.modalPresentationStyle = .fullScreen
        view.backgroundColor = .systemBackground
        setupUI()
        if restoreDraft() {
            cleanupStagedAssets()
        }
        observeExtensionLifecycle()
        loadSharedContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshSubmitButton()
        textView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        flushDraft()
        super.viewWillDisappear(animated)
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
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
        let enabled = hasContent && pendingSharedItemCount == 0 && !isFinishing
        submitButton.isEnabled = enabled
        submitButton.backgroundColor = enabled ? .systemBlue : .systemGray3
        cancelButton.isEnabled = !isFinishing
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func loadSharedContent() {
        guard let extensionContext = extensionContext else { return }
        let items = extensionContext.inputItems as? [NSExtensionItem] ?? []

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    pendingSharedItemCount += 1
                    loadURL(from: provider) { [weak self] in self?.sharedItemDidFinishLoading() }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                    pendingSharedItemCount += 1
                    loadHtml(from: provider) { [weak self] in self?.sharedItemDidFinishLoading() }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    pendingSharedItemCount += 1
                    loadText(from: provider) { [weak self] in self?.sharedItemDidFinishLoading() }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    pendingSharedItemCount += 1
                    loadFile(
                        from: provider, typeIdentifier: UTType.image.identifier,
                        completion: { [weak self] in self?.sharedItemDidFinishLoading() })
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    pendingSharedItemCount += 1
                    loadFile(
                        from: provider, typeIdentifier: UTType.movie.identifier,
                        completion: { [weak self] in self?.sharedItemDidFinishLoading() })
                } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    pendingSharedItemCount += 1
                    loadFile(
                        from: provider, typeIdentifier: UTType.audio.identifier,
                        completion: { [weak self] in self?.sharedItemDidFinishLoading() })
                } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    pendingSharedItemCount += 1
                    loadFile(
                        from: provider, typeIdentifier: UTType.data.identifier,
                        completion: { [weak self] in self?.sharedItemDidFinishLoading() })
                }
            }
        }
        refreshSubmitButton()
    }

    private func loadURL(from provider: NSItemProvider, completion: @escaping () -> Void) {
        provider.loadItem(
            forTypeIdentifier: UTType.url.identifier, options: nil
        ) { [weak self] (item, error) in
            guard let self = self, let url = item as? URL else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            if url.isFileURL {
                self.appendFile(from: url, completion: completion)
                return
            }
            let link = "<" + url.absoluteString + ">"
            DispatchQueue.main.async {
                self.appendContent(link)
                completion()
            }
        }
    }

    private func loadText(from provider: NSItemProvider, completion: @escaping () -> Void) {
        provider.loadItem(
            forTypeIdentifier: UTType.plainText.identifier, options: nil
        ) { [weak self] (text, error) in
            guard let self = self, let text = text as? String else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            DispatchQueue.main.async {
                self.appendContent(text)
                completion()
            }
        }
    }

    private func loadHtml(from provider: NSItemProvider, completion: @escaping () -> Void) {
        provider.loadItem(
            forTypeIdentifier: UTType.html.identifier, options: nil
        ) { [weak self] (html, error) in
            guard let self = self, let html = html as? String else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            let displayText = Iosk.MobileHTML2Markdown(html) ?? html
            DispatchQueue.main.async {
                self.appendContent(displayText)
                completion()
            }
        }
    }

    private func loadFile(
        from provider: NSItemProvider, typeIdentifier: String, completion: @escaping () -> Void
    ) {
        let progress = provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { [weak self] (url, error) in
            guard let self = self, let url = url else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            self.appendFile(from: url, typeIdentifier: typeIdentifier, completion: completion)
        }
        loadingProgresses.append(progress)
    }

    /// 在分享回调返回前将临时文件复制到草稿资源目录，保证恢复的草稿仍可引用附件。
    private func appendFile(
        from url: URL, typeIdentifier: String? = nil, completion: @escaping () -> Void
    ) {
        var link: String?
        var copyError: Error?
        attachmentQueue.sync {
            guard attachmentState == .active else { return }
            do {
                link = try stageAttachment(from: url, typeIdentifier: typeIdentifier)
            } catch {
                copyError = error
            }
        }
        if let copyError = copyError {
            print("shorthand asset copy failed: \(copyError)")
        }
        DispatchQueue.main.async {
            if let link = link {
                self.appendContent(link + "\n\n")
            }
            completion()
        }
    }

    @objc private func submit() {
        let rawText = textView.text ?? ""
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard pendingSharedItemCount == 0 && !isFinishing else { return }

        guard draftStore.flush(rawText) else {
            showStorageError()
            return
        }
        isFinishing = true
        refreshSubmitButton()
        attachmentQueue.sync {
            attachmentState = .submitting
        }

        attachmentQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.promoteStagedAttachments(referencedBy: text)
                let directoryURL = try self.shorthandsDirectory()
                try FileManager.default.createDirectory(
                    at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                let fileURL = self.nextShorthandFileURL(in: directoryURL)
                guard self.draftStore.promote(rawText, to: fileURL) else {
                    throw ShorthandShareError.promotionFailed
                }
            } catch {
                self.attachmentState = .active
                DispatchQueue.main.async {
                    self.isFinishing = false
                    self.refreshSubmitButton()
                    self.showStorageError()
                }
                print("shorthand write failed: \(error)")
                return
            }

            self.removeStagedAttachments()
            DispatchQueue.main.async {
                self.textView.text = ""
                self.dismissExtension()
            }
        }
    }

    @objc private func cancel() {
        guard !isFinishing else { return }
        isFinishing = true
        refreshSubmitButton()

        guard draftStore.clear() else {
            isFinishing = false
            refreshSubmitButton()
            showStorageError()
            return
        }
        attachmentQueue.async { [weak self] in
            guard let self = self else { return }
            self.attachmentState = .cancelled
            self.removeStagedAttachments()
            DispatchQueue.main.async {
                for progress in self.loadingProgresses {
                    progress.cancel()
                }
                self.loadingProgresses.removeAll()
                self.pendingSharedItemCount = 0
                self.textView.text = ""
                self.dismissExtension()
            }
        }
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// 分享扩展进程的 Documents 落不到主 App 容器，故写入 App Group 共享容器，
    /// 由主 App `SceneDelegate.moveSharedShorthands()` 在回前台时搬运到工作空间对应目录。
    private func shorthandsDirectory() throws -> URL {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.ld246.siyuan")
        else {
            throw ShorthandShareError.appGroupUnavailable
        }
        return containerURL.appendingPathComponent(
            "home/.config/siyuan/shortcuts/shorthands", isDirectory: true)
    }

    private func stagedAssetsDirectory(createDirectory: Bool = true) throws -> URL {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.ld246.siyuan")
        else {
            throw ShorthandShareError.appGroupUnavailable
        }
        let directoryURL = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ShorthandDrafts", isDirectory: true)
            .appendingPathComponent("share-assets", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        return directoryURL
    }

    private func stageAttachment(from url: URL, typeIdentifier: String?) throws -> String {
        let rawName = url.lastPathComponent
        var baseName = Iosk.MobileFilepathBase(rawName)
        baseName = Iosk.MobileFilterUploadFileName(baseName)
        let stagedAssetsURL = try stagedAssetsDirectory()
        let formalAssetsURL = try shorthandsDirectory().appendingPathComponent("assets", isDirectory: true)
        var fileName = Iosk.MobileAssetName(baseName)
        while FileManager.default.fileExists(
            atPath: stagedAssetsURL.appendingPathComponent(fileName).path)
            || FileManager.default.fileExists(
                atPath: formalAssetsURL.appendingPathComponent(fileName).path)
        {
            fileName = Iosk.MobileAssetName(baseName)
        }

        let partialURL = stagedAssetsURL.appendingPathComponent(
            ".shorthand-partial-" + UUID().uuidString)
        let destinationURL = stagedAssetsURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: partialURL)
            try FileManager.default.moveItem(at: partialURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }

        let contentType = typeIdentifier.flatMap(UTType.init)
            ?? UTType(filenameExtension: url.pathExtension)
        if contentType?.conforms(to: .image) == true {
            return "![" + fileName + "](assets/" + fileName + ")"
        }
        return "[" + fileName + "](assets/" + fileName + ")"
    }

    private func promoteStagedAttachments(referencedBy text: String) throws {
        let sourceDirectoryURL = try stagedAssetsDirectory(createDirectory: false)
        guard FileManager.default.fileExists(atPath: sourceDirectoryURL.path) else { return }

        let targetDirectoryURL = try shorthandsDirectory().appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceDirectoryURL, includingPropertiesForKeys: [.isRegularFileKey])
        for sourceURL in sourceURLs {
            let fileName = sourceURL.lastPathComponent
            guard !fileName.hasPrefix(".shorthand-partial-") else { continue }
            guard try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ShorthandShareError.invalidStagedAsset
            }
            guard text.contains("assets/" + fileName) else { continue }

            let targetURL = targetDirectoryURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                guard FileManager.default.contentsEqual(atPath: sourceURL.path, andPath: targetURL.path) else {
                    throw ShorthandShareError.assetCollision
                }
                continue
            }

            let partialURL = targetDirectoryURL.appendingPathComponent(
                ".shorthand-partial-" + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: partialURL)
                try FileManager.default.moveItem(at: partialURL, to: targetURL)
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
        }
    }

    private func cleanupStagedAssets() {
        let referencedText = textView.text ?? ""
        attachmentQueue.sync {
            do {
                let stagedDirectoryURL = try stagedAssetsDirectory(createDirectory: false)
                if FileManager.default.fileExists(atPath: stagedDirectoryURL.path) {
                    let stagedURLs = try FileManager.default.contentsOfDirectory(
                        at: stagedDirectoryURL, includingPropertiesForKeys: nil)
                    for url in stagedURLs {
                        let fileName = url.lastPathComponent
                        if fileName.hasPrefix(".shorthand-partial-")
                            || !referencedText.contains("assets/" + fileName)
                        {
                            try FileManager.default.removeItem(at: url)
                        }
                    }
                }
                let formalDirectoryURL = try shorthandsDirectory().appendingPathComponent(
                    "assets", isDirectory: true)
                try removePartialFiles(in: formalDirectoryURL)
            } catch {
                print("shorthand staged asset cleanup failed: \(error)")
            }
        }
    }

    private func removePartialFiles(in directoryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)
        for url in urls where url.lastPathComponent.hasPrefix(".shorthand-partial-") {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func removeStagedAttachments() {
        do {
            let directoryURL = try stagedAssetsDirectory(createDirectory: false)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            print("shorthand staged asset cleanup failed: \(error)")
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isFinishing else { return }
        refreshSubmitButton()
        draftStore.scheduleSave(textView.text)
    }

    private func restoreDraft() -> Bool {
        switch draftStore.load() {
        case .success(let text):
            textView.text = text
            refreshSubmitButton()
            return true
        case .failure:
            refreshSubmitButton()
            DispatchQueue.main.async { [weak self] in
                self?.showStorageError()
            }
            return false
        }
    }

    private func appendContent(_ content: String) {
        guard !isFinishing && !content.isEmpty else { return }
        let existing = textView.text ?? ""
        var separator = "\n\n"
        if existing.isEmpty || existing.hasSuffix("\n\n") {
            separator = ""
        } else if existing.hasSuffix("\n") {
            separator = "\n"
        }
        textView.text = existing + separator + content
        draftStore.scheduleSave(textView.text)
        refreshSubmitButton()
    }

    private func sharedItemDidFinishLoading() {
        pendingSharedItemCount = max(0, pendingSharedItemCount - 1)
        if !isFinishing {
            flushDraft()
        }
        refreshSubmitButton()
    }

    private func flushDraft() {
        guard !isFinishing else { return }
        if !draftStore.flush(textView.text ?? "") {
            print("shorthand draft flush failed")
        }
    }

    private func observeExtensionLifecycle() {
        let names: [Notification.Name] = [
            .NSExtensionHostWillResignActive,
            .NSExtensionHostDidEnterBackground,
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.flushDraft()
            }
            lifecycleObservers.append(observer)
        }
    }

    private func showStorageError() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: NSLocalizedString("shorthand_storage_error", comment: ""),
            message: nil,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    private func nextShorthandFileURL(in directoryURL: URL) -> URL {
        var timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var url = directoryURL.appendingPathComponent(String(timestamp) + ".md")
        while FileManager.default.fileExists(atPath: url.path) {
            timestamp += 1
            url = directoryURL.appendingPathComponent(String(timestamp) + ".md")
        }
        return url
    }
}

private enum ShorthandShareError: Error {
    case appGroupUnavailable
    case assetCollision
    case invalidStagedAsset
    case promotionFailed
}

private enum ShorthandAttachmentState {
    case active
    case submitting
    case cancelled
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
