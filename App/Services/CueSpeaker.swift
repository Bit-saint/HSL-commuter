import AVFoundation
import AudioToolbox
import CoreHaptics
import UIKit
import ETAEngine

/// Spoken and haptic pace cues, so the phone can stay in your pocket.
/// Voice ducks your music briefly; by default it only speaks when headphones are connected.
@MainActor
final class CueSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    enum Haptic {
        case gentle      // one soft tap: time to go / you're on track
        case speedUp     // two taps
        case urgent      // three quick taps: run
        case attention   // long buzz: missed / changed
    }

    private let synth = AVSpeechSynthesizer()
    private var engine: CHHapticEngine?
    private var lastSpoken = Date.distantPast
    private var lastText = ""

    override init() {
        super.init()
        synth.delegate = self
    }

    var headphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        return outputs.contains { [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio].contains($0) }
    }

    // MARK: - Speaking

    /// - Parameter urgent: bypasses the 20 s spacing between messages.
    func say(_ text: String, settings: SmartSettings, urgent: Bool = false) {
        guard settings.voiceCues, !text.isEmpty, text != lastText || urgent else { return }
        guard !settings.voiceHeadphonesOnly || headphonesConnected else { return }
        guard urgent || Date().timeIntervalSince(lastSpoken) > 20 else { return }
        lastSpoken = Date()
        lastText = text

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: settings.voiceLanguage == "fi" ? "fi-FI" : "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.prefersAssistiveTechnologySettings = true
        synth.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Give the music back.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Haptics

    func haptic(_ kind: Haptic, settings: SmartSettings) {
        guard settings.haptics else { return }
        let taps: [(time: Double, intensity: Float, sharpness: Float, duration: Double)]
        switch kind {
        case .gentle: taps = [(0, 0.5, 0.2, 0)]
        case .speedUp: taps = [(0, 0.8, 0.5, 0), (0.18, 0.8, 0.5, 0)]
        case .urgent: taps = [(0, 1, 0.8, 0), (0.12, 1, 0.8, 0), (0.24, 1, 0.8, 0)]
        case .attention: taps = [(0, 0.9, 0.3, 0.5)]
        }
        if UIApplication.shared.applicationState == .active, CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            playCoreHaptics(taps)
        } else {
            // In the background Core Haptics is unavailable; system vibrations still work.
            for (i, _) in taps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.45) {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
            }
        }
    }

    private func playCoreHaptics(_ taps: [(time: Double, intensity: Float, sharpness: Float, duration: Double)]) {
        do {
            if engine == nil { engine = try CHHapticEngine(); engine?.isAutoShutdownEnabled = true }
            try engine?.start()
            let events = taps.map { t in
                CHHapticEvent(eventType: t.duration > 0 ? .hapticContinuous : .hapticTransient,
                              parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: t.intensity),
                                           CHHapticEventParameter(parameterID: .hapticSharpness, value: t.sharpness)],
                              relativeTime: t.time, duration: t.duration)
            }
            let player = try engine?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player?.start(atTime: 0)
        } catch {}
    }

    // MARK: - Phrases (English / Finnish)

    static func noun(_ mode: TransitMode, fi: Bool) -> String {
        switch mode {
        case .bus, .trunkBus, .uBus: return fi ? "Bussi" : "Bus"
        case .tram, .lightRail: return fi ? "Ratikka" : "Tram"
        case .metro: return "Metro"
        case .rail: return fi ? "Juna" : "Train"
        case .ferry: return fi ? "Lautta" : "Ferry"
        default: return ""
        }
    }

    static func minutes(_ m: Int, fi: Bool) -> String {
        if m <= 0 { return fi ? "nyt" : "now" }
        if m == 1 { return fi ? "minuutin päästä" : "in 1 minute" }
        return fi ? "\(m) minuutin päästä" : "in \(m) minutes"
    }

    static func meters(_ d: Double, fi: Bool) -> String {
        let m = Int((d / 10).rounded()) * 10
        return fi ? "\(m) metriä" : "\(m) metres"
    }

    /// What to say when the pace advice changes.
    static func phrase(for state: PaceState, previous: PaceState?, mode: TransitMode, line: String,
                       minutes m: Int, distance: Double, waitIndoors: Bool, fi: Bool) -> String? {
        let v = "\(noun(mode, fi: fi)) \(line)"
        switch state {
        case .leaveSoon:
            if waitIndoors { return fi ? "\(v) tulee \(minutes(m, fi: fi)). Odota vielä sisällä." : "\(v) \(minutes(m, fi: fi)). Stay inside a little longer." }
            return nil
        case .goNow:
            if let p = previous, p.urgency > PaceState.goNow.urgency {
                return fi ? "Hyvä, ehdit hyvin. Normaali tahti riittää." : "Nice, you're on track. Normal pace is fine."
            }
            return fi ? "Lähde nyt. \(v) tulee \(minutes(m, fi: fi))." : "Time to go. \(v) \(minutes(m, fi: fi))."
        case .walkBriskly:
            return fi ? "Kävele vähän reippaammin. \(v) tulee \(minutes(m, fi: fi)), matkaa \(meters(distance, fi: fi))."
                      : "Walk a bit faster. \(v) \(minutes(m, fi: fi)), \(meters(distance, fi: fi)) to go."
        case .run:
            return fi ? "Juokse! \(v) tulee \(minutes(m, fi: fi))." : "Run now. \(v) is \(m <= 1 ? "a minute" : "\(m) minutes") away."
        case .willMiss:
            return fi ? "Et ehdi tähän. Etsin seuraavan vaihtoehdon." : "You won't make this one. Finding the next option."
        case .atStop:
            return fi ? "Olet pysäkillä. \(v) tulee \(minutes(m, fi: fi))." : "You're at the stop. \(v) \(minutes(m, fi: fi))."
        default:
            return nil
        }
    }

    static func haptic(for state: PaceState, previous: PaceState?) -> Haptic? {
        switch state {
        case .goNow: return .gentle
        case .walkBriskly: return .speedUp
        case .run: return .urgent
        case .willMiss: return .attention
        default: return nil
        }
    }
}
