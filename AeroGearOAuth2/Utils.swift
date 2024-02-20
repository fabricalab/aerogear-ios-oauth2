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
}
