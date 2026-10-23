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

    /// Backend and model, e.g. "Ollama · gemma4:latest", for the History section.
    var chatModelDescription: String { get }

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

    var chatModelDescription: String { "Claude · \(claudeAPI.model)" }

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

/// A model served by the local Ollama server. Vision models get the
/// screenshots and can point; text-only models answer from the transcript.
@MainActor
final class OllamaChatProvider: BuddyChatProvider {
    let displayName = "Ollama"
    let monitoredServiceComponent = MonitoredServiceComponent.ollamaChat

    let installedModel: OllamaInstalledModel
    private let ollamaAPI: OllamaAPI

    var supportsScreenshotImages: Bool { installedModel.supportsVision }

    var chatModelDescription: String { "Ollama · \(installedModel.name)" }

    init(installedModel: OllamaInstalledModel, ollamaAPI: OllamaAPI) {
        self.installedModel = installedModel
        self.ollamaAPI = ollamaAPI
    }

    func generateStreamingResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var chatMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for exchange in conversationHistory {
            chatMessages.append(["role": "user", "content": exchange.userTranscript])
            chatMessages.append(["role": "assistant", "content": exchange.assistantResponse])
        }

        // Ollama attaches images to a message as a bare list, unlike Claude's
        // interleaved image and text blocks. The labels (which carry the
        // pixel dimensions the [POINT] coordinates are measured in) go into
        // the text in the same order, so each one reads as "image N".
        var currentUserMessage: [String: Any] = ["role": "user"]
        if images.isEmpty {
            currentUserMessage["content"] = userPrompt
        } else {
            let numberedImageLabels = images.enumerated().map { imageIndex, image in
                "image \(imageIndex + 1): \(image.label)"
            }
            currentUserMessage["content"] = numberedImageLabels.joined(separator: "\n") + "\n\n" + userPrompt
            currentUserMessage["images"] = images.map { image in image.data.base64EncodedString() }
        }
        chatMessages.append(currentUserMessage)

        return try await ollamaAPI.streamChat(
            modelName: installedModel.name,
            shouldDisableThinking: installedModel.supportsThinking,
            messages: chatMessages,
            onTextChunk: onTextChunk
        )
    }
}
