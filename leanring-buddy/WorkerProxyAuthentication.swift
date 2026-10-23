//
//  WorkerProxyAuthentication.swift
//  leanring-buddy
//
//  Attaches the shared secret that the Cloudflare Worker requires on every
//  request. Without it the worker is an open proxy: anyone who finds its URL
//  (which is compiled into the app) could spend the API credit behind it.
//
//  The secret flows from the gitignored Config/Secrets.xcconfig build setting
//  into the ClickyProxySharedSecret Info.plist key, so it is never committed.
//

import Foundation

enum WorkerProxyAuthentication {
    static let sharedSecretHeaderName = "X-Clicky-Proxy-Secret"

    private static let sharedSecretFromInfoPlist: String? = {
        let configuredSharedSecret = AppBundleConfiguration.stringValue(forKey: "ClickyProxySharedSecret")
        if configuredSharedSecret == nil {
            print("⚠️ Clicky: ClickyProxySharedSecret is not set. Add CLICKY_PROXY_SHARED_SECRET to Config/Secrets.xcconfig or the worker will reject every request.")
        }
        return configuredSharedSecret
    }()

    static func addSharedSecretHeader(to request: inout URLRequest) {
        guard let sharedSecretFromInfoPlist else { return }
        request.setValue(sharedSecretFromInfoPlist, forHTTPHeaderField: sharedSecretHeaderName)
    }
}
