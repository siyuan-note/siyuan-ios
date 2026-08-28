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

import Foundation

final class ShorthandDraftStore {

  private static let appGroupIdentifier = "group.com.ld246.siyuan"
  private static let saveDelay = DispatchTimeInterval.milliseconds(250)

  private let fileName: String
  private let queue: DispatchQueue
  private var pendingSave: DispatchWorkItem?
  private var revision: UInt64 = 0
  private var isAvailable = true

  init(fileName: String) {
    self.fileName = fileName
    self.queue = DispatchQueue(label: "com.ld246.siyuan.shorthand-draft.\(fileName)")
  }

  func load() -> Result<String, Error> {
    return queue.sync {
      do {
        let url = try draftURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
          isAvailable = true
          return .success("")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        isAvailable = true
        return .success(text)
      } catch {
        isAvailable = false
        print("shorthand draft read failed: \(error)")
        return .failure(error)
      }
    }
  }

  func scheduleSave(_ text: String) {
    queue.async { [self] in
      guard isAvailable else { return }
      revision &+= 1
      let taskRevision = revision
      pendingSave?.cancel()
      if text.isEmpty {
        pendingSave = nil
        if !removeDraft() {
          print("shorthand draft clear failed")
        }
        return
      }
      let workItem = DispatchWorkItem { [weak self] in
        guard let self = self, taskRevision == self.revision else { return }
        _ = self.write(text)
        if taskRevision == self.revision {
          self.pendingSave = nil
        }
      }
      pendingSave = workItem
      queue.asyncAfter(deadline: .now() + Self.saveDelay, execute: workItem)
    }
  }

  @discardableResult
  func flush(_ text: String) -> Bool {
    return queue.sync {
      guard isAvailable else { return false }
      revision &+= 1
      pendingSave?.cancel()
      pendingSave = nil
      return text.isEmpty ? removeDraft() : write(text)
    }
  }

  @discardableResult
  func clear() -> Bool {
    return queue.sync {
      guard isAvailable else { return false }
      revision &+= 1
      pendingSave?.cancel()
      pendingSave = nil
      return removeDraft()
    }
  }

  @discardableResult
  func promote(_ text: String, to destinationURL: URL) -> Bool {
    return queue.sync {
      guard isAvailable else { return false }
      revision &+= 1
      pendingSave?.cancel()
      pendingSave = nil
      guard write(text) else { return false }

      do {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
          throw ShorthandDraftStoreError.destinationExists
        }
        let sourceURL = try draftURL(createDirectory: false)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return true
      } catch {
        print("shorthand draft promotion failed: \(error)")
        return false
      }
    }
  }

  private func draftURL(createDirectory: Bool = true) throws -> URL {
    guard
      let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    else {
      throw ShorthandDraftStoreError.appGroupUnavailable
    }

    let directoryURL = containerURL
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("ShorthandDrafts", isDirectory: true)
    if createDirectory {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true, attributes: nil)
    }
    return directoryURL.appendingPathComponent(fileName)
  }

  private func write(_ text: String) -> Bool {
    do {
      let url = try draftURL()
      try Data(text.utf8).write(to: url, options: .atomic)
      return true
    } catch {
      print("shorthand draft write failed: \(error)")
      return false
    }
  }

  private func removeDraft() -> Bool {
    do {
      let url = try draftURL(createDirectory: false)
      guard FileManager.default.fileExists(atPath: url.path) else { return true }
      do {
        try FileManager.default.removeItem(at: url)
        return true
      } catch {
        print("shorthand draft delete failed: \(error)")
      }

      let handle = try FileHandle(forWritingTo: url)
      defer {
        try? handle.close()
      }
      try handle.truncate(atOffset: 0)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return (attributes[.size] as? NSNumber)?.uint64Value == 0
    } catch {
      print("shorthand draft clear failed: \(error)")
      return false
    }
  }
}

private enum ShorthandDraftStoreError: Error {
  case appGroupUnavailable
  case destinationExists
}
