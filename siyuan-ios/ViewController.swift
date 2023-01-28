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
import WebKit
import Iosk
import PDFKit
import GameController

class ViewController: UIViewController, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {

    static let syWebView = WKWebView()
    var keyboardShowed = false
    var isDarkStyle = false
    
    deinit {
       // make sure to remove the observer when this view controller is dismissed/deallocated
       NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let url = URL(string: "http://127.0.0.1:6806/appearance/boot/index.html") else {
            return
        }
        
        initKernel()
        
        // js 中调用 swift
        ViewController.syWebView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        ViewController.syWebView.configuration.userContentController.add(self, name: "startKernelFast")
        ViewController.syWebView.configuration.userContentController.add(self, name: "changeStatusBar")
        ViewController.syWebView.configuration.userContentController.add(self, name: "setClipboard")
        
        // open url
        ViewController.syWebView.navigationDelegate = self
        
        // show keyboard
        ViewController.syWebView.scrollView.isScrollEnabled = false
        ViewController.syWebView.scrollView.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        
        // 息屏/应用切换
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        waitFotKernelHttpServing()
        ViewController.syWebView.load(URLRequest(url: url))
        
        view.addSubview(ViewController.syWebView)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if ViewController.syWebView.frame.width != view.safeAreaLayoutGuide.layoutFrame.width || !keyboardShowed {
            ViewController.syWebView.frame = view.safeAreaLayoutGuide.layoutFrame
        }
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    override var prefersStatusBarHidden: Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return isDarkStyle ? .lightContent : .darkContent
    }
    
    func UIColorFromRGB(_ rgbValue: Int) -> UIColor! {
        return UIColor(
            red: CGFloat((Float((rgbValue & 0xff0000) >> 16)) / 255.0),
            green: CGFloat((Float((rgbValue & 0x00ff00) >> 8)) / 255.0),
            blue: CGFloat((Float((rgbValue & 0x0000ff) >> 0)) / 255.0),
            alpha: 1.0)
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "startKernelFast" {
            let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            Iosk.MobileStartKernelFast("ios", Bundle.main.resourcePath, urls[0].path, "")
        } else if message.name == "changeStatusBar" {
            let argument = (message.body as! String).split(separator: " ");
            if (argument[1] == "0") {
                isDarkStyle = false
            } else {
                isDarkStyle = true
            }
            self.view.backgroundColor = UIColor.init(hexString: String(argument[0]))
            setNeedsStatusBarAppearanceUpdate()
        } else if message.name == "setClipboard" {
            UIPasteboard.general.string = (message.body as! String)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        guard url != nil else {
            print(url!)
            decisionHandler(.allow)
            return
        }
        if url!.description == "siyuan://api/system/exit" {
            decisionHandler(.cancel)
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        } else if (
            url!.description.lowercased().starts(with: "http://127.0.0.1:6806/assets") == true ||
            url!.description.lowercased().starts(with: "http://127.0.0.1:6806/export") == true || // 导出 Data
            (
                url!.description.lowercased().starts(with: "http://127.0.0.1:6806") == false &&
                navigationAction.targetFrame?.request != nil && navigationAction.targetFrame?.request.url?.description.lowercased().starts(with: "http://127.0.0.1:6806") == true
            )
        ) && UIApplication.shared.canOpenURL(url!) {
            decisionHandler(.cancel)
            UIApplication.shared.open(url!, options: [:], completionHandler: nil)
        } else if navigationAction.navigationType == .linkActivated && UIApplication.shared.canOpenURL(url!) {
            decisionHandler(.cancel)
            UIApplication.shared.open(url!, options: [:], completionHandler: nil)
        } else {
            decisionHandler(.allow)
        }
    }
    
    func initKernel () {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        Iosk.MobileStartKernel("ios", Bundle.main.resourcePath, urls[0].path, TimeZone.current.identifier, getIP(), Locale.preferredLanguages[0].prefix(2) == "zh" ? "zh_CN" : "en_US");
    }
    
    func waitFotKernelHttpServing() {
        for _ in 1...500 {
            usleep(100000); // 0.1s
            if (Iosk.MobileIsHttpServing()) {
                break;
            }
        }
     }
    
    func getIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next } // memory has been renamed to pointee in swift 3 so changed memory to pointee
                guard let interface = ptr?.pointee else {
                    return nil
                }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                    guard let ifa_name = interface.ifa_name else {
                        return nil
                    }
                    let name: String = String(cString: ifa_name)
                    
                    if name == "en0" {  // String.fromCString() is deprecated in Swift 3. So use the following code inorder to get the exact IP Address.
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t((interface.ifa_addr.pointee.sa_len)), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
    
    @objc func keyboardWillChange(notification: NSNotification) {
        keyboardShowed = true
        if (GCKeyboard.coalesced != nil) {
            if ViewController.syWebView.frame.size.height != view.safeAreaLayoutGuide.layoutFrame.height {
                ViewController.syWebView.frame.size.height = view.safeAreaLayoutGuide.layoutFrame.height
            }
        } else {
            guard let userInfo = notification.userInfo else { return }
            let endFrameRect = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            if (endFrameRect?.origin.y ?? 0) >= UIScreen.main.bounds.size.height {
                if ViewController.syWebView.frame.size.height != view.safeAreaLayoutGuide.layoutFrame.height {
                    ViewController.syWebView.frame.size.height = view.safeAreaLayoutGuide.layoutFrame.height
                }
                ViewController.syWebView.evaluateJavaScript("hideKeyboardToolbar()")
            } else {
                let mainHeight = view.safeAreaLayoutGuide.layoutFrame.height - (endFrameRect?.height ?? 0) + view.safeAreaInsets.bottom
                if ViewController.syWebView.frame.size.height != mainHeight {
                    ViewController.syWebView.frame.size.height = mainHeight
                }
                ViewController.syWebView.evaluateJavaScript("showKeyboardToolbar()")
            }
        }
    }
    
    @objc func willEnterForeground(_ notification: NSNotification!) {
        // iOS 端息屏后内核退出，再次进入时重新拉起内核
        let url = URL(string: "http://127.0.0.1:6806/api/system/version")!
        let task = URLSession.shared.dataTask(with: url) {(data, response, error) in
            guard let _ = data, error == nil else {
                DispatchQueue.main.async {
                    ViewController.syWebView.evaluateJavaScript("var logElement = document.getElementById('errorLog');if(logElement){logElement.remove();}", completionHandler: nil)
                }
                let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                Iosk.MobileStartKernelFast("ios", Bundle.main.resourcePath, urls[0].path, "")
                return
            }
        }
        task.resume()
    }
}
extension UIColor {
    convenience init?(hexString: String?) {
        let input: String! = (hexString ?? "")
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        var alpha: CGFloat = 1.0
        var red: CGFloat = 0
        var blue: CGFloat = 0
        var green: CGFloat = 0
        switch (input.count) {
        case 3 /* #RGB */:
            red = Self.colorComponent(from: input, start: 0, length: 1)
            green = Self.colorComponent(from: input, start: 1, length: 1)
            blue = Self.colorComponent(from: input, start: 2, length: 1)
            break
        case 4 /* #ARGB */:
            alpha = Self.colorComponent(from: input, start: 0, length: 1)
            red = Self.colorComponent(from: input, start: 1, length: 1)
            green = Self.colorComponent(from: input, start: 2, length: 1)
            blue = Self.colorComponent(from: input, start: 3, length: 1)
            break
        case 6 /* #RRGGBB */:
            red = Self.colorComponent(from: input, start: 0, length: 2)
            green = Self.colorComponent(from: input, start: 2, length: 2)
            blue = Self.colorComponent(from: input, start: 4, length: 2)
            break
        case 8 /* #AARRGGBB */:
            alpha = Self.colorComponent(from: input, start: 0, length: 2)
            red = Self.colorComponent(from: input, start: 2, length: 2)
            green = Self.colorComponent(from: input, start: 4, length: 2)
            blue = Self.colorComponent(from: input, start: 6, length: 2)
            break
        default:
            NSException.raise(NSExceptionName("Invalid color value"), format: "Color value \"%@\" is invalid.  It should be a hex value of the form #RBG, #ARGB, #RRGGBB, or #AARRGGBB", arguments:getVaList([hexString ?? ""]))
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
    
    static func colorComponent(from string: String!, start: Int, length: Int) -> CGFloat {
        let substring = (string as NSString)
            .substring(with: NSRange(location: start, length: length))
        let fullHex = length == 2 ? substring : "\(substring)\(substring)"
        var hexComponent: UInt64 = 0
        Scanner(string: fullHex)
            .scanHexInt64(&hexComponent)
        return CGFloat(Double(hexComponent) / 255.0)
    }
}
