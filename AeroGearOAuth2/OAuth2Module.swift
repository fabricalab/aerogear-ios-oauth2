/*
* JBoss, Home of Professional Open Source.
* Copyright Red Hat, Inc., and individual contributors
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation
import UIKit
import SafariServices
import AeroGearHttp
import AuthenticationServices
import CommonCrypto

/**
Notification constants emitted during oauth authorization flow.
*/
public let AGAppLaunchedWithURLNotification = "AGAppLaunchedWithURLNotification"
public let AGAppDidBecomeActiveNotification = "AGAppDidBecomeActiveNotification"
public let AGAuthzErrorDomain = "AGAuthzErrorDomain"

/**
The current state that this module is in.

- AuthorizationStatePendingExternalApproval: the module is waiting external approval.
- AuthorizationStateApproved: the oauth flow has been approved.
- AuthorizationStateUnknown: the oauth flow is in unknown state (e.g. user clicked cancel).
*/
enum AuthorizationState {
    case authorizationStatePendingExternalApproval
    case authorizationStateApproved
    case authorizationStateUnknown
}

/**
Parent class of any OAuth2 module implementing generic OAuth2 authorization flow.
*/
open class OAuth2Module : AuthzModule2 {
    /**
     Gateway to request authorization access.

     :param: completionHandler A block object to be executed when the request operation finishes.
     */

    let config: Config
    open var http: Http
    open var httpUserInfo: Http
    open var oauth2Session: OAuth2Session
    var applicationLaunchNotificationObserver: NSObjectProtocol?
    var applicationDidBecomeActiveNotificationObserver: NSObjectProtocol?
    var state: AuthorizationState
    //open var webView: OAuth2WebViewController? // UIWebView DEPRECATED, TODO with WKWebView
    //open var authenticationSession: SFAuthenticationSession? // DEPRECATED
    @available(iOS 12, *)
    private(set) lazy var webAuthenticationSession: ASWebAuthenticationSession? = nil
    @available(iOS 13, *)
    lazy public var contextProviding: ASWebAuthenticationPresentationContextProviding? = nil
    open var idToken: String?
    open var serverCode: String?
    open var customDismiss: Bool = false

    /**
    Initialize an OAuth2 module.

    :param: config the configuration object that setups the module.
    :param: session the session that that module will be bound to.
    :param: requestSerializer the actual request serializer to use when performing requests.
    :param: responseSerializer the actual response serializer to use upon receiving a response.

    :returns: the newly initialized OAuth2Module.
    */
    public required init(config: Config, session: OAuth2Session? = nil, requestSerializer: RequestSerializer = AuthHttpRequestSerializer(), responseSerializer: ResponseSerializer = JsonResponseSerializerByCharset()) {
        if (config.accountId == nil) {
            config.accountId = "ACCOUNT_FOR_CLIENTID_\(config.clientId)"
        }
        if (session == nil) {
            self.oauth2Session = TrustedPersistentOAuth2Session(accountId: config.accountId!)
        } else {
            self.oauth2Session = session!
        }

        self.config = config

        /* TODO with WKWebView
         if config.webView == .embeddedWebView {
            //self.webView = OAuth2WebViewController()
            self.customDismiss = true
        }*/

        if config.webView == .safariViewController {
            self.customDismiss = true
        }

        self.http = Http(baseURL: config.baseURL, requestSerializer: requestSerializer, responseSerializer:  responseSerializer)
        self.state = .authorizationStateUnknown
        
        self.httpUserInfo = config.baseURLUserInfo != nil ? Http(baseURL: config.baseURLUserInfo, requestSerializer: requestSerializer, responseSerializer:  responseSerializer) : self.http
        self.httpUserInfo.authzModule = self
    }

    // MARK: Public API - To be overridden if necessary by OAuth2 specific adapter

    /**
    Request an authorization code.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func requestAuthorizationCode(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        // register with the notification system in order to be notified when the 'authorization' process completes in the
        // external browser, and the oauth code is available so that we can then proceed to request the 'access_token'
        // from the server.
        applicationLaunchNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: AGAppLaunchedWithURLNotification), object: nil, queue: nil, using: { (notification: Notification!) -> Void in
            self.extractCode(notification, completionHandler: completionHandler)
            if (self.customDismiss) {
                //UIApplication.shared.keyWindow?.rootViewController?.dismiss(animated: true, completion: nil)
                UIApplication.shared.windows.filter {$0.isKeyWindow}.first?.rootViewController?.dismiss(animated: true, completion: nil)
            }
        })

        // register to receive notification when the application becomes active so we
        // can clear any pending authorization requests which are not completed properly,
        // that is a user switched into the app without Accepting or Cancelling the authorization
        // request in the external browser process.
        applicationDidBecomeActiveNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: AGAppDidBecomeActiveNotification), object:nil, queue:nil, using: { (note: Notification!) -> Void in
            // check the state
            if (self.state == .authorizationStatePendingExternalApproval) {
                // unregister
                self.stopObserving()
                // ..and update state
                self.state = .authorizationStateUnknown
            }
        })

        // update state to 'Pending'
        self.state = .authorizationStatePendingExternalApproval

        // calculate final url
        var params = "?scope=\(config.scope)&redirect_uri=\(config.redirectURL.urlEncode())&client_id=\(config.clientId)&response_type=code\(config.customParams ?? "")"

        if let audienceId = config.audienceId {
            params = "\(params)&audience=\(audienceId)"
        }
        
        //-- PKCE protocol implementation
        var verifier: String? = nil
        if config.enablePKCE {
            var buffer = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
            verifier = Data(buffer).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            
            if let data = verifier!.data(using: .utf8) {
                buffer = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                _ = data.withUnsafeBytes {
                    CC_SHA256($0.baseAddress, CC_LONG(data.count), &buffer)
                }
                let hash = Data(buffer)
                let challenge = hash.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                params = "\(params)&code_challenge=\(challenge)&code_challenge_method=S256"
            }
        }
        //--
        
        var stateParam: String? = nil
        if config.enableStateParam {
            stateParam = NSUUID().uuidString
            params = "\(params)&state=\(stateParam!)"
        }

        guard let computedUrl = http.calculateURL(baseURL: config.baseURL, url: config.authzEndpoint) else {
            let error = NSError(domain:AGAuthzErrorDomain, code:0, userInfo:["NSLocalizedDescriptionKey": "Malformatted URL."])
            completionHandler(nil, error)
            return
        }

        if let url = URL(string:computedUrl.absoluteString + params) {
            switch config.webView {
            //case .embeddedWebView: // TODO with WKWebView
            case .externalSafari:
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            case .safariViewController:
                let safariController = SFSafariViewController(url: url)
                config.webViewHandler(safariController, completionHandler)
            /* DEPRECATED
             case .sfAuthenticationSession:
                authenticationSession = SFAuthenticationSession(url: url, callbackURLScheme: "\(String(describing: NSURL(string: config.redirectURL)!.scheme!))", completionHandler: { completionUrl, error in
                    if let unwrappedError = error {
                        completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": String(describing: unwrappedError)]))
                    } else {
                        if let compUrl = completionUrl,  compUrl.absoluteString.lowercased().hasPrefix(self.config.redirectURL.lowercased()) {
                            let notification = Notification(name: NSNotification.Name(rawValue: AGAppLaunchedWithURLNotification), object: nil, userInfo: [UIApplication.LaunchOptionsKey.url:compUrl])
                            self.extractCode(notification, verifier: verifier, completionHandler: completionHandler)
                        } else {
                            completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": "CallbackUrl not match"]))
                        }

                    }
                })
                authenticationSession?.start() */
            case .asWebAuthenticationSession:
                if #available(iOS 12.0, *) {
                    self.webAuthenticationSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "\(String(describing: NSURL(string: config.redirectURL)!.scheme!))", completionHandler: { completionUrl, error in
                        if let unwrappedError = error {
                            completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": String(describing: unwrappedError)]))
                        } else {
                            if let compUrl = completionUrl,  compUrl.absoluteString.lowercased().hasPrefix(self.config.redirectURL.lowercased()) {
                                let queryParamsDict = compUrl.getQuerieParams
                                if let sp = stateParam, sp != queryParamsDict["state"] {
                                    completionHandler(nil, NSError(domain: "", code:0, userInfo:["Error": "State param callback is not equal to the state param sent"]))
                                    return
                                }
                                let notification = Notification(name: NSNotification.Name(rawValue: AGAppLaunchedWithURLNotification), object: nil, userInfo: [UIApplication.LaunchOptionsKey.url:compUrl])
                                self.extractCode(notification, verifier: verifier, completionHandler: completionHandler)
                            } else {
                                completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": "CallbackUrl not match"]))
                            }

                        }
                    })
                    if #available(iOS 13.0, *) {
                        self.webAuthenticationSession?.presentationContextProvider = self.contextProviding
                        self.webAuthenticationSession?.prefersEphemeralWebBrowserSession = self.config.prefersEphemeralWebBrowserSession
                    }
                    self.webAuthenticationSession?.start()
                }
            }
        }
    }

    /**
    Request to refresh an access token.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func refreshAccessToken(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        if let unwrappedRefreshToken = self.oauth2Session.refreshToken {
            var paramDict: [String: String] = ["refresh_token": unwrappedRefreshToken, "client_id": config.clientId, "grant_type": "refresh_token"]
            if (config.clientSecret != nil) {
                paramDict["client_secret"] = config.clientSecret!
            }

            http.request(method: .post, path: config.refreshTokenEndpoint!, parameters: paramDict as [String : AnyObject]?, completionHandler: { (response, error) in
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }

                if let unwrappedResponse = response as? [String: AnyObject] {
                    let accessToken: String = unwrappedResponse["access_token"] as! String
                    let expiration = unwrappedResponse["expires_in"] as! NSNumber
                    let exp: String = expiration.stringValue
                    var refreshToken = unwrappedRefreshToken
                    if let newRefreshToken = unwrappedResponse["refresh_token"] as? String {
                        refreshToken = newRefreshToken
                    }

                    self.oauth2Session.save(accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiration: exp, refreshTokenExpiration: nil, idToken: nil)

                    completionHandler(unwrappedResponse["access_token"], nil)
                }
            })
        }
    }

    /**
    Exchange an authorization code for an access token.

    :param: code the 'authorization' code to exchange for an access token.
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func exchangeAuthorizationCodeForAccessToken(code: String, verifier: String? = nil, completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        var paramDict: [String: String] = ["code": code, "client_id": config.clientId, "redirect_uri": config.redirectURL, "grant_type":"authorization_code"]

        if let unwrapped = config.clientSecret {
            paramDict["client_secret"] = unwrapped
        }

        if let audience = config.audienceId {
            paramDict["audience"] = audience
        }
        
        if let code_verifier = verifier { // PKCE compatibility
            paramDict["code_verifier"] = code_verifier
        }

        http.request(method: .post, path: config.accessTokenEndpoint, parameters: paramDict as [String : AnyObject]?, completionHandler: {(responseObject, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }

            if let unwrappedResponse = responseObject as? [String: AnyObject] {
                let accessToken = self.tokenResponse(unwrappedResponse)
                completionHandler(accessToken as AnyObject?, nil)
            }
        })
    }

    open func tokenResponse(_ unwrappedResponse: [String: AnyObject]) -> String {
        let accessToken: String   = unwrappedResponse["access_token"] as! String
        let refreshToken: String? = unwrappedResponse["refresh_token"] as? String
        let idToken: String?      = unwrappedResponse["id_token"] as? String
        let serverCode: String?   = unwrappedResponse["server_code"] as? String
        let expiration            = unwrappedResponse["expires_in"] as? NSNumber
        let exp: String?          = expiration?.stringValue
        // expiration for refresh token is used in Keycloak
        let expirationRefresh     = unwrappedResponse["refresh_expires_in"] as? NSNumber
        let expRefresh            = expirationRefresh?.stringValue

        self.oauth2Session.save(accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiration: exp, refreshTokenExpiration: expRefresh, idToken: idToken)
        self.idToken    = self.oauth2Session.idToken
        self.serverCode = serverCode

        return accessToken
    }

    /**
    Gateway to request authorization access.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func requestAccess(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        self.requestAccessByRefreshToken { (token, error) in
            if let accessToken = token {
                completionHandler(accessToken, nil)
            }else {
                self.requestAuthorizationCode(completionHandler: completionHandler)
            }
        }
    }
    
    /**
     Returns the current access token if it's not expired, otherwise retrieves it using refresh token.
     Returns an error if none of the two attempts is successfully completed
     - Parameter completionHandler: callback function with access token or error
     */
    open func requestAccessByRefreshToken(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        if (self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()) {
            // we already have a valid access token, nothing more to be done
            completionHandler(self.oauth2Session.accessToken! as AnyObject?, nil)
        } else if (self.oauth2Session.refreshToken != nil && self.oauth2Session.refreshTokenIsNotExpired()) {
            // need to refresh token
            self.refreshAccessToken(completionHandler: completionHandler)
        } else {
            // cannot get access token using refresh token
            completionHandler(nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["OpenID Connect" : "Can't get access token using refresh token" ]))
        }
    }

    /**
    Gateway to provide authentication using the Authorization Code Flow with OpenID Connect.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func login(completionHandler: @escaping (AnyObject?, OpenIdClaim?, NSError?) -> Void) {

        self.requestAccess { (response: AnyObject?, error: NSError?) -> Void in

            if (error != nil) {
                completionHandler(nil, nil, error)
                return
            }
            let paramDict: [String: String] = [:]
            /* access token will no more sent by request params (Okta fails)
             if response != nil {
                paramDict = ["access_token": response! as! String]
            }*/
            if let userInfoEndpoint = self.config.userInfoEndpoint {

                self.httpUserInfo.request(method: .get, path:userInfoEndpoint, parameters: paramDict as [String : AnyObject]?, completionHandler: {(responseObject, error) in
                    if (error != nil) {
                        completionHandler(nil, nil, error)
                        return
                    }
                    var openIDClaims: OpenIdClaim?
                    if let unwrappedResponse = responseObject as? [String: AnyObject] {
                        openIDClaims = self.makeOpenIdClaim(fromDict: unwrappedResponse)
                    }
                    completionHandler(response, openIDClaims, nil)
                })
            } else {
                completionHandler(nil, nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["OpenID Connect" : "No UserInfo endpoint available in config"]))
                return
            }

        }

    }

    open func makeOpenIdClaim(fromDict: [String: AnyObject]) -> OpenIdClaim {
        return OpenIdClaim(fromDict: fromDict)
    }

    /**
    Request to revoke access.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func revokeAccess(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        // return if not yet initialized
        if (self.oauth2Session.accessToken == nil) {
            return
        }
        // return if no revoke endpoint
        guard let revokeTokenEndpoint = config.revokeTokenEndpoint else {
            return
        }

        let paramDict: [String:String] = ["token":self.oauth2Session.accessToken!]

        http.request(method: .post, path: revokeTokenEndpoint, parameters: paramDict as [String : AnyObject]?, completionHandler: { (response, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }

            self.oauth2Session.clearTokens()
            completionHandler(response as AnyObject?, nil)
        })
    }

    /**
    Return any authorization fields.

    :returns:  a dictionary filled with the authorization fields.
    */
    open func authorizationFields() -> [String: String]? {
        if (self.oauth2Session.accessToken == nil) {
            return nil
        } else {
            return ["Authorization":"Bearer \(self.oauth2Session.accessToken!)"]
        }
    }

    /**
    Returns a boolean indicating whether authorization has been granted.

    :returns: true if authorized, false otherwise.
    */
    open func isAuthorized() -> Bool {
        return self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()
    }
    
    /**
    Perform logout with the specified url in config

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    public func logout(completionHandler: @escaping (AnyObject?, NSError?) -> Void){
        if let urlString = self.config.logoutURL, let url = URL(string: urlString) {
            switch config.webView {
            //case .embeddedWebView: // TODO with WKWebView
            case .externalSafari:
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            case .safariViewController:
                let safariController = SFSafariViewController(url: url)
                config.webViewHandler(safariController, completionHandler)
            /*
            case .sfAuthenticationSession:
                authenticationSession = SFAuthenticationSession(url: url, callbackURLScheme: "\(String(describing: NSURL(string: config.redirectURL)!.scheme!))", completionHandler: { completionUrl, error in
                    if let unwrappedError = error {
                        completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": String(describing: unwrappedError)]))
                    } else {
                        completionHandler(completionUrl as AnyObject?, nil)
                    }
                })
                authenticationSession?.start()
              */
            case .asWebAuthenticationSession:
                if #available(iOS 12.0, *) {
                    self.webAuthenticationSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "\(String(describing: NSURL(string: config.redirectURL)!.scheme!))", completionHandler: { completionUrl, error in
                        if let unwrappedError = error {
                            completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": String(describing: unwrappedError)]))
                        } else {
                            completionHandler(completionUrl as AnyObject?, nil)
                        }
                    })
                    if #available(iOS 13.0, *) {
                        self.webAuthenticationSession?.presentationContextProvider = self.contextProviding
                    }
                    self.webAuthenticationSession?.start()
                }
            }
        }else {
            completionHandler(nil, NSError(domain: "", code: 0, userInfo: ["Error": "No logout url found"]))
        }
    }

    // MARK: Internal Methods

    func extractCode(_ notification: Notification, verifier: String? = nil, completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        let info = notification.userInfo!
        let url: URL? = info[UIApplication.LaunchOptionsKey.url] as? URL

        // extract the code from the URL
        let queryParamsDict = url?.getQuerieParams ?? [:]
        let code = queryParamsDict["code"]
        // if exists perform the exchange
        if (code != nil) {
            self.exchangeAuthorizationCodeForAccessToken(code: code!, verifier: verifier, completionHandler: completionHandler)
            // update state
            state = .authorizationStateApproved
        } else {
            guard let errorName = queryParamsDict["error"] else {
                let error = NSError(domain:AGAuthzErrorDomain, code:0, userInfo:["NSLocalizedDescriptionKey": "User cancelled authorization."])
                completionHandler(nil, error)
                return
            }

            let errorDescription = queryParamsDict["error_description"] ?? "There was an error!"
            let error = NSError(domain: AGAuthzErrorDomain, code: 1, userInfo: ["error": errorName, "errorDescription": errorDescription])

            completionHandler(nil, error)
        }
        // finally, unregister
        self.stopObserving()
    }

    
    deinit {
        self.stopObserving()
    }

    func stopObserving() {
        // clear all observers
        if (applicationLaunchNotificationObserver != nil) {
            NotificationCenter.default.removeObserver(applicationLaunchNotificationObserver!)
            self.applicationLaunchNotificationObserver = nil
        }

        if (applicationDidBecomeActiveNotificationObserver != nil) {
            NotificationCenter.default.removeObserver(applicationDidBecomeActiveNotificationObserver!)
            applicationDidBecomeActiveNotificationObserver = nil
        }
    }
}
