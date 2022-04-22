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

class ViewController: UIViewController, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {

    let syWebView = WKWebView()
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
        syWebView.configuration.preferences.javaScriptEnabled = true
        syWebView.configuration.userContentController.add(self, name: "startKernelFast")
        syWebView.configuration.userContentController.add(self, name: "changeStatusBar")
        syWebView.configuration.userContentController.add(self, name: "setClipboard")
        
        // open url
        syWebView.navigationDelegate = self
        
        // show keyboard
        syWebView.scrollView.isScrollEnabled = false
        syWebView.scrollView.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide), name: UIResponder.keyboardDidHideNotification, object: nil)
        
        // 息屏/应用切换
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        waitFotKernelHttpServing()
        syWebView.load(URLRequest(url: url))
        
        view.addSubview(syWebView)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if syWebView.frame.width != view.safeAreaLayoutGuide.layoutFrame.width || !keyboardShowed {
            syWebView.frame = view.safeAreaLayoutGuide.layoutFrame
        }
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
            Iosk.MobileStartKernelFast("ios", Bundle.main.resourcePath, urls[0].path, "", "", "")
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
            (
                url!.description.lowercased().starts(with: "http://127.0.0.1:6806") == false &&
                (navigationAction.targetFrame?.request) != nil && navigationAction.targetFrame?.request.url?.description.lowercased().starts(with: "http://127.0.0.1:6806") == true
            )
        ) &&
        UIApplication.shared.canOpenURL(url!) {
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
        Iosk.MobileSetDefaultLang("zh_CN")
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = urls[0]
        Iosk.MobileStartKernel("ios", Bundle.main.resourcePath, documentsDirectory.path, "", "", TimeZone.current.identifier, "");
    }
    
    func waitFotKernelHttpServing() {
        for _ in 1...500 {
            usleep(10000);
            if (Iosk.MobileIsHttpServing()) {
                break;
            }
        }
     }
    
    @objc func keyboardDidHide(notification: NSNotification) {
        keyboardShowed = true
        if syWebView.frame.size.height != view.safeAreaLayoutGuide.layoutFrame.height {
            syWebView.frame.size.height = view.safeAreaLayoutGuide.layoutFrame.height
        }
    }
    
    @objc func keyboardDidShow(notification: NSNotification) {
        keyboardShowed = true
        let keyboardHeight = (notification.userInfo![UIResponder.keyboardFrameEndUserInfoKey] as! NSValue).cgRectValue.height
        let mainHeight = view.safeAreaLayoutGuide.layoutFrame.height
        - keyboardHeight + view.safeAreaInsets.bottom
        if syWebView.frame.size.height != mainHeight {
            syWebView.frame.size.height = mainHeight
        }
    }
    
    @objc func willEnterForeground(_ notification: NSNotification!) {
        // iOS 端息屏后内核退出，再次进入时重新拉起内核
        let url = URL(string: "http://127.0.0.1:6806/api/system/version")!
        let task = URLSession.shared.dataTask(with: url) {(data, response, error) in
            guard let _ = data, error == nil else {
                DispatchQueue.main.async {
                    self.syWebView.evaluateJavaScript("var logElement = document.getElementById('errorLog');if(logElement){logElement.remove();}", completionHandler: nil)
                }
                let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                Iosk.MobileStartKernelFast("ios", Bundle.main.resourcePath, urls[0].path, "", "", "")
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
