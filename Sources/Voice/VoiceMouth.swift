import Foundation
import os

/// Per-line timings and failures only: never the spoken text.
private let mouthLog = Logger(subsystem: "com.calshot.voice", category: "mouth")

/// Splits the agent's streamed reply into sentences to speak as soon as each one is complete, so the first words
/// play while the rest is still being written. Formatting meant for the eye is removed before speaking.
struct VoiceSentenceSplitter {
    private var buffer = ""
    /// Sentences longer than this are split at a comma or space, so speech starts sooner.
    var limit = 240
    mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let cut = boundary() {
            let sentence = Self.speakable(String(buffer[..<cut]))
            buffer = String(buffer[cut...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }
    mutating func finish() -> [String] {
        let rest = Self.speakable(buffer); buffer = ""
        return rest.isEmpty ? [] : [rest]
    }
    private func boundary() -> String.Index? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            if character == "\n" { return next }
            if ".!?؟…。".contains(character) {
                // A boundary needs what follows: "3.5" and "Dr." mid-stream are not ends yet.
                guard next < buffer.endIndex else { return nil }
                if buffer[next].isWhitespace, buffer.distance(from: buffer.startIndex, to: index) >= 2,
                   character != "." || !Self.abbreviation(before: index, in: buffer) { return buffer.index(after: next) }
            }
            index = next
        }
        guard buffer.count > limit else { return nil }
        let window = buffer.index(buffer.startIndex, offsetBy: limit)
        let head = buffer[..<window]
        if let comma = head.lastIndex(where: { ",،;:".contains($0) }) { return buffer.index(after: comma) }
        if let space = head.lastIndex(of: " ") { return buffer.index(after: space) }
        return window
    }
    private static let abbreviations: Set<String> = ["dr", "mr", "mrs", "ms", "st", "prof", "vs", "etc", "a.m", "p.m", "e.g", "i.e", "jr", "sr", "no"]
    private static func abbreviation(before dot: String.Index, in text: String) -> Bool {
        let word = text[..<dot].split(whereSeparator: { $0.isWhitespace }).last.map { $0.lowercased() } ?? ""
        return abbreviations.contains(word)
    }
    static func speakable(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\*\*|__|`|#+ ?"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s*(?:[-•*>]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Speaks sentences in order through Calshot's voice server. Up to two sentences are fetched ahead, so the next
/// one is ready when the current one ends; only the sentence at the front plays.
@MainActor protocol VoiceSpeaking: AnyObject {
    /// True while a sentence is waiting, arriving or still audible.
    var isSpeaking: Bool { get }
    var onFirstAudio: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var voice: String { get set }
    func say(_ sentence: String)
    /// Barge-in: drops everything queued and stops what is audible.
    func stop()
    /// Voice started: opens the connections the first sentence needs.
    func warm()
}
extension VoiceSpeaking { func warm() {} }

@MainActor final class VoiceMouth: VoiceSpeaking {
    var onFirstAudio: (() -> Void)?
    var onError: ((Error) -> Void)?
    var voice = VoiceMouth.defaultVoice
    static let defaultVoice = "Sulafat"
    /// Google's prebuilt voices with their published character, as offered in Settings → Voice. The server accepts
    /// only these names.
    static let voices: [(name: String, style: String)] = [
        ("Sulafat", "Warm"), ("Achird", "Friendly"), ("Kore", "Firm"), ("Puck", "Upbeat"), ("Charon", "Informative"),
        ("Aoede", "Breezy"), ("Achernar", "Soft"), ("Iapetus", "Clear"), ("Zephyr", "Bright"), ("Leda", "Youthful"),
        ("Orus", "Firm"), ("Fenrir", "Excitable"), ("Callirrhoe", "Easy-going"), ("Autonoe", "Bright"), ("Enceladus", "Breathy"),
        ("Umbriel", "Easy-going"), ("Algieba", "Smooth"), ("Despina", "Smooth"), ("Erinome", "Clear"), ("Algenib", "Gravelly"),
        ("Rasalgethi", "Informative"), ("Laomedeia", "Upbeat"), ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"),
        ("Pulcherrima", "Forward"), ("Zubenelgenubi", "Casual"), ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"), ("Sadaltager", "Knowledgeable")]
    private let service: any VoiceServicing
    private let audio: any VoiceAudio
    private final class Line {
        let id = UUID().uuidString
        let text: String
        var chunks: [Data] = []
        var done = false
        var task: Task<Void, Never>?
        init(_ text: String) { self.text = text }
    }
    private var lines: [Line] = []
    private var heardFirst = false
    private static let lookahead = 2
    init(service: any VoiceServicing, audio: any VoiceAudio) { self.service = service; self.audio = audio }

    var isSpeaking: Bool { !lines.isEmpty || audio.isPlaying }
    func warm() { service.warm() }

    func say(_ sentence: String) {
        let text = String(sentence.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if lines.isEmpty, !audio.isPlaying { heardFirst = false }
        lines.append(Line(text))
        fetch()
    }
    func stop() {
        for line in lines { line.task?.cancel() }
        lines = []
        _ = audio.flush()
    }
    private func fetch() {
        for line in lines.prefix(Self.lookahead) where line.task == nil {
            let started = Date()
            line.task = Task { [weak self, weak line] in
                guard let self, let line else { return }
                var first = true
                do {
                    for try await chunk in self.service.speech(line.text, voice: self.voice) {
                        if first { first = false; mouthLog.info("speech first audio: \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms") }
                        guard self.lines.contains(where: { $0 === line }) else { return }
                        if self.lines.first === line { self.play(chunk, line) } else { line.chunks.append(chunk) }
                    }
                } catch is CancellationError { return }
                catch {
                    guard self.lines.contains(where: { $0 === line }) else { return }
                    mouthLog.error("speech failed: \(String(describing: error), privacy: .public)")
                    self.onError?(error)
                }
                line.done = true
                self.advance()
            }
        }
    }
    private func play(_ chunk: Data, _ line: Line) {
        do {
            try audio.enqueuePCM16(chunk, itemID: line.id)
            if !heardFirst { heardFirst = true; onFirstAudio?() }
        } catch { onError?(error) }
    }
    /// The front sentence finished arriving: the next one plays what it already has, then streams the rest.
    private func advance() {
        while let front = lines.first, front.done {
            lines.removeFirst()
            if let next = lines.first { next.chunks.forEach { play($0, next) }; next.chunks = [] }
        }
        fetch()
    }
}
