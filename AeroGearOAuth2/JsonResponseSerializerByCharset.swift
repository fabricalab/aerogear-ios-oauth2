//
//  JsonResponseSerializerByCharset.swift
//  AeroGearOAuth2
//
//  Created by Fabricalab on 03/06/2019.
//  Copyright © 2019 aerogear. All rights reserved.
//

import Foundation
import AeroGearHttp


open class JsonResponseSerializerByCharset : JsonResponseSerializer {
    
    private enum Charset:String {
        case UTF_8 = "UTF-8"
        case ISO_8859_1 = "ISO-8859-1"
    }
    
    var charset:String = Charset.UTF_8.rawValue
    
    
    public override init() {
        super.init()
        
        self.validation = { [unowned self] (response: URLResponse?, data: Data) -> Void  in
            var error: NSError! = NSError(domain: HttpErrorDomain, code: 0, userInfo: nil)
            let httpResponse = response as! HTTPURLResponse
            self.charset = httpResponse.textEncodingName ?? Charset.UTF_8.rawValue
            let dataAsJson: [String: Any]?
            
            // validate JSON
            do {
                dataAsJson = try self.readResponseByCharset(data: data)
            } catch  _  {
                let userInfo = [NSLocalizedDescriptionKey: "Invalid response received, can't parse JSON" as NSString,
                                NetworkingOperationFailingURLResponseErrorKey: response ?? "HttpErrorDomain"] as [String : Any]
                let customError = NSError(domain: HttpResponseSerializationErrorDomain, code: NSURLErrorBadServerResponse, userInfo: userInfo)
                throw customError;
            }
            
            if !(httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
                var userInfo = [NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                                NetworkingOperationFailingURLResponseErrorKey: response ??  "HttpErrorDomain"] as [String : Any]
                if let dataAsJson = dataAsJson {
                    userInfo["CustomData"] = dataAsJson           }
                error = NSError(domain: HttpResponseSerializationErrorDomain, code: httpResponse.statusCode, userInfo: userInfo)
                throw error
            }
        }
        
        self.response = { [unowned self] (data: Data, Int) -> Any? in
            do {
                return try self.readResponseByCharset(data: data)
            } catch _ {
                return nil
            }
        }
    }
    
    /**
     Decodifica dati raw in base al charset ottenuto dalla response
     - Returns: chiave valore del json contenuto in data
     */
    private func readResponseByCharset(data: Data) throws -> [String: Any]?{
        if charset.uppercased() == Charset.ISO_8859_1.rawValue {
            let decoded = String(data: data, encoding: String.Encoding.isoLatin1)
            let dataUTF8:Data? = decoded!.data(using: .utf8)
            return try JSONSerialization.jsonObject(with: dataUTF8!, options: JSONSerialization.ReadingOptions(rawValue: 0)) as? [String: Any]
        }else {
            return try JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions(rawValue: 0)) as? [String: Any]
        }
    }
}
