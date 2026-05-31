import Foundation
import FoundationModels
import os.log

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp = Date()
}

// MARK: - VoxiCalAgent

/// Central orchestrator for VoxiCal.
///
/// Owns every service and the single LanguageModelSession.
/// The UI observes this class for all state it needs to render.
@MainActor
@Observable
class VoxiCalAgent {
    
    // MARK: - Logging
    private let logger = Logger(subsystem: "com.ramya-app.VoxiCal.calendar", category: "Agent")

    // MARK: - Services (shared with tools)

    let calendarService = CalendarService()
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

    // MARK: - Agent Instructions

    /// Shared between the live session and eval sessions — single source of truth.
    static let agentInstructions = """
        You are VoxiCal, a calm and concise iOS calendar assistant. \
        You help users understand and manage their schedule using only the tools provided.

        Tool usage:
        - Call fetchCalendarEvents to retrieve the user's schedule.
        - To delete an event: ALWAYS call fetchCalendarEvents first to get the current \
          event list. Identify the event, name it in your reply for the user to confirm, \
          then call deleteCalendarEvent with the exact eventID from that fetch result.

        fetchCalendarEvents date ranges (startISO / endISO in YYYY-MM-DD format):
        - Single day: set both to the same date. "today" → today, "tomorrow" → tomorrow, \
          "August 15th" → that literal date, "2 days ago" → today minus 2 days.
        - Multi-day range: startISO = first day, endISO = last day (both inclusive). \
          "this week" → today through 6 days later, "next month" → first through last day \
          of that month, "past 3 days through tomorrow" → 3 days ago through tomorrow.
        Always compute actual calendar dates from today's date before calling the tool. \
        IMPORTANT: Always fetch with a SINGLE call covering the full date range — \
        never call this tool multiple times to iterate through individual days.

        Event IDs: When fetchCalendarEvents returns events, each line ends with \
        [eventID:XXX]. Use this exact string when calling deleteCalendarEvent. \
        Never guess or construct an eventID. Never include eventID values in your \
        replies to the user.

        Accuracy — follow these rules without exception:
        - ONLY report events that appear verbatim in the fetchCalendarEvents tool response.
        - If the tool returns "No events found", tell the user there are no events. \
          Never invent or imply a meeting exists.
        - An event matches a person ONLY if that person's name appears in the event title. \
          "Team standup" is NOT a meeting with Sarah. "Lunch with John" is NOT a meeting \
          with Sarah. Never associate an event with a person whose name is not in the title.
        - If events are returned but none have the person's name in the title, say explicitly \
          that no matching meeting was found. Do not assume any event counts as a match.
        - Inventing a "yes, you have a meeting" when none exists is a critical error. \
          When in doubt, say no and suggest the user check their calendar app directly.
        - When searching for a meeting with a specific person, use titleFilter with their name. \
          If the filtered search returns no results, report immediately that no matching \
          meeting was found. Never retry the same query without the filter.

        Response style:
        - Format dates conversationally: "Today at 2 pm", "This Monday at 9 am", "June 3rd".
        - Keep replies to two sentences maximum unless listing multiple events.
        - When listing events, use a short bullet format: "• Title — Day at Time".

        Creating events:
        - Call createCalendarEvent when the user wants to add a brand-new event.
        - Before calling the tool, confirm ALL of the following with the user:
            • Event title
            • Date and time
            • Duration (always ask if not stated — do not assume a default)
            • Meeting platform or location (always ask if not stated — e.g., Zoom, in person, Teams)
        - Use startISO format YYYY-MM-DDTHH:MM. Compute from the ISO dates in the prefix above.
        - The tool runs conflict detection automatically. If it reports a conflict:
            1. Name the conflicting event and its time clearly.
            2. Ask the user how to proceed — offer exactly these options:
               (a) Pick a different time — you will call createCalendarEvent with the new time
               (b) Move the existing event to make room — you will call updateCalendarEvent on its eventID
               (c) Replace the existing event — you will call deleteCalendarEvent then createCalendarEvent
            3. Make NO calendar changes until the user explicitly picks an option.
            4. After the user responds, make exactly one follow-up tool call matching their choice.

        Updating events:
        - Call updateCalendarEvent when the user wants to change an existing event.
        - Always call fetchCalendarEvents first to obtain the exact eventID. \
          Use the startISO and endISO values already computed in the date prefix above.
        - Only pass fields the user explicitly wants changed; omit others (nil = leave unchanged).
        - An empty string for location or notes clears that field — use only when the user \
          explicitly says to remove it.
        - Confirm what will change before calling updateCalendarEvent.
        - For relative time changes ("next hour", "next day", "next Friday"), compute the exact \
          new date and time from today's date before calling the tool.

        Intent disambiguation:
        - "reschedule", "move", "change", "update" → updateCalendarEvent
        - "add", "create", "schedule" (new event) → createCalendarEvent
        - When ambiguous, ask the user to clarify before acting.
        """

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
            logger.info("✓ Apple Intelligence model is available")
        case .unavailable:
            isModelAvailable = false
            errorMessage = "Apple Intelligence is not available on this device. You need an iPhone with an A17 Pro or M-series chip running iOS 26.4 with Apple Intelligence enabled."
            logger.warning("✗ Apple Intelligence model is unavailable")
        @unknown default:
            isModelAvailable = false
            errorMessage = "Apple Intelligence availability is unknown."
            logger.error("✗ Unknown Apple Intelligence availability state")
        }
    }

    // MARK: - Session Construction

    /// Builds the instruction string with today's full and ISO dates so the model can
    /// resolve relative references ("tomorrow", "next Friday") to concrete date strings.
    static func buildInstructions() -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let isoToday       = f.string(from: today)
        let isoTomorrow    = f.string(from: cal.date(byAdding: .day, value: 1,  to: today)!)
        let iso14DaysLater = f.string(from: cal.date(byAdding: .day, value: 14, to: today)!)
        let verbose = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
        let prefix = """
            Today is \(verbose). \
            YYYY-MM-DD dates: today=\(isoToday), tomorrow=\(isoTomorrow), \
            14-days-from-today=\(iso14DaysLater). \
            When fetching to find an event to update or reschedule: \
            use startISO='\(isoToday)' (today) and endISO='\(iso14DaysLater)' (14 days out). \
            Do NOT use \(iso14DaysLater) as startISO.
            """
        return prefix + "\n\n" + agentInstructions
    }

    private func buildSession() {
        let tools: [any Tool] = [
            FetchCalendarEventsTool(calendarService: calendarService),
            DeleteCalendarEventTool(calendarService: calendarService),
            CreateCalendarEventTool(calendarService: calendarService),
            UpdateCalendarEventTool(calendarService: calendarService)
        ]

        logger.info("Building LanguageModelSession with 4 tools: fetchCalendarEvents, deleteCalendarEvent, createCalendarEvent, updateCalendarEvent")

        let instructions = VoxiCalAgent.buildInstructions()

        session = LanguageModelSession(
            tools: tools,
            instructions: instructions
        )
    }

    // MARK: - Send Text Message

    /// Primary entry point for both typed text and transcribed voice.
    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }

        logger.info("[USER] \(trimmed, privacy: .public)")

        // Auto-reset conversation after 16 messages (8 turns) to prevent context window overflow
        if messages.count >= 16 {
            logger.info("Context window approaching limit (16 messages) — clearing conversation")
            clearConversation()
        }

        guard let session else {
            errorMessage = "Session not ready — please wait a moment and try again."
            logger.error("Session is nil when sending message")
            return
        }

        // Stop any in-progress TTS immediately so voices don't overlap
        ttsService.stop()

        messages.append(ChatMessage(role: .user, text: trimmed))
        isProcessing  = true
        errorMessage  = nil

        var responseText: String?
        var lastError: Error?

        for attempt in 1...3 {
            do {
                let response = try await session.respond(to: trimmed)
                responseText = response.content
                break
            } catch {
                lastError = error
                let isTransient = error.localizedDescription.contains("error -1")
                    || error.localizedDescription.localizedCaseInsensitiveContains("generation")
                guard isTransient && attempt < 3 else { break }
                logger.warning("Transient model error (attempt \(attempt)/3), retrying in \(attempt * 2)s…")
                try? await Task.sleep(for: .seconds(Double(attempt * 2)))
            }
        }

        if let text = responseText {
            logger.info("[AGENT] \(text, privacy: .public)")
            messages.append(ChatMessage(role: .assistant, text: text))
            ttsService.speak(text)
        } else {
            let friendly = friendlyError(from: lastError ?? NSError(domain: "VoxiCal", code: -1))
            logger.error("Agent failed after 3 attempts: \(lastError?.localizedDescription ?? "unknown")")
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
