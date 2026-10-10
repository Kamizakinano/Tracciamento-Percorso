import AVFoundation

/// Avviso vocale "Strada già percorsa" (anche in background, grazie alla modalità audio).
final class VoiceAlert: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceAlert()

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Cuffie, auricolari Bluetooth o CarPlay collegati.
    var hasPrivateOutput: Bool {
        let privatePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { privatePorts.contains($0.portType) }
    }

    /// Parla se l'impostazione lo consente (0 mai, 1 solo cuffie/CarPlay, 2 sempre).
    func speakIfEnabled(_ text: String, setting: Int) {
        guard setting == 2 || (setting == 1 && hasPrivateOutput) else { return }
        speak(text)
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Restituisce l'audio alle altre app (musica, navigatore).
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
