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

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Override point for customization after application launch.
    // 设置通知代理
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  // MARK: UISceneSession Lifecycle

  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return UISceneConfiguration(
      name: "Default Configuration", sessionRole: connectingSceneSession.role)
  }

  func application(
    _ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>
  ) {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
  }

  // 关键：允许在前台时显示通知、播放声音
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // iOS 14+ 推荐使用 [.banner, .list, .sound]
    completionHandler([.banner, .sound, .badge])
  }
}

private struct LANSyncDiscoveryInfo: Decodable {
  let instance: String
  let serviceType: String
  let port: Int32
  let txt: [String: String]
}

final class LANSyncBonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  static let shared = LANSyncBonjour()

  private var browser: NetServiceBrowser?
  private var publishedService: NetService?
  private var publishedInfo = ""
  private var refreshTimer: Timer?
  private var resolvingServices: [NetService] = []

  func start() {
    guard refreshTimer == nil else { return }
    refreshAdvertisement()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      self?.refreshAdvertisement()
    }
  }

  func stop() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    stopDiscovery()
  }

  private func refreshAdvertisement() {
    let rawInfo = Iosk.MobileLANSyncDiscoveryInfo()
    guard !rawInfo.isEmpty, rawInfo != publishedInfo,
      let data = rawInfo.data(using: .utf8),
      let info = try? JSONDecoder().decode(LANSyncDiscoveryInfo.self, from: data)
    else {
      if rawInfo.isEmpty {
        stopDiscovery()
      }
      return
    }

    if browser == nil {
      let currentBrowser = NetServiceBrowser()
      currentBrowser.delegate = self
      currentBrowser.searchForServices(ofType: "_siyuan-sync._tcp.", inDomain: "local.")
      browser = currentBrowser
    }
    publishedService?.stop()
    let service = NetService(
      domain: "local.", type: info.serviceType, name: info.instance, port: info.port)
    service.setTXTRecord(
      NetService.data(fromTXTRecord: info.txt.mapValues { Data($0.utf8) }))
    service.delegate = self
    service.publish()
    publishedService = service
    publishedInfo = rawInfo
  }

  private func stopDiscovery() {
    browser?.stop()
    browser?.delegate = nil
    browser = nil
    publishedService?.stop()
    publishedService?.delegate = nil
    publishedService = nil
    publishedInfo = ""
    for service in resolvingServices {
      service.stop()
      service.delegate = nil
    }
    resolvingServices.removeAll()
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    service.delegate = self
    resolvingServices.append(service)
    service.resolve(withTimeout: 3)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    defer { removeResolvingService(sender) }
    guard let txtData = sender.txtRecordData() else { return }
    let txt = NetService.dictionary(fromTXTRecord: txtData).compactMapValues {
      String(data: $0, encoding: .utf8)
    }
    guard JSONSerialization.isValidJSONObject(txt),
      let jsonData = try? JSONSerialization.data(withJSONObject: txt),
      let txtJSON = String(data: jsonData, encoding: .utf8)
    else {
      return
    }
    for addressData in sender.addresses ?? [] {
      guard let address = numericAddress(addressData) else { continue }
      if Iosk.MobileAddLANSyncPeer(sender.name, address, Int(sender.port), txtJSON) {
        break
      }
    }
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
  ) {
    removeResolvingService(service)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    browser.delegate = nil
    self.browser = nil
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    guard sender === publishedService else { return }
    sender.delegate = nil
    publishedService = nil
    publishedInfo = ""
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    removeResolvingService(sender)
  }

  private func removeResolvingService(_ service: NetService) {
    resolvingServices.removeAll { $0 === service }
  }

  private func numericAddress(_ data: Data) -> String? {
    return data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return nil }
      let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(
        socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count),
        nil, 0, NI_NUMERICHOST) == 0
      else {
        return nil
      }
      return String(cString: host)
    }
  }
}
