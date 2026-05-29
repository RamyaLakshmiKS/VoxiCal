import Foundation
import FoundationModels

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()
}

// MARK: - CalendarViewModel

/// Central orchestrator for VoxiCal.
///
/// Owns every service and the single LanguageModelSession.
/// The UI observes this class for all state it needs to render.
@MainActor
@Observable
class CalendarViewModel {

    // MARK: - Services (shared with tools)

    let calendarService = CalendarService()
    let cacheService    = ResponseCacheService()
    let speechService   = SpeechService()
    let ttsService      = TTSService()

    // MARK: - LLM Session

    private var session: LanguageModelSession?

    // MARK: - UI State

    var messages: [ChatMessage]  = []
    var isProcessing             = false
    var isModelAvailable         = false
    var errorMessage: String?    = nil
    var showSettingsAlert        = false

    // MARK: - Setup

    /// Called once from VoxiCalApp on first launch via `.task { }`.
    func setup() async {
        checkModelAvailability()

        guard isModelAvailable else { return }

        // Request calendar access; surface errors as non-fatal banners
        do {
            try await calendarService.requestAccess()
        } catch CalendarError.accessDenied {
            errorMessage = "Calendar access denied. Tap here to open Settings."
            showSettingsAlert = true
        } catch {
            errorMessage = error.localizedDescription
        }

        buildSession()
        appendWelcome()
    }

    // MARK: - Model Availability

    private func checkModelAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            isModelAvailable = true
        case .unavailable:
            isModelAvailable = false
            errorMessage = "Apple Intelligence is not available on this device. You need an iPhone with an A17 Pro or M-series chip running iOS 26.4 with Apple Intelligence enabled."
        @unknown default:
            isModelAvailable = false
            errorMessage = "Apple Intelligence availability is unknown."
        }
    }

    // MARK: - Session Construction

    private func buildSession() {
        let tools: [any Tool] = [
            FetchCalendarEventsTool(calendarService: calendarService, cacheService: cacheService),
            DeleteCalendarEventTool(calendarService: calendarService),
            SearchCacheTool(cacheService: cacheService)
        ]

        // Instructions are a static developer string — never interpolate user input here.
        // The model reads these once when the session is created.
        session = LanguageModelSession(
            tools: tools,
            instructions: """
                You are VoxiCal, a calm and concise iOS calendar assistant. \
                You help users understand and manage their schedule using only the tools provided.

                Tool usage order:
                1. Always call searchPastResponses first to check for a recent cached answer.
                2. Only call fetchCalendarEvents if the cache has no useful or fresh result.
                3. To delete an event: ALWAYS call fetchCalendarEvents first — never rely on a \
                   cached eventID — to get the current event list. Identify the event, name it in \
                   your reply for the user to confirm, then call deleteCalendarEvent with the exact \
                   eventID from that fresh fetch result.

                daysAhead values for fetchCalendarEvents (today is day 0, inclusive):
                - 1 = today only
                - 2 = today AND tomorrow (use this when the user asks about tomorrow)
                - 7 = this week
                - 30 = this month
                Never use daysAhead:1 when the user asks about tomorrow — that range ends at \
                midnight tonight and will return zero results for tomorrow's events.

                Event IDs: When fetchCalendarEvents returns events, each line ends with \
                [eventID:XXX]. Use this exact string when calling deleteCalendarEvent. \
                Never guess or construct an eventID. Never include eventID values in your \
                replies to the user.

                Response style:
                - Format dates conversationally: "Today at 2 pm", "This Monday at 9 am", "June 3rd".
                - Keep replies to two sentences maximum unless listing multiple events.
                - When listing events, use a short bullet format: "• Title — Day at Time".
                - Never invent or guess events. Only report what the tools return.
                - If the calendar has no events in a time range, say so plainly and briefly.
                """
        )
    }

    // MARK: - Send Text Message

    /// Primary entry point for both typed text and transcribed voice.
    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }

        // Auto-reset conversation after 16 messages (8 turns) to prevent context window overflow
        if messages.count >= 16 {
            clearConversation()
        }

        guard let session else {
            errorMessage = "Session not ready — please wait a moment and try again."
            return
        }

        // Stop any in-progress TTS immediately so voices don't overlap
        ttsService.stop()

        messages.append(ChatMessage(role: .user, text: trimmed))
        isProcessing  = true
        errorMessage  = nil

        do {
            // Foundation Models orchestrates all tool calls autonomously.
            // respond(to:) does not return until the model has finished reasoning
            // and executing every tool call it decided to make.
            let response = try await session.respond(to: trimmed)
            let responseText = response.content

            messages.append(ChatMessage(role: .assistant, text: responseText))

            // Persist to cache so SearchCacheTool can serve repeat queries
            // without going back to EventKit or growing the live transcript.
            await cacheService.store(query: trimmed, response: responseText)

            // Speak the response — audio session handoff handled inside TTSService
            ttsService.speak(responseText)

        } catch {
            let friendly = friendlyError(from: error)
            messages.append(ChatMessage(role: .assistant, text: friendly))
        }

        isProcessing = false
    }

    // MARK: - Send Voice Message

    /// Called by the Send button when recordingState is .recording or .paused.
    /// Stops the recording, retrieves the transcript, then routes through sendMessage.
    func sendVoiceInput() async {
        let transcript = speechService.stopAndSend()
        guard !transcript.isEmpty else { return }
        await sendMessage(transcript)
    }

    // MARK: - Conversation Reset

    /// Wipes the chat history and creates a new LanguageModelSession.
    /// Necessary when the session transcript grows close to the 4,096-token limit.
    func clearConversation() {
        ttsService.stop()
        session = nil
        messages.removeAll()
        buildSession()
        appendWelcome()
    }

    // MARK: - Private Helpers

    private func appendWelcome() {
        messages.append(ChatMessage(
            role: .assistant,
            text: "Hi! I'm VoxiCal. Try asking: \"What's on my schedule today?\" or \"Do I have anything this week?\""
        ))
    }

    private func friendlyError(from error: Error) -> String {
        // Surface context-window overflow with a specific recovery hint
        let description = error.localizedDescription.lowercased()
        if description.contains("context") || description.contains("token") {
            return "The conversation is getting long — I've reached my memory limit. Tap \"New Chat\" to start fresh."
        }
        return "Something went wrong: \(error.localizedDescription). Please try again."
    }
}
