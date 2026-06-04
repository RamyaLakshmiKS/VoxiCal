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

// MARK: - CalendarIntent

enum CalendarIntent: Equatable {
    case read, create, delete, update, unknown
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
    private var pendingCreateRequest: String?
    private var sessionCreationDay: Date = .distantPast
    private var currentIntent: CalendarIntent = .unknown

    // MARK: - Agent Instructions (section-based for per-intent composition)

    private static let introSection = """
        You are VoxiCal, a calm and concise iOS calendar assistant. \
        You help users understand and manage their schedule using only the tools provided.
        """

    private static let fetchSection = """
        Tool usage:
        - Call fetchCalendarEvents whenever the user asks about events, meetings, appointments, or availability — past or future.
        - Call it ONCE per question with the correct date range. Never call it multiple times for the same query. Do not call it for general knowledge.
        - To delete an event: ALWAYS call fetchCalendarEvents first. Identify the event, name it in your reply for the user to confirm, then call deleteCalendarEvent with the exact eventID.
        - Use the pre-computed ISO dates from the date prefix — never compute by hand. Always fetch with a SINGLE call covering the full date range — never call per day.
        """

    private static let eventIDSection = """
        Event IDs:
        - Event IDs appear in the [INTERNAL] section of the fetchCalendarEvents response. Each line is formatted as: Title (Day Mon DD HH:mm): eventID. Use the complete eventID string when calling update or delete tools.
        - NEVER include eventID values in your replies to the user — no exceptions.
        - NEVER use an eventID from a previous turn — always call fetchCalendarEvents in the same turn before update or delete.
        """

    private static let successSection = """
        Success reporting: Only tell the user a calendar change was made if the corresponding tool returned a success message. Never report "updated" or "scheduled" unless the action tool explicitly confirmed it.
        """

    private static let accuracySection = """
        Accuracy — ABSOLUTE RULES, no exceptions:
        - ONLY report events that appear in the fetchCalendarEvents tool response. Never use training knowledge, assumptions, or conversation memory to claim any event exists.
        - STOP RULE: If the tool returns empty → say "You have nothing scheduled" or "I don't see any [meetings/events]." Never imply any event exists.
        - An event matches a person ONLY if that person's name appears in the event TITLE. "Team standup" is NOT a meeting with Sarah.
        - When the user asks about a specific person, ALWAYS use titleFilter with that name. If the result is empty → say immediately "I don't see a meeting with [name]." NEVER retry without the filter.
        """

    private static let styleSection = """
        Response style — this is a VOICE assistant, responses are spoken aloud:
        - Use plain conversational sentences only. No markdown, no bold, no headers, no bullet symbols (•), no dashes (-), no asterisks (*), no numbered lists. These are read aloud literally by TTS and sound broken.
        - Keep replies to one or two sentences. For 2–4 events: "You have standup at 9 and a review at 2." For 5+ events: "You have N meetings this week. The main ones are..." — list at most 3 specifics.
        - For all-day events, say "[title], all day [day label]" — never read a time.
        - Format times and dates conversationally: "tomorrow at 9 AM", "this Friday at 2 PM".
        - When listing events, use ONLY the exact date and time shown in the event's description.
        """

    private static let createSection = """
        Creating events:
        - Call createCalendarEvent when the user wants to add a brand-new event.
        - Required before calling the tool: specific event title (not just "call" or "meeting"), date and exact start time, duration in minutes, platform or location. Use the pre-computed ISO dates from the date prefix for startISO.
        - If any required detail is missing, ask one short targeted question for only the missing detail(s). Do not call createCalendarEvent until all details are known. A response that calls createCalendarEvent AND asks for missing details is WRONG.
        - If the user gives a vague time like "morning" or "afternoon", ask for a specific start time.
        - If the user answers a clarification with only missing details, reuse the earlier title/date/time and create the event.
        - The tool runs conflict detection automatically. If it reports a conflict: name the conflicting event, ask how to proceed — (a) pick a different time, (b) move the existing event, (c) replace it. Make no changes until the user chooses.
        """

    private static let updateSection = """
        Updating events:
        - Call updateCalendarEvent to change an existing event. Always call fetchCalendarEvents first in the same turn.
        - If the user has not named a specific event, ask which one before fetching. If multiple events match, list them and ask which to update.
        - Only pass fields the user explicitly asked to change (nil = keep unchanged, "" = clear the field).
        - After a successful update, confirm what changed: "Moved your standup to 10am tomorrow."
        - For recurring events, ask: "Change just this occurrence, or the whole series?"
        - If a time is given without AM/PM and context is unclear, ask before updating. If no fetched event matches the user's description, say it was not found.
        """

    private static let disambiguationSection = """
        Intent disambiguation:
        - "reschedule", "move", "change", "update" → updateCalendarEvent
        - "add", "create", "schedule" (new event) → createCalendarEvent
        - "delete", "remove", "cancel" → deleteCalendarEvent
        - When ambiguous, ask the user to clarify before acting.
        """

    /// Backward-compatible accessor used by evals and tests.
    static var agentInstructions: String { buildInstructions() }

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
    /// Composes only the sections relevant to the given intent to minimize token usage.
    static func buildInstructions(for intent: CalendarIntent = .unknown, recentHistory: String? = nil) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"

        let isoToday        = f.string(from: today)
        let isoTomorrow     = f.string(from: cal.date(byAdding: .day, value:  1, to: today)!)
        let isoYesterday    = f.string(from: cal.date(byAdding: .day, value: -1, to: today)!)
        let iso14DaysLater  = f.string(from: cal.date(byAdding: .day, value: 14, to: today)!)

        // Calendar-week boundaries (locale-aware)
        let thisWeekInterval = cal.dateInterval(of: .weekOfYear, for: today)!
        let isoThisWeekStart = f.string(from: thisWeekInterval.start)
        let isoThisWeekEnd   = f.string(from: cal.date(byAdding: .day, value: -1, to: thisWeekInterval.end)!)

        let nextWeekInterval = cal.dateInterval(of: .weekOfYear, for: thisWeekInterval.end)!
        let isoNextWeekStart = f.string(from: nextWeekInterval.start)
        let isoNextWeekEnd   = f.string(from: cal.date(byAdding: .day, value: -1, to: nextWeekInterval.end)!)

        // Month boundaries
        let thisMonthInterval = cal.dateInterval(of: .month, for: today)!
        let isoThisMonthStart = f.string(from: thisMonthInterval.start)
        let isoThisMonthEnd   = f.string(from: cal.date(byAdding: .day, value: -1, to: thisMonthInterval.end)!)

        let nextMonthInterval = cal.dateInterval(of: .month, for: thisMonthInterval.end)!
        let isoNextMonthStart = f.string(from: nextMonthInterval.start)
        let isoNextMonthEnd   = f.string(from: cal.date(byAdding: .day, value: -1, to: nextMonthInterval.end)!)

        let lastMonthDate     = cal.date(byAdding: .month, value: -1, to: today)!
        let lastMonthInterval = cal.dateInterval(of: .month, for: lastMonthDate)!
        let isoLastMonthStart = f.string(from: lastMonthInterval.start)
        let isoLastMonthEnd   = f.string(from: cal.date(byAdding: .day, value: -1, to: lastMonthInterval.end)!)

        // Weekday dates this week
        let isoThisMonday    = f.string(from: thisWeekInterval.start)
        let isoThisTuesday   = f.string(from: cal.date(byAdding: .day, value: 1, to: thisWeekInterval.start)!)
        let isoThisWednesday = f.string(from: cal.date(byAdding: .day, value: 2, to: thisWeekInterval.start)!)
        let isoThisThursday  = f.string(from: cal.date(byAdding: .day, value: 3, to: thisWeekInterval.start)!)
        let isoThisFriday    = f.string(from: cal.date(byAdding: .day, value: 4, to: thisWeekInterval.start)!)

        // Weekend (nearest upcoming Saturday and Sunday)
        let weekdayToday = cal.component(.weekday, from: today)
        let daysToSat = weekdayToday == 7 ? 0 : 7 - weekdayToday
        let daysToSun = weekdayToday == 1 ? 0 : 8 - weekdayToday
        let isoThisSaturday = f.string(from: cal.date(byAdding: .day, value: daysToSat, to: today)!)
        let isoThisSunday   = f.string(from: cal.date(byAdding: .day, value: daysToSun, to: today)!)

        // Current time (HH:mm local)
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm"
        let isoCurrentTime = tf.string(from: Date())

        let verbose = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .none)
        let datePrefix = """
            Today is \(verbose). Current time: \(isoCurrentTime). \
            YYYY-MM-DD dates — use these EXACTLY: \
            today=\(isoToday), tomorrow=\(isoTomorrow), yesterday=\(isoYesterday). \
            Weekdays this week: Mon=\(isoThisMonday), Tue=\(isoThisTuesday), \
            Wed=\(isoThisWednesday), Thu=\(isoThisThursday), Fri=\(isoThisFriday). \
            This week: \(isoThisWeekStart)–\(isoThisWeekEnd). \
            Next week: \(isoNextWeekStart)–\(isoNextWeekEnd). \
            This month: \(isoThisMonthStart)–\(isoThisMonthEnd). \
            Next month: \(isoNextMonthStart)–\(isoNextMonthEnd). \
            Last month: \(isoLastMonthStart)–\(isoLastMonthEnd). \
            This weekend: \(isoThisSaturday)–\(isoThisSunday). \
            For update/delete fetches: startISO=\(isoToday) endISO=\(iso14DaysLater).
            """

        var parts: [String] = []
        if let history = recentHistory { parts.append(history) }
        parts.append(datePrefix)
        parts.append(introSection)
        if intent != .create                                             { parts.append(fetchSection) }
        if intent == .delete || intent == .update || intent == .unknown  { parts.append(eventIDSection) }
        parts.append(successSection)
        parts.append(accuracySection)
        parts.append(styleSection)
        if intent == .create || intent == .unknown                       { parts.append(createSection) }
        if intent == .update || intent == .unknown                       { parts.append(updateSection) }
        parts.append(disambiguationSection)
        return parts.joined(separator: "\n\n")
    }

    private func buildSession(for intent: CalendarIntent = .unknown, recentHistory: String? = nil) {
        let fetch  = FetchCalendarEventsTool(calendarService: calendarService)
        let delete = DeleteCalendarEventTool(calendarService: calendarService)
        let create = CreateCalendarEventTool(calendarService: calendarService)
        let update = UpdateCalendarEventTool(calendarService: calendarService)

        let tools: [any Tool]
        switch intent {
        case .read:    tools = [fetch]
        case .create:  tools = [create]
        case .delete:  tools = [fetch, delete]
        case .update:  tools = [fetch, update]
        case .unknown: tools = [fetch, delete, create, update]
        }

        logger.info("Building LanguageModelSession for intent=\(String(describing: intent), privacy: .public) with \(tools.count) tool(s)")

        let instructions = VoxiCalAgent.buildInstructions(for: intent, recentHistory: recentHistory)

        sessionCreationDay = Calendar.current.startOfDay(for: Date())
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

        // Rebuild session if calendar date has rolled past midnight (stale date anchors)
        let currentDay = Calendar.current.startOfDay(for: Date())
        if currentDay != sessionCreationDay, session != nil {
            logger.info("Calendar date changed since session was built — rebuilding with fresh anchors")
            clearConversation()
            messages.append(ChatMessage(role: .assistant, text: "It's a new day — I've refreshed my date references. Please ask again!"))
            return
        }

        logger.info("[USER] \(trimmed, privacy: .public)")

        // Auto-reset conversation after 16 messages (8 turns) to prevent context window overflow
        if messages.count >= 16 {
            logger.info("Context window approaching limit (16 messages) — clearing conversation")
            clearConversation()
        }

        // Rebuild session with intent-specific tools when the user's goal changes
        let detectedIntent = detectIntent(trimmed)
        if detectedIntent != currentIntent {
            let history = recentHistoryContext()
            currentIntent = detectedIntent
            buildSession(for: detectedIntent, recentHistory: history.isEmpty ? nil : history)
            logger.info("Intent changed to \(String(describing: detectedIntent), privacy: .public) — session rebuilt")
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

        if let pending = pendingCreateRequest {
          let combinedRequest = pending + " " + trimmed
          if let draft = parseCreateDraft(from: combinedRequest) {
            // All required fields collected. Route through the LLM session so that
            // conflict responses, confirmations, and errors are always natural language.
            // Calling the tool directly would expose raw tool-result text to the user.
            self.pendingCreateRequest = nil
            let synthesized = synthesizeCreatePrompt(from: draft)
            logger.info("[FAST-PATH→LLM] \(synthesized, privacy: .public)")
            do {
              let response = try await session.respond(to: synthesized)
              logger.info("[AGENT] \(response.content, privacy: .public)")
              messages.append(ChatMessage(role: .assistant, text: response.content))
              ttsService.speak(response.content)
            } catch {
              let friendly = friendlyError(from: error)
              logger.error("Create via LLM failed: \(error.localizedDescription, privacy: .public)")
              messages.append(ChatMessage(role: .assistant, text: friendly))
            }
            isProcessing = false
            return
          }
          // Parse still incomplete — re-evaluate what's missing from the accumulated context
          // and keep collecting rather than falling through to the LLM cold.
          if let clarification = clarificationForAmbiguousCreateRequest(combinedRequest) {
            self.pendingCreateRequest = combinedRequest  // advance the accumulated state
            logger.info("[AGENT] \(clarification, privacy: .public)")
            messages.append(ChatMessage(role: .assistant, text: clarification))
            ttsService.speak(clarification)
            isProcessing = false
            return
          }
          // User said something that isn't a create follow-up — abandon fast path.
          self.pendingCreateRequest = nil
        }

        if let clarification = clarificationForAmbiguousCreateRequest(trimmed) {
          pendingCreateRequest = trimmed
          logger.info("[AGENT] \(clarification, privacy: .public)")
          messages.append(ChatMessage(role: .assistant, text: clarification))
          ttsService.speak(clarification)
          isProcessing = false
          return
        }

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
        pendingCreateRequest = nil
        currentIntent = .unknown
        buildSession()
        appendWelcome()
    }

    // MARK: - Private Helpers

    private func appendWelcome() {
        messages.append(ChatMessage(
            role: .assistant,
            text: "Hi, how can I help you today?"
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

    private func clarificationForAmbiguousCreateRequest(_ text: String) -> String? {
      guard isCreateIntent(text) else { return nil }

      let missingTitle    = extractedTitle(from: text) == nil
      let missingDateTime = extractedDate(from: text) == nil || extractedTime(from: text) == nil
      let missingDuration = extractedDurationMinutes(from: text) == nil
      let missingLocation = extractedLocation(from: text) == nil

      // Choose a natural label for the "title" question based on what the user said.
      // "Create a meeting" / "Book a call" → ask who it's with, not for a generic title.
      let titleQuestion = genericMeetingWithoutPerson(text)
        ? "who the meeting is with"
        : "what to call the event"

      // When title is missing along with other fields, bundle it into the question.
      if missingTitle && missingDateTime && missingDuration && missingLocation {
        return "I can help with that — could you tell me \(titleQuestion), the date and time, how long it should be, and where it will take place?"
      }
      if missingTitle && missingDateTime && missingDuration {
        return "Could you tell me \(titleQuestion), the date and time, and how long it should be?"
      }
      if missingTitle && missingDateTime && missingLocation {
        return "Could you tell me \(titleQuestion), the date and time, and where it will take place?"
      }
      if missingTitle && missingDuration && missingLocation {
        return "Could you tell me \(titleQuestion), how long it should be, and where it will take place?"
      }
      if missingDateTime && missingDuration && missingLocation {
        return "What date, time, duration, and location should I use for the event?"
      }
      if missingDateTime && missingDuration {
        return "What date, time, and duration should I use for the event?"
      }
      if missingDateTime && missingLocation {
        return "What date, time, and location should I use for the event?"
      }
      if missingDuration && missingLocation {
        return "How long should it be, and where should I schedule it?"
      }
      if missingTitle && missingDateTime {
        return "Could you tell me \(titleQuestion) and the date and time?"
      }
      if missingTitle && missingDuration {
        return "Could you tell me \(titleQuestion) and how long it should be?"
      }
      if missingTitle && missingLocation {
        return "Could you tell me \(titleQuestion) and where it will take place?"
      }
      if missingDateTime {
        return "What date and time should I use for the event?"
      }
      if missingDuration {
        return "How long should the event be?"
      }
      if missingLocation {
        return "Where should I schedule the event?"
      }
      if missingTitle {
        return genericMeetingWithoutPerson(text)
          ? "Who will you be meeting with?"
          : "What should I title the event?"
      }
      return nil
    }

    /// Returns true when the text describes a generic meeting/call but doesn't name who it's with.
    private func genericMeetingWithoutPerson(_ text: String) -> Bool {
      let lower = text.lowercased()
      let hasGenericWord = lower.contains("a meeting") || lower.contains("a call")
          || lower.contains("a sync") || lower.contains("a session")
      // If we already extracted a title (person/org found), it's not "without person"
      let hasPerson = extractedTitle(from: text) != nil
      return hasGenericWord && !hasPerson
    }

    /// Builds a compact, structured prompt the LLM can act on once the fast-path
    /// has collected all required fields. The LLM then calls createCalendarEvent
    /// and handles conflicts, confirmations, and errors in natural language.
    private func synthesizeCreatePrompt(from draft: CreateCalendarEventTool.Arguments) -> String {
      var parts = ["Create an event:"]
      parts.append("title '\(draft.title)'")
      parts.append("starting \(draft.startISO)")
      if let mins = draft.durationMinutes { parts.append("for \(mins) minutes") }
      if let loc  = draft.location        { parts.append("at \(loc)") }
      if let note = draft.notes           { parts.append("notes: \(note)") }
      return parts.joined(separator: ", ")
    }

    private func parseCreateDraft(from text: String) -> CreateCalendarEventTool.Arguments? {
      guard let title = extractedTitle(from: text),
          let startISO = makeStartISO(from: text),
          let durationMinutes = extractedDurationMinutes(from: text),
          let location = extractedLocation(from: text) else {
        return nil
      }

      return CreateCalendarEventTool.Arguments(
        title: title,
        startISO: startISO,
        durationMinutes: durationMinutes,
        location: location,
        notes: nil
      )
    }

    private func isCreateIntent(_ text: String) -> Bool {
      detectIntent(text) == .create
    }

    private func detectIntent(_ text: String) -> CalendarIntent {
      let lower = text.lowercased()
      if lower.contains("delete") || lower.contains("remove") || lower.contains("cancel") { return .delete }
      if lower.contains("reschedule") || lower.contains("move") || lower.contains("update")
          || lower.contains("change") || lower.contains("shift") || lower.contains("rename") { return .update }
      if lower.contains("schedule") || lower.contains("create") || lower.contains("add ")
          || lower.contains("book") || lower.contains("set up") || lower.contains("plan ")
          || lower.contains("put on") || lower.contains("need to meet") || lower.contains("want to meet") { return .create }
      if lower.contains("what") || lower.contains("when") || lower.contains("show")
          || lower.contains("do i have") || lower.contains("any") || lower.contains("list")
          || lower.contains("free") || lower.contains("available") { return .read }
      return .unknown
    }

    private func recentHistoryContext() -> String {
      guard !messages.isEmpty else { return "" }
      let recent = messages.suffix(4)
      let lines = recent.map { msg -> String in
        let role = msg.role == .user ? "User" : "Assistant"
        return "\(role): \(msg.text)"
      }
      return "[Recent conversation:]\n" + lines.joined(separator: "\n")
    }

    private func extractedTitle(from text: String) -> String? {
      let lower = text.lowercased()

      // Named 1:1 pattern
      if let range = lower.range(of: #"1:1 with [A-Za-z][A-Za-z\- ]+"#, options: .regularExpression) {
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      // 1-on-1 / one-on-one variant
      if let range = lower.range(of: #"(?:1-on-1|one-on-one) with [A-Za-z][A-Za-z\- ]+"#, options: .regularExpression) {
        let title = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.prefix(1).uppercased() + title.dropFirst()
      }

      // Well-known named event types (no person needed)
      if lower.contains("team sync")    { return "Team sync" }
      if lower.contains("check-in")     { return "Check-in" }
      if lower.contains("standup") || lower.contains("stand-up") || lower.contains("stand up") { return "Standup" }
      if lower.contains("all hands") || lower.contains("all-hands") { return "All Hands" }
      if lower.contains("design review") { return "Design review" }
      if lower.contains("sprint planning") { return "Sprint planning" }
      if lower.contains("retro")         { return "Retro" }

      // "X with [Person]" — allow arbitrary words between the event type and "with"
      // e.g. "meeting tomorrow with Google" or "call next week with Priya"
      let eventTypes = ["call", "sync", "catch-up", "catchup", "catch up",
                        "lunch", "coffee", "interview", "review", "session",
                        "discussion", "meeting"]
      // Words that appear after "with" but are NOT person/company names
      let nonPersonWords: Set<String> = ["the", "a", "an", "my", "our", "us", "me",
                                         "you", "your", "him", "her", "them", "who",
                                         "zoom", "teams", "meet", "skype", "webex"]

      for eventType in eventTypes {
        guard lower.contains(eventType) else { continue }
        // Find "with [Name]" anywhere in the text
        guard let nameRange = lower.range(of: #"\bwith\s+([A-Za-z][A-Za-z]+)"#, options: .regularExpression),
              let captureRange = lower.range(of: #"(?<=\bwith\s)[A-Za-z][A-Za-z]+"#, options: .regularExpression)
        else { continue }
        let _ = nameRange  // nameRange confirms the pattern exists
        let name = String(lower[captureRange])
        guard !nonPersonWords.contains(name) else { continue }
        let nameCapitalized = name.prefix(1).uppercased() + name.dropFirst()
        let typeCapitalized = eventType.prefix(1).uppercased() + eventType.dropFirst()
        return "\(typeCapitalized) with \(nameCapitalized)"
      }

      return nil
    }

    private func extractedDate(from text: String) -> Date? {
      let lower = text.lowercased()
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())

      if lower.contains("tomorrow") {
        return calendar.date(byAdding: .day, value: 1, to: today)
      }
      if lower.contains("today") {
        return today
      }
      for weekday in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] {
        if lower.contains("next \(weekday)") || lower.contains("this \(weekday)") || lower.contains(weekday) {
          let targetWeekday = weekdayNumber(for: weekday)
          let currentWeekday = calendar.component(.weekday, from: today)
          var daysAhead = (targetWeekday - currentWeekday + 7) % 7
          if lower.contains("next \(weekday)") {
            daysAhead += 7
          } else if daysAhead == 0 {
            daysAhead = 0
          }
          return calendar.date(byAdding: .day, value: daysAhead, to: today)
        }
      }
      return nil
    }

    private func extractedTime(from text: String) -> (hour: Int, minute: Int)? {
      let lower = text.lowercased()
      // "morning", "afternoon" etc. are always vague times.
      if lower.contains("morning") || lower.contains("afternoon") || lower.contains("evening")
          || lower.contains("later") || lower.contains("after lunch") {
        return nil
      }
      // "around" is only vague when it modifies a time ("around 3pm"), not a duration ("around 2 hours").
      // Block only when "around" is followed by a time pattern, not by a number+duration unit.
      let aroundModifiesDuration = lower.range(of: #"\baround\s+\d+\s*(?:hours?|hrs?|minutes?|mins?)"#, options: .regularExpression) != nil
      let aroundModifiesTime    = lower.range(of: #"\baround\s+\d"#, options: .regularExpression) != nil && !aroundModifiesDuration
      if aroundModifiesTime { return nil }

      let pattern = #"\b(1[0-2]|0?[1-9])(?::([0-5][0-9]))?\s*([ap]m)\b"#
      guard let match = lower.range(of: pattern, options: .regularExpression) else { return nil }
      let matched = String(lower[match])
      let parts = matched.replacingOccurrences(of: " ", with: "").components(separatedBy: CharacterSet(charactersIn: ":apm"))

      let regex = try? NSRegularExpression(pattern: pattern)
      guard let regex,
          let result = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }

      let hourString = (lower as NSString).substring(with: result.range(at: 1))
      let minuteString = result.range(at: 2).location != NSNotFound ? (lower as NSString).substring(with: result.range(at: 2)) : "00"
      let meridiem = (lower as NSString).substring(with: result.range(at: 3))

      guard var hour = Int(hourString), let minute = Int(minuteString) else { return nil }
      if meridiem == "pm" && hour < 12 { hour += 12 }
      if meridiem == "am" && hour == 12 { hour = 0 }
      return (hour, minute)
    }

    private func extractedDurationMinutes(from text: String) -> Int? {
      let lower = text.lowercased()

      // Natural-language fixed phrases (checked before digit/word patterns).
      // Regex covers informal variants: "half n hr", "half n hour", "half an hour", "half-hour", etc.
      if lower.range(of: #"\bhalf[\s-]*(?:an?\s+|n\s+)?h(?:our|r)\b"#, options: .regularExpression) != nil { return 30 }
      if lower.contains("an hour and a half") || lower.contains("hour and a half") { return 90 }
      if lower.contains("an hour") || lower.contains("a hour") { return 60 }

      // Digit-based: "30 minutes", "2 hrs", "1 hour"
      let digitPattern = #"\b(\d+)\s*(minutes?|mins?|hours?|hrs?)\b"#
      if let regex = try? NSRegularExpression(pattern: digitPattern),
         let result = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
        let valueString = (lower as NSString).substring(with: result.range(at: 1))
        let unit       = (lower as NSString).substring(with: result.range(at: 2))
        if let value = Int(valueString) {
          return unit.hasPrefix("hour") || unit.hasPrefix("hr") ? value * 60 : value
        }
      }

      // Word-number-based: "one hour", "thirty minutes", etc.
      let wordNumbers: [(String, Int)] = [
        ("sixty", 60), ("ninety", 90),
        ("forty-five", 45), ("forty five", 45),
        ("thirty", 30), ("forty", 40), ("twenty", 20), ("fifteen", 15),
        ("ten", 10), ("five", 5),
        ("one", 1), ("two", 2), ("three", 3), ("four", 4),
        ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9)
      ]
      for (word, value) in wordNumbers {
        if lower.range(of: #"\b"# + word + #"\s*(?:hours?|hrs?)\b"#, options: .regularExpression) != nil {
          return value * 60
        }
        if lower.range(of: #"\b"# + word + #"\s*(?:minutes?|mins?)\b"#, options: .regularExpression) != nil {
          return value
        }
      }

      return nil
    }

    private func extractedLocation(from text: String) -> String? {
      let lower = text.lowercased()
      if lower.contains("zoom") { return "Zoom" }
      if lower.contains("teams") { return "Teams" }
      if lower.contains("google meet") { return "Google Meet" }
      // Use word-boundary match so "meeting" does not falsely return "Meet"
      if lower.range(of: #"\bmeet\b"#, options: .regularExpression) != nil { return "Meet" }
      if lower.contains("conference room a") { return "Conference Room A" }
      if lower.contains("conference room") { return "Conference Room" }
      if lower.contains("in person") { return "In person" }
      return nil
    }

    private func makeStartISO(from text: String) -> String? {
      guard let date = extractedDate(from: text), let time = extractedTime(from: text) else { return nil }
      var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
      components.hour = time.hour
      components.minute = time.minute
      guard let startDate = Calendar.current.date(from: components) else { return nil }

      let formatter = DateFormatter()
      formatter.calendar = Calendar.current
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone.current
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
      return formatter.string(from: startDate)
    }

    private func weekdayNumber(for weekday: String) -> Int {
      switch weekday {
      case "sunday": return 1
      case "monday": return 2
      case "tuesday": return 3
      case "wednesday": return 4
      case "thursday": return 5
      case "friday": return 6
      case "saturday": return 7
      default: return 1
      }
    }
}
