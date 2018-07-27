import Foundation

open class SFAuthenticationModule: OAuth2Module {

    override open func requestAuthorizationCode(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        applicationLaunchNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: AGAppLaunchedWithURLNotification), object: nil, queue: nil, using: { (notification: Notification!) -> Void in
            self.extractCode(notification, completionHandler: completionHandler)
            if ( self.webView != nil || self.customDismiss) {
                UIApplication.shared.keyWindow?.rootViewController?.dismiss(animated: true, completion: nil)
            }
        })

        applicationDidBecomeActiveNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: AGAppDidBecomeActiveNotification), object:nil, queue:nil, using: { (note: Notification!) -> Void in
            // check the state
            if (self.state == .authorizationStatePendingExternalApproval) {
                // unregister
                self.stopSFObserving()
                // ..and update state
                self.state = .authorizationStateUnknown
            }
        })

        self.state = .authorizationStatePendingExternalApproval

        var params = "?scope=\(config.scope)&redirect_uri=\(config.redirectURL.urlEncode())&client_id=\(config.clientId)&response_type=code"

        if let audienceId = this.config.audienceId {
            params = "\(params)&audience=\(audienceId)"
        }

        guard let computedUrl = http.calculateURL(baseURL: config.baseURL, url: config.authzEndpoint) else {
            let error = NSError(domain:AGAuthzErrorDomain, code:0, userInfo:["NSLocalizedDescriptionKey": "Malformatted URL."])
            completionHandler(nil, error)
            return
        }

        if let url = URL(string:computedUrl.absoluteString + params) {
            let session = SFAuthenticationSession(url: url, callbackURLScheme: "\(String(describing: NSURL(string: config.redirectURL)!.scheme))://", completionHandler: completionHandler)
            session.start()
        }
    }
}

