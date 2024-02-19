//
//  AuthzModule2.swift
//  AeroGearOAuth2
//
//  Created by Daniele Niccolini on 19/02/24.
//  Copyright © 2024 aerogear. All rights reserved.
//

import Foundation
import AeroGearHttp


public protocol AuthzModule2 : AuthzModule {
    
    
    /**
     2.0: verifier added for PKCE protocol compatibility
    Exchange an authorization code for an access token.
    
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    func exchangeAuthorizationCodeForAccessToken(code: String, verifier: String?, completionHandler: @escaping (AnyObject?, NSError?) -> Void)
}


extension AuthzModule {
        
    
    public func exchangeAuthorizationCodeForAccessToken(code: String, completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        fatalError("This method is not implemented, use exchangeAuthorizationCodeForAccessToken with different signature")
    }
}
