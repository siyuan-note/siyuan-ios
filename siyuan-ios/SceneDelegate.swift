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

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let _ = (scene as? UIWindowScene) else { return }
        for context in connectionOptions.urlContexts{
            handleURLContext(context)
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts{
            handleURLContext(context)
        }
    }
    
    // Handle URL context for both OIDC callbacks and block URLs
    private func handleURLContext(_ context: UIOpenURLContext) {
        let url = context.url
        
        // Check if this is an OIDC callback
        // OIDC callbacks typically contain certain query parameters or paths
        if isOIDCCallback(url) {
            // Handle OIDC callback - similar to Android's onNewIntent with oidcCallback
            let urlString = url.absoluteString
            let escapedURL = escapeJavaScriptString(urlString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                ViewController.syWebView.evaluateJavaScript("window.handleOidcCallbackLink('\(escapedURL)')", completionHandler: { result, error in
                    if let error = error {
                        print("Error calling handleOidcCallbackLink: \(error)")
                    }
                })
            }
        } else {
            // Handle regular block URL
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                ViewController.syWebView.evaluateJavaScript("window.openFileByURL('" + url.absoluteString + "')")
            }
        }
    }
    
    // Check if the URL is an OIDC callback
    private func isOIDCCallback(_ url: URL) -> Bool {
        // Check if URL contains typical OIDC callback parameters
        // Common OIDC callback parameters: code, state, error, error_description
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return false
        }
        
        // Check for common OIDC callback parameters
        let oidcParams = ["code", "state", "error", "error_description", "id_token", "access_token"]
        return queryItems.contains { item in
            oidcParams.contains(item.name)
        }
    }
    
    // Escape JavaScript string to prevent injection
    private func escapeJavaScriptString(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }


    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}

