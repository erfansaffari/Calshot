// Generates Resources/CalshotAlert.wav: Calshot's alert chime, a soft two-note glass bell (~1.2 s).
// Run: swift script/generate_alert_sound.swift
import Foundation

let rate = 44_100.0, length = 1.25
let count = Int(rate * length)
var samples = [Double](repeating: 0, count: count)
/// A bell-like note: a fundamental with gently inharmonic partials and an exponential decay.
func note(_ frequency: Double, at start: Double, gain: Double, decay: Double) {
    let partials: [(ratio: Double, gain: Double, decay: Double)] = [(1, 1, 1), (2.0, 0.28, 0.55), (2.76, 0.12, 0.4), (4.07, 0.05, 0.25)]
    let begin = Int(start * rate)
    for i in begin..<count {
        let t = Double(i - begin) / rate
        let attack = min(1, t / 0.006)
        var value = 0.0
        for p in partials { value += p.gain * exp(-t / (decay * p.decay)) * sin(2 * .pi * frequency * p.ratio * t) }
        samples[i] += gain * attack * value
    }
}
note(1318.51, at: 0.0, gain: 0.55, decay: 0.32)   // E6
note(1975.53, at: 0.11, gain: 0.42, decay: 0.42)  // B6
// Peak at about -14 dBFS, with a short fade at the end.
let peak = samples.map(abs).max() ?? 1
let target = pow(10, -14.0 / 20)
for i in 0..<count {
    let fade = min(1, Double(count - i) / (0.05 * rate))
    samples[i] = samples[i] / peak * target * fade
}
var data = Data()
func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; data.append(Data(bytes: &v, count: MemoryLayout<T>.size)) }
data.append("RIFF".data(using: .ascii)!); append(UInt32(36 + count * 2))
data.append("WAVEfmt ".data(using: .ascii)!); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
data.append("data".data(using: .ascii)!); append(UInt32(count * 2))
for s in samples { append(Int16(max(-1, min(1, s)) * 32_767)) }
let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/CalshotAlert.wav")
try! data.write(to: url)
print("Wrote \(url.path) (\(data.count) bytes)")
