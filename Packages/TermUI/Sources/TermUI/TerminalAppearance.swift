import UIKit
import SwiftTerm

/// Font family options for rendering terminal text.
public enum TerminalFontFamily: String, CaseIterable, Sendable, Equatable, Identifiable {
    case sfMono = "SF Mono"
    case menlo = "Menlo"
    case courier = "Courier"

    public var id: String { rawValue }

    /// Resolves the UIKit font for the requested point size, falling back to the system monospace font.
    public func uiFont(ofSize size: CGFloat) -> UIFont {
        switch self {
        case .sfMono:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            return UIFont(name: "Menlo-Regular", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .courier:
            return UIFont(name: "Courier", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// Cursor shapes supported by the terminal view.
public enum TerminalCursorStyle: String, CaseIterable, Sendable, Equatable, Identifiable {
    case block = "Block"
    case bar = "Bar"
    case underline = "Underline"

    public var id: String { rawValue }

    var swiftTermStyle: CursorStyle {
        switch self {
        case .block: return .steadyBlock
        case .bar: return .steadyBar
        case .underline: return .steadyUnderline
        }
    }

    @MainActor func apply(to view: TerminalView) {
        view.getTerminal().setCursorStyle(swiftTermStyle)
    }
}
