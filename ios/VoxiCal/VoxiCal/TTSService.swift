import AVFoundation

// MARK: - TTSService

/// Converts LLM response text to spoken audio using AVSpeechSynthesizer.
///
/// Responsibilities:
///  - Speak each assistant response immediately after it arrives
///  - Interrupt any in-progress speech when a new response comes in
///  - Pause/resume if the user taps the speaker button
///  - Switch the audio session back to playback mode so the voice is audible
///    (SpeechService sets the session to .record; TTSService must reclaim it)
@MainActor
@Observable
class TTSService: NSObject {

    // MARK: - Observed State

    /// True while the synthesizer is actively speaking — used to show a stop button in the UI.
    var isSpeaking: Bool = false

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak `text` aloud. Interrupts any currently playing speech.
    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Reclaim the audio session for playback (recording session set by SpeechService)
        configurePlaybackSession()

        // Stop any in-progress utterance immediately so the new response starts right away
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)

        // Rate: 0.5 is AVSpeechUtteranceDefaultSpeechRate — natural conversational pace.
        // Slightly above default feels more like an assistant and less like a screen reader.
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = preferredVoice()

        // Small pre-utterance delay so the UI chat bubble renders before audio starts
        utterance.preUtteranceDelay = 0.15

        synthesizer.speak(utterance)
    }

    /// Stop speaking immediately — called when the user taps the stop/speaker button.
    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .word)
        isSpeaking = false
    }

    /// Toggle pause/resume — useful if the user wants to re-read the text at their own pace.
    func togglePause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
    }

    // MARK: - Private Helpers

    /// Selects the best available voice for the device's current locale,
    /// with an enhanced (neural) voice preferred over the default.
    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"

        // Prefer enhanced/neural voices (higher quality, downloaded on demand)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let enhanced = voices.first {
            $0.language.hasPrefix(languageCode) &&
            $0.quality == .enhanced
        }
        if let enhanced { return enhanced }

        // Fall back to any voice matching the locale language
        let standard = voices.first { $0.language.hasPrefix(languageCode) }
        if let standard { return standard }

        // Final fallback: system default
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    /// Switches the shared AVAudioSession to playback mode so speech is audible.
    /// Must be called after SpeechService deactivates the recording session.
    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? session.setActive(true)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
