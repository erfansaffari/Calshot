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
