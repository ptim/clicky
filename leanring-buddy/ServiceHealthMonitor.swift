//
//  ServiceHealthMonitor.swift
//  leanring-buddy
//
//  Tracks whether each part of the voice pipeline (worker proxy, Claude,
//  ElevenLabs, speech-to-text, screen capture, permissions) is working, so
//  the panel's Status section can say exactly what failed instead of the
//  app speaking one generic error for everything.
//
//  Health is updated two ways: passively, when a real push-to-talk
//  interaction succeeds or fails, and actively, when the user presses a
//  Test button in the panel.
//

import Combine
import Foundation
import ScreenCaptureKit

/// The pieces of the pipeline that can fail independently.
enum MonitoredServiceComponent: String, CaseIterable, Identifiable {
    case workerProxy
    case claudeChat
    case ollamaChat
    case elevenLabsSpeech
    case speechToText
    case screenCapture
    case permissions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .workerProxy: return "Worker proxy"
        case .claudeChat: return "Claude"
        case .ollamaChat: return "Ollama"
        case .elevenLabsSpeech: return "ElevenLabs voice"
        case .speechToText: return "Speech to text"
        case .screenCapture: return "Screen capture"
        case .permissions: return "Permissions"
        }
    }

    var iconSystemName: String {
        switch self {
        case .workerProxy: return "server.rack"
        case .claudeChat: return "sparkles"
        case .ollamaChat: return "desktopcomputer"
        case .elevenLabsSpeech: return "speaker.wave.2"
        case .speechToText: return "waveform"
        case .screenCapture: return "rectangle.dashed.badge.record"
        case .permissions: return "lock.shield"
        }
    }
}

enum ServiceComponentHealthStatus {
    /// Nothing has exercised this component yet.
    case unknown
    /// A Test button check is in flight.
    case checking
    case healthy
    case failing
}

struct ServiceComponentHealth {
    var status: ServiceComponentHealthStatus = .unknown
    /// One short line shown next to the component, e.g. "Out of credits".
    var summaryMessage: String = "Not checked yet"
    /// The raw error (HTTP status + response body, or the system error), so
    /// the user can copy it into a bug report or a search.
    var detailedErrorText: String?
    var lastCheckedDate: Date?
}

/// A non-2xx response (or an in-stream error event) from the Worker proxy.
/// Keeps the status code and body separate so the failure can be diagnosed
/// from the provider's own error code rather than guessed from the status:
/// ElevenLabs, for example, reports an exhausted key quota as a 401.
struct WorkerProxyResponseError: LocalizedError {
    let httpStatusCode: Int
    let responseBody: String

    var errorDescription: String? {
        "HTTP \(httpStatusCode): \(responseBody)"
    }
}

/// What went wrong, phrased for the panel and for speaking aloud.
struct ServiceFailureDiagnosis {
    let summaryMessage: String
    let spokenMessage: String
    /// True when the worker itself could not be reached or rejected the
    /// request, so the Worker proxy row should turn red too.
    let isWorkerProxyProblem: Bool
}

@MainActor
final class ServiceHealthMonitor: ObservableObject {
    @Published private(set) var healthByComponent: [MonitoredServiceComponent: ServiceComponentHealth] =
        Dictionary(uniqueKeysWithValues: MonitoredServiceComponent.allCases.map { ($0, ServiceComponentHealth()) })

    /// Short timeouts so a dead worker shows up as red in seconds, not minutes.
    private let healthCheckSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func health(for component: MonitoredServiceComponent) -> ServiceComponentHealth {
        healthByComponent[component] ?? ServiceComponentHealth()
    }

    var hasAnyFailingComponent: Bool {
        healthByComponent.values.contains { $0.status == .failing }
    }

    var hasAnyHealthyComponent: Bool {
        healthByComponent.values.contains { $0.status == .healthy }
    }

    var isAnyComponentChecking: Bool {
        healthByComponent.values.contains { $0.status == .checking }
    }

    // MARK: - Recording Results

    func recordSuccess(for component: MonitoredServiceComponent, summaryMessage: String = "Working") {
        healthByComponent[component] = ServiceComponentHealth(
            status: .healthy,
            summaryMessage: summaryMessage,
            detailedErrorText: nil,
            lastCheckedDate: Date()
        )
        // Any successful round trip through the worker proves it is
        // reachable and accepted the shared secret.
        if component == .claudeChat || component == .elevenLabsSpeech {
            recordSuccess(for: .workerProxy)
        }
    }

    /// Records a failure and returns the diagnosis so the caller can speak it.
    @discardableResult
    func recordFailure(for component: MonitoredServiceComponent, error: Error) -> ServiceFailureDiagnosis {
        let diagnosis = Self.diagnoseFailure(of: component, error: error)
        recordFailure(
            for: component,
            summaryMessage: diagnosis.summaryMessage,
            detailedErrorText: String(describing: error)
        )
        if diagnosis.isWorkerProxyProblem && component != .workerProxy {
            recordFailure(
                for: .workerProxy,
                summaryMessage: diagnosis.summaryMessage,
                detailedErrorText: String(describing: error)
            )
        }
        return diagnosis
    }

    func recordFailure(for component: MonitoredServiceComponent, summaryMessage: String, detailedErrorText: String?) {
        healthByComponent[component] = ServiceComponentHealth(
            status: .failing,
            summaryMessage: summaryMessage,
            detailedErrorText: detailedErrorText,
            lastCheckedDate: Date()
        )
    }

    /// Called on every permission poll, so it only writes when something
    /// changed to avoid republishing the panel every 1.5 seconds.
    func recordPermissionState(missingPermissionNames: [String]) {
        let currentPermissionsHealth = health(for: .permissions)
        if missingPermissionNames.isEmpty {
            guard currentPermissionsHealth.status != .healthy else { return }
            recordSuccess(for: .permissions, summaryMessage: "All granted")
        } else {
            let missingPermissionsSummary = "Missing: " + missingPermissionNames.joined(separator: ", ")
            guard currentPermissionsHealth.status != .failing
                    || currentPermissionsHealth.summaryMessage != missingPermissionsSummary else { return }
            recordFailure(for: .permissions, summaryMessage: missingPermissionsSummary, detailedErrorText: nil)
        }
    }

    private func markChecking(_ component: MonitoredServiceComponent) {
        var componentHealth = health(for: component)
        componentHealth.status = .checking
        componentHealth.summaryMessage = "Checking…"
        healthByComponent[component] = componentHealth
    }

    // MARK: - Tests

    /// Actively checks one component. Permissions are not tested here — the
    /// CompanionManager owns those checks and reports them via
    /// `recordPermissionState`.
    func runTest(
        for component: MonitoredServiceComponent,
        claudeModelIdentifier: String,
        ollamaModelName: String?,
        transcriptionProviderDisplayName: String
    ) async {
        guard component != .permissions else { return }
        markChecking(component)

        switch component {
        case .workerProxy:
            await testWorkerProxy()
        case .claudeChat:
            await testClaudeChat(claudeModelIdentifier: claudeModelIdentifier)
        case .ollamaChat:
            await testOllamaChat(ollamaModelName: ollamaModelName)
        case .elevenLabsSpeech:
            await testElevenLabsSpeech()
        case .speechToText:
            await testSpeechToText(transcriptionProviderDisplayName: transcriptionProviderDisplayName)
        case .screenCapture:
            await testScreenCapture()
        case .permissions:
            break
        }
    }

    /// The worker checks the shared secret before routing, so a POST to a
    /// path it doesn't serve answers 404 when the secret is right and 401
    /// when it's wrong — without touching any paid upstream API.
    private func testWorkerProxy() async {
        guard let statusCheckURL = URL(string: "\(WorkerProxyConfiguration.workerBaseURL)/status-check") else {
            recordFailure(
                for: .workerProxy,
                summaryMessage: "Invalid worker URL",
                detailedErrorText: WorkerProxyConfiguration.workerBaseURL
            )
            return
        }

        var statusCheckRequest = URLRequest(url: statusCheckURL)
        statusCheckRequest.httpMethod = "POST"
        WorkerProxyAuthentication.addSharedSecretHeader(to: &statusCheckRequest)

        do {
            let (responseData, response) = try await healthCheckSession.data(for: statusCheckRequest)
            let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if httpStatusCode == 404 {
                recordSuccess(for: .workerProxy, summaryMessage: "Reachable, secret accepted")
            } else {
                let responseBody = String(data: responseData, encoding: .utf8) ?? ""
                recordFailure(
                    for: .workerProxy,
                    error: WorkerProxyResponseError(httpStatusCode: httpStatusCode, responseBody: responseBody)
                )
            }
        } catch {
            recordFailure(for: .workerProxy, error: error)
        }
    }

    /// A one-token, text-only request so the test costs a fraction of a cent.
    private func testClaudeChat(claudeModelIdentifier: String) async {
        guard let chatURL = URL(string: WorkerProxyConfiguration.chatURL) else { return }

        var chatRequest = URLRequest(url: chatURL)
        chatRequest.httpMethod = "POST"
        chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        WorkerProxyAuthentication.addSharedSecretHeader(to: &chatRequest)

        let requestBody: [String: Any] = [
            "model": claudeModelIdentifier,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ok"]]
        ]

        do {
            chatRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (responseData, response) = try await healthCheckSession.data(for: chatRequest)
            let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(httpStatusCode) {
                recordSuccess(for: .claudeChat)
            } else {
                let responseBody = String(data: responseData, encoding: .utf8) ?? ""
                recordFailure(
                    for: .claudeChat,
                    error: WorkerProxyResponseError(httpStatusCode: httpStatusCode, responseBody: responseBody)
                )
            }
        } catch {
            recordFailure(for: .claudeChat, error: error)
        }
    }

    /// Free and local: checks the Ollama server answers, then that the model
    /// picked in the panel is actually pulled. Doesn't generate anything,
    /// because a cold model load can take longer than the test should.
    private func testOllamaChat(ollamaModelName: String?) async {
        let ollamaAPI = OllamaAPI()
        do {
            let serverVersion = try await ollamaAPI.fetchServerVersion()
            guard let ollamaModelName else {
                recordFailure(
                    for: .ollamaChat,
                    summaryMessage: "Running (v\(serverVersion)), but no model picked",
                    detailedErrorText: nil
                )
                return
            }

            let installedModels = try await ollamaAPI.fetchInstalledModels()
            if installedModels.contains(where: { $0.name == ollamaModelName }) {
                recordSuccess(for: .ollamaChat, summaryMessage: "Running, \(ollamaModelName) installed")
            } else {
                recordFailure(
                    for: .ollamaChat,
                    summaryMessage: "\(ollamaModelName) isn't installed. Run: ollama pull \(ollamaModelName)",
                    detailedErrorText: "Installed: " + installedModels.map(\.name).joined(separator: ", ")
                )
            }
        } catch {
            recordFailure(for: .ollamaChat, error: error)
        }
    }

    /// Synthesizes a single word without playing it. Costs about two
    /// ElevenLabs credits, so a key that is nearly exhausted can still be
    /// caught by the quota message in the error body.
    private func testElevenLabsSpeech() async {
        guard let textToSpeechURL = URL(string: WorkerProxyConfiguration.textToSpeechURL) else { return }

        var textToSpeechRequest = URLRequest(url: textToSpeechURL)
        textToSpeechRequest.httpMethod = "POST"
        textToSpeechRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        textToSpeechRequest.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        WorkerProxyAuthentication.addSharedSecretHeader(to: &textToSpeechRequest)

        let requestBody: [String: Any] = [
            "text": "ok",
            "model_id": ElevenLabsTTSClient.textToSpeechModelIdentifier
        ]

        do {
            textToSpeechRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (responseData, response) = try await healthCheckSession.data(for: textToSpeechRequest)
            let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(httpStatusCode) && !responseData.isEmpty {
                recordSuccess(for: .elevenLabsSpeech)
            } else {
                let responseBody = String(data: responseData, encoding: .utf8) ?? ""
                recordFailure(
                    for: .elevenLabsSpeech,
                    error: WorkerProxyResponseError(httpStatusCode: httpStatusCode, responseBody: responseBody)
                )
            }
        } catch {
            recordFailure(for: .elevenLabsSpeech, error: error)
        }
    }

    /// Only AssemblyAI goes through the worker; the other providers are
    /// local (Apple Speech) or have no cheap check, so they stay unknown
    /// until a real dictation succeeds or fails.
    private func testSpeechToText(transcriptionProviderDisplayName: String) async {
        guard transcriptionProviderDisplayName == "AssemblyAI" else {
            healthByComponent[.speechToText] = ServiceComponentHealth(
                status: .unknown,
                summaryMessage: "\(transcriptionProviderDisplayName): no test available",
                detailedErrorText: nil,
                lastCheckedDate: Date()
            )
            return
        }

        guard let transcribeTokenURL = URL(string: WorkerProxyConfiguration.transcribeTokenURL) else { return }

        var transcribeTokenRequest = URLRequest(url: transcribeTokenURL)
        transcribeTokenRequest.httpMethod = "POST"
        WorkerProxyAuthentication.addSharedSecretHeader(to: &transcribeTokenRequest)

        do {
            let (responseData, response) = try await healthCheckSession.data(for: transcribeTokenRequest)
            let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            let didReceiveToken = (responseJSON?["token"] as? String)?.isEmpty == false
            if (200...299).contains(httpStatusCode) && didReceiveToken {
                recordSuccess(for: .speechToText, summaryMessage: "AssemblyAI token issued")
                recordSuccess(for: .workerProxy)
            } else {
                let responseBody = String(data: responseData, encoding: .utf8) ?? ""
                recordFailure(
                    for: .speechToText,
                    error: WorkerProxyResponseError(httpStatusCode: httpStatusCode, responseBody: responseBody)
                )
            }
        } catch {
            recordFailure(for: .speechToText, error: error)
        }
    }

    /// Asking for shareable content fails the same way a real capture does
    /// when Screen Recording access is missing, without grabbing pixels.
    private func testScreenCapture() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if shareableContent.displays.isEmpty {
                recordFailure(for: .screenCapture, summaryMessage: "No displays found", detailedErrorText: nil)
            } else {
                recordSuccess(for: .screenCapture, summaryMessage: "\(shareableContent.displays.count) display(s) available")
            }
        } catch {
            recordFailure(for: .screenCapture, error: error)
        }
    }

    // MARK: - Diagnosis

    /// Turns a raw error into a short explanation. Checks the provider's own
    /// error code in the body before falling back to the HTTP status,
    /// because status codes alone are misleading (ElevenLabs returns 401 for
    /// an exhausted key quota, the same code the worker uses for a bad secret).
    static func diagnoseFailure(of component: MonitoredServiceComponent, error: Error) -> ServiceFailureDiagnosis {
        let componentName = component.displayName

        // Ollama is called directly, not through the worker, so its
        // connection failures mean "Ollama isn't running", not a worker problem.
        if component == .ollamaChat {
            return diagnoseOllamaFailure(error: error)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .dnsLookupFailed:
                let workerBaseURL = WorkerProxyConfiguration.workerBaseURL
                let isLocalWorker = workerBaseURL.contains("localhost") || workerBaseURL.contains("127.0.0.1")
                return ServiceFailureDiagnosis(
                    summaryMessage: isLocalWorker
                        ? "Can't reach \(workerBaseURL). Is wrangler dev running?"
                        : "Can't reach the worker at \(workerBaseURL)",
                    spokenMessage: "I can't reach my server. Check the status section in the menu bar.",
                    isWorkerProxyProblem: true
                )
            case .notConnectedToInternet:
                return ServiceFailureDiagnosis(
                    summaryMessage: "No internet connection",
                    spokenMessage: "I'm not connected to the internet.",
                    isWorkerProxyProblem: true
                )
            default:
                break
            }
        }

        if let workerProxyResponseError = error as? WorkerProxyResponseError {
            return diagnoseWorkerProxyResponse(workerProxyResponseError, componentName: componentName)
        }

        let nsError = error as NSError
        if component == .screenCapture || nsError.domain == SCStreamErrorDomain || nsError.domain == "CompanionScreenCapture" {
            return ServiceFailureDiagnosis(
                summaryMessage: "Screen capture failed. Check Screen Recording permission",
                spokenMessage: "I couldn't take a screenshot. Check screen recording permission in the menu bar.",
                isWorkerProxyProblem: false
            )
        }

        return ServiceFailureDiagnosis(
            summaryMessage: error.localizedDescription,
            spokenMessage: "Something went wrong with \(componentName). Check the status section in the menu bar.",
            isWorkerProxyProblem: false
        )
    }

    private static func diagnoseOllamaFailure(error: Error) -> ServiceFailureDiagnosis {
        if let ollamaModelSelectionError = error as? OllamaModelSelectionError {
            return ServiceFailureDiagnosis(
                summaryMessage: ollamaModelSelectionError.message,
                spokenMessage: "Pick an Ollama model in the menu bar first.",
                isWorkerProxyProblem: false
            )
        }

        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return ServiceFailureDiagnosis(
                    summaryMessage: "Ollama timed out. The model may be too large for this Mac or still loading",
                    spokenMessage: "Ollama took too long to answer. Try again, or pick a smaller model.",
                    isWorkerProxyProblem: false
                )
            }
            if urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost
                || urlError.code == .networkConnectionLost {
                return ServiceFailureDiagnosis(
                    summaryMessage: "Can't reach Ollama at \(OllamaConfiguration.baseURL). Is it running?",
                    spokenMessage: "I can't reach Ollama. Make sure it's running.",
                    isWorkerProxyProblem: false
                )
            }
        }

        if let ollamaResponseError = error as? OllamaResponseError {
            if ollamaResponseError.httpStatusCode == 404 {
                return ServiceFailureDiagnosis(
                    summaryMessage: "Model not installed: \(ollamaResponseError.errorMessage)",
                    spokenMessage: "That Ollama model isn't installed. Pick another one in the menu bar.",
                    isWorkerProxyProblem: false
                )
            }
            return ServiceFailureDiagnosis(
                summaryMessage: "Ollama error: \(ollamaResponseError.errorMessage)",
                spokenMessage: "Ollama returned an error. Check the status section in the menu bar.",
                isWorkerProxyProblem: false
            )
        }

        return ServiceFailureDiagnosis(
            summaryMessage: error.localizedDescription,
            spokenMessage: "Something went wrong with Ollama. Check the status section in the menu bar.",
            isWorkerProxyProblem: false
        )
    }

    private static func diagnoseWorkerProxyResponse(
        _ workerProxyResponseError: WorkerProxyResponseError,
        componentName: String
    ) -> ServiceFailureDiagnosis {
        let httpStatusCode = workerProxyResponseError.httpStatusCode
        let responseBody = workerProxyResponseError.responseBody
        let lowercasedResponseBody = responseBody.lowercased()
        let providerErrorMessage = extractProviderErrorMessage(fromResponseBody: responseBody)

        // The worker's own rejections are plain text, unlike the providers' JSON.
        let trimmedResponseBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if httpStatusCode == 401 && trimmedResponseBody == "Unauthorized" {
            return ServiceFailureDiagnosis(
                summaryMessage: "Worker rejected the shared secret",
                spokenMessage: "My server rejected my password. Check the status section in the menu bar.",
                isWorkerProxyProblem: true
            )
        }
        if trimmedResponseBody == "Proxy is not configured" {
            return ServiceFailureDiagnosis(
                summaryMessage: "Worker has no CLICKY_PROXY_SHARED_SECRET set",
                spokenMessage: "My server isn't configured yet. Check the status section in the menu bar.",
                isWorkerProxyProblem: true
            )
        }

        let isOutOfCredits = httpStatusCode == 402
            || lowercasedResponseBody.contains("quota_exceeded")
            || lowercasedResponseBody.contains("credit balance")
            || lowercasedResponseBody.contains("insufficient")
        if isOutOfCredits {
            return ServiceFailureDiagnosis(
                summaryMessage: "Out of credits: \(providerErrorMessage)",
                spokenMessage: "\(componentName) is out of credits. Check the status section in the menu bar.",
                isWorkerProxyProblem: false
            )
        }

        if httpStatusCode == 529 || lowercasedResponseBody.contains("overloaded") {
            return ServiceFailureDiagnosis(
                summaryMessage: "Overloaded, try again shortly",
                spokenMessage: "\(componentName) is overloaded right now. Try again in a moment.",
                isWorkerProxyProblem: false
            )
        }

        if httpStatusCode == 429 {
            return ServiceFailureDiagnosis(
                summaryMessage: "Rate limited: \(providerErrorMessage)",
                spokenMessage: "\(componentName) is rate limiting me. Try again in a moment.",
                isWorkerProxyProblem: false
            )
        }

        if httpStatusCode == 401 || httpStatusCode == 403 {
            return ServiceFailureDiagnosis(
                summaryMessage: "API key rejected: \(providerErrorMessage)",
                spokenMessage: "\(componentName) rejected its API key. Check the status section in the menu bar.",
                isWorkerProxyProblem: false
            )
        }

        return ServiceFailureDiagnosis(
            summaryMessage: "HTTP \(httpStatusCode): \(providerErrorMessage)",
            spokenMessage: "\(componentName) returned an error. Check the status section in the menu bar.",
            isWorkerProxyProblem: false
        )
    }

    /// Pulls the human-readable message out of a provider's JSON error body.
    /// ElevenLabs uses `detail.message`, Anthropic uses `error.message`; the
    /// worker's own errors use a top-level `error` string.
    private static func extractProviderErrorMessage(fromResponseBody responseBody: String) -> String {
        if let responseData = responseBody.data(using: .utf8),
           let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let detailObject = responseJSON["detail"] as? [String: Any],
               let detailMessage = detailObject["message"] as? String {
                return detailMessage
            }
            if let detailMessage = responseJSON["detail"] as? String {
                return detailMessage
            }
            if let errorObject = responseJSON["error"] as? [String: Any],
               let errorMessage = errorObject["message"] as? String {
                return errorMessage
            }
            if let errorMessage = responseJSON["error"] as? String {
                return errorMessage
            }
            if let topLevelMessage = responseJSON["message"] as? String {
                return topLevelMessage
            }
        }

        let trimmedResponseBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedResponseBody.isEmpty {
            return "No details"
        }
        return String(trimmedResponseBody.prefix(200))
    }
}
