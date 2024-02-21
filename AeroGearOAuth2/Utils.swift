//
//  Utils.swift
//  AeroGearOAuth2
//
//  Created by Daniele Niccolini on 20/02/24.
//  Copyright © 2024 aerogear. All rights reserved.
//

import Foundation


extension URL {
    
    var getQuerieParams: [String: String] {
        var dict: [String:String] = [:]
        let items = URLComponents(string: absoluteString)?.queryItems ?? []
        items.forEach { dict.updateValue($0.value ?? "", forKey: $0.name) }
        return dict
    }
    
    func addParamsToNewUrl(params: [String: String], withEncoding: CharacterSet? = nil) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: true)
        var queryItems:[URLQueryItem] = components?.queryItems ?? []
        queryItems.append(contentsOf: params.map{(key, value) in URLQueryItem(name: key, value: value.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.urlHostAllowed)!)})
        if let cs = withEncoding {
            components?.percentEncodedQuery = queryItems.map {
                $0.name.addingPercentEncoding(withAllowedCharacters: cs)! + "=" + $0.value!.addingPercentEncoding(withAllowedCharacters: cs)!
            }.joined(separator:"&")
        }else {
            components?.queryItems = queryItems
        }
        return components?.url
    }
}
