//
//  File.swift
//  AeroGearOAuth2
//
//  Created by Fabricalab on 06/05/2020.
//  Copyright © 2020 aerogear. All rights reserved.
//

import Foundation
import AeroGearHttp

public class AuthHttpRequestSerializer: HttpRequestSerializer {
    override public func request(url: URL, method: HttpMethod, parameters: [String : Any]?, headers: [String : String]? = nil) -> URLRequest {
        var request:URLRequest = super.request(url: url, method: method, parameters: parameters, headers: headers)
        // add access token parameter to header
        if method == .get, request.allHTTPHeaderFields?["Authorization"] == nil, let access_token = parameters?["access_token"] as? String{
            request.addValue("Bearer \(access_token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
