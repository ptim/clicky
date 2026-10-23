//
//  WorkerProxyConfiguration.swift
//  leanring-buddy
//
//  Single source of truth for where the Cloudflare Worker proxy lives.
//
//  The base URL flows from the CLICKY_WORKER_BASE_URL build setting
//  (default in Config/Clicky.xcconfig, overridable in the gitignored
//  Config/Secrets.xcconfig) into the ClickyWorkerBaseURL Info.plist key,
//  so switching between a deployed worker and `wrangler dev` needs no
//  code changes.
//

import Foundation

enum WorkerProxyConfiguration {
    static let workerBaseURL: String = {
        guard let configuredWorkerBaseURL = AppBundleConfiguration.stringValue(forKey: "ClickyWorkerBaseURL") else {
            fatalError("ClickyWorkerBaseURL is not set. Set CLICKY_WORKER_BASE_URL in Config/Secrets.xcconfig.")
        }

        // Strip a trailing slash so route URLs don't end up with `//chat`.
        let workerBaseURLWithoutTrailingSlash = configuredWorkerBaseURL.hasSuffix("/")
            ? String(configuredWorkerBaseURL.dropLast())
            : configuredWorkerBaseURL
        print("🌐 Clicky: using worker proxy at \(workerBaseURLWithoutTrailingSlash)")
        return workerBaseURLWithoutTrailingSlash
    }()

    static var chatURL: String { "\(workerBaseURL)/chat" }
    static var textToSpeechURL: String { "\(workerBaseURL)/tts" }
    static var transcribeTokenURL: String { "\(workerBaseURL)/transcribe-token" }
}
