//
//  OllamaAPI.swift
//  leanring-buddy
//
//  Client for a locally running Ollama server (https://ollama.com). Talks to
//  it directly rather than through the Cloudflare Worker: Ollama runs on the
//  user's own machine, needs no API key, and the screenshots never leave it.
//
//  Uses Ollama's native /api endpoints rather than its OpenAI-compatible
//  ones because only the native /api/tags reports each model's capabilities,
//  which is how the picker knows whether a model can see screenshots.
//

import Foundation

/// One model the local Ollama server has pulled.
struct OllamaInstalledModel: Identifiable, Equatable {
    /// The tag Ollama knows it by, e.g. "qwen2.5vl:7b".
    let name: String
    /// True when the model accepts images, so it can see screenshots and point.
    let supportsVision: Bool
    /// True for reasoning models. Their thinking is switched off for voice
    /// answers, because it adds seconds of silence before the reply starts.
    let supportsThinking: Bool

    var id: String { name }
}

/// A non-2xx response (or an in-stream error line) from Ollama. Ollama
/// reports errors as `{"error": "..."}`, e.g. a 404 for a model that hasn't
/// been pulled.
struct OllamaResponseError: LocalizedError {
    let httpStatusCode: Int
    let errorMessage: String

    var errorDescription: String? {
        "Ollama HTTP \(httpStatusCode): \(errorMessage)"
    }
}

/// Ollama is the selected backend but there's no usable model to send the
/// question to, e.g. none are installed yet.
struct OllamaModelSelectionError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum OllamaConfiguration {
    /// The Ollama server's base URL, from the CLICKY_OLLAMA_BASE_URL build
    /// setting (via the ClickyOllamaBaseURL Info.plist key). Falls back to
    /// Ollama's default address so a missing setting still works.
    static let baseURL: String = {
        let configuredBaseURL = AppBundleConfiguration.stringValue(forKey: "ClickyOllamaBaseURL")
            ?? "http://localhost:11434"
        return configuredBaseURL.hasSuffix("/")
            ? String(configuredBaseURL.dropLast())
            : configuredBaseURL
    }()
}

final class OllamaAPI {
    /// Context window requested for every call. Ollama's default is small
    /// enough that the system prompt plus a couple of screenshots overflow
    /// it and get silently truncated. The model warm-up must ask for the
    /// same size, otherwise Ollama reloads the model on the first question.
    static let contextWindowTokenCount = 8192

    /// How long Ollama keeps the model in memory after the last request, so
    /// follow-up questions don't pay the multi-second load again.
    static let keepModelLoadedDuration = "30m"

    /// Matches the 1024 max_tokens the Worker allows for Claude.
    private static let maximumResponseTokenCount = 1024

    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = OllamaConfiguration.baseURL) {
        self.baseURL = baseURL

        // Unlike the cloud clients this does NOT wait for connectivity: the
        // server is on localhost, so a refused connection means Ollama isn't
        // running and the user should hear that straight away. The long
        // request timeout covers a cold model load plus image processing.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Models

    /// Lists the pulled models with their capabilities. Older Ollama versions
    /// don't include capabilities in /api/tags, so those models are asked
    /// about one by one via /api/show.
    func fetchInstalledModels() async throws -> [OllamaInstalledModel] {
        let responseJSON = try await sendJSONRequest(path: "/api/tags", method: "GET", requestBody: nil)
        let modelEntries = responseJSON["models"] as? [[String: Any]] ?? []

        var installedModels: [OllamaInstalledModel] = []
        for modelEntry in modelEntries {
            guard let modelName = modelEntry["name"] as? String else { continue }

            var modelCapabilities = modelEntry["capabilities"] as? [String]
            if modelCapabilities == nil {
                modelCapabilities = try? await fetchModelCapabilities(modelName: modelName)
            }

            installedModels.append(OllamaInstalledModel(
                name: modelName,
                supportsVision: modelCapabilities?.contains("vision") ?? false,
                supportsThinking: modelCapabilities?.contains("thinking") ?? false
            ))
        }
        return installedModels.sorted { $0.name < $1.name }
    }

    private func fetchModelCapabilities(modelName: String) async throws -> [String] {
        let responseJSON = try await sendJSONRequest(
            path: "/api/show",
            method: "POST",
            requestBody: ["model": modelName]
        )
        return responseJSON["capabilities"] as? [String] ?? []
    }

    /// Returns the server's version string. Used by the Status section's
    /// Test button as a free reachability check.
    func fetchServerVersion() async throws -> String {
        let responseJSON = try await sendJSONRequest(path: "/api/version", method: "GET", requestBody: nil)
        return responseJSON["version"] as? String ?? "unknown"
    }

    /// Loads a model into memory without generating anything (a generate
    /// request with no prompt), so the first push-to-talk after picking a
    /// model doesn't wait for the load.
    func loadModelIntoMemory(modelName: String) async throws {
        _ = try await sendJSONRequest(
            path: "/api/generate",
            method: "POST",
            requestBody: [
                "model": modelName,
                "keep_alive": Self.keepModelLoadedDuration,
                "options": ["num_ctx": Self.contextWindowTokenCount]
            ]
        )
    }

    // MARK: - Chat

    /// Sends a chat request and streams the reply. Ollama streams one JSON
    /// object per line, each carrying the next piece of `message.content`,
    /// until a line with `"done": true`. Returns the full response text.
    func streamChat(
        modelName: String,
        shouldDisableThinking: Bool,
        messages: [[String: Any]],
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var requestBody: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": messages,
            "keep_alive": Self.keepModelLoadedDuration,
            "options": [
                "num_ctx": Self.contextWindowTokenCount,
                "num_predict": Self.maximumResponseTokenCount
            ]
        ]
        // Only sent to models that think: Ollama rejects the field for
        // models without the capability.
        if shouldDisableThinking {
            requestBody["think"] = false
        }

        var request = try makeRequest(path: "/api/chat", method: "POST", requestBody: requestBody)
        request.timeoutInterval = 180

        let (byteStream, response) = try await session.bytes(for: request)
        let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard (200...299).contains(httpStatusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            throw OllamaResponseError(
                httpStatusCode: httpStatusCode,
                errorMessage: Self.extractErrorMessage(fromResponseBody: errorBodyLines.joined(separator: "\n"))
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard let lineData = line.data(using: .utf8),
                  let streamedObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Errors after the stream has started (for example running out
            // of memory mid-answer) arrive as a line with an error field.
            if let streamedErrorMessage = streamedObject["error"] as? String {
                throw OllamaResponseError(httpStatusCode: httpStatusCode, errorMessage: streamedErrorMessage)
            }

            if let messageObject = streamedObject["message"] as? [String: Any],
               let textChunk = messageObject["content"] as? String,
               !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }

            if streamedObject["done"] as? Bool == true {
                break
            }
        }

        return accumulatedResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Request Helpers

    private func makeRequest(path: String, method: String, requestBody: [String: Any]?) throws -> URLRequest {
        guard let requestURL = URL(string: baseURL + path) else {
            throw OllamaResponseError(httpStatusCode: -1, errorMessage: "Invalid Ollama URL: \(baseURL)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        if let requestBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        }
        return request
    }

    private func sendJSONRequest(path: String, method: String, requestBody: [String: Any]?) async throws -> [String: Any] {
        let request = try makeRequest(path: path, method: method, requestBody: requestBody)
        let (responseData, response) = try await session.data(for: request)
        let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseBody = String(data: responseData, encoding: .utf8) ?? ""

        guard (200...299).contains(httpStatusCode) else {
            throw OllamaResponseError(
                httpStatusCode: httpStatusCode,
                errorMessage: Self.extractErrorMessage(fromResponseBody: responseBody)
            )
        }
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }

    private static func extractErrorMessage(fromResponseBody responseBody: String) -> String {
        if let responseData = responseBody.data(using: .utf8),
           let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let errorMessage = responseJSON["error"] as? String {
            return errorMessage
        }
        let trimmedResponseBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResponseBody.isEmpty ? "No details" : String(trimmedResponseBody.prefix(200))
    }
}
