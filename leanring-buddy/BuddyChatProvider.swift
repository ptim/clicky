//
//  BuddyChatProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for chat response backends — the same pattern
//  BuddyTranscriptionProvider uses for voice transcription. Claude (through
//  the Cloudflare Worker) and Ollama (running locally) both implement it, so
//  the push-to-talk pipeline doesn't care which one answers.
//

import Foundation

@MainActor
protocol BuddyChatProvider: AnyObject {
    /// Short name for logs and spoken errors ("Claude", "Ollama").
    var displayName: String { get }

    /// Whether the model can look at screenshots. When false the pipeline
    /// skips the screen capture entirely and uses the text-only prompt,
    /// because sending images to a text-only model either errors or is
    /// silently ignored.
    var supportsScreenshotImages: Bool { get }

    /// The Status section row that a failure of this provider should turn red.
    var monitoredServiceComponent: MonitoredServiceComponent { get }

    /// Sends one chat turn and streams the response back. Returns the full
    /// response text once the stream finishes. `onTextChunk` receives the
    /// accumulated text so far, matching ClaudeAPI's existing callback.
    func generateStreamingResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String
}

/// Claude via the Worker proxy. A thin wrapper so ClaudeAPI itself stays
/// untouched and the Sonnet/Opus request path behaves exactly as before.
@MainActor
final class ClaudeChatProvider: BuddyChatProvider {
    let displayName = "Claude"
    let supportsScreenshotImages = true
    let monitoredServiceComponent = MonitoredServiceComponent.claudeChat

    private let claudeAPI: ClaudeAPI

    init(claudeAPI: ClaudeAPI) {
        self.claudeAPI = claudeAPI
    }

    func generateStreamingResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        // ClaudeAPI's history tuple labels predate the provider protocol, so
        // map ours onto them rather than changing the working client.
        let historyForClaudeAPI = conversationHistory.map { exchange in
            (userPlaceholder: exchange.userTranscript, assistantResponse: exchange.assistantResponse)
        }

        let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: historyForClaudeAPI,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return fullResponseText
    }
}
