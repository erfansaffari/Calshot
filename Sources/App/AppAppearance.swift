import AppKit
import SwiftUI

/// One durable preference shared by the web workspace and native surfaces.
enum AppAppearance: String, CaseIterable {
    case system, light, dark
    static let defaultsKey = "appearanceMode"
    static func resolve(_ value: String?) -> AppAppearance { value.flatMap(Self.init(rawValue:)) ?? .system }
    static var saved: AppAppearance { load(from: .standard) }
    static func load(from defaults: UserDefaults) -> AppAppearance { resolve(defaults.string(forKey: defaultsKey)) }
    func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.defaultsKey) }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Device-local material preferences. These never change permissions or billing routes.
struct GlassAppearance: Codable, Equatable {
    static let defaultsKey = "glassAppearance.v1"
    static let standard = GlassAppearance()
    var enabled = true
    var opacity = 0.35
    var blur = 24.0
    var contrast = 0.5
    var isValid: Bool {
        opacity.isFinite && (0.35...1).contains(opacity) && blur.isFinite && (0...40).contains(blur) && contrast.isFinite && (0...1).contains(contrast)
    }
    static func load(from defaults: UserDefaults) -> GlassAppearance {
        guard let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return .standard }
        return value
    }
    func save(to defaults: UserDefaults) throws {
        guard isValid else { throw CalendarToolArgumentError("Choose valid glass opacity, blur and contrast values.") }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
