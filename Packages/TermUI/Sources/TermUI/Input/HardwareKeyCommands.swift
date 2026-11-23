import UIKit

public extension Notification.Name {
    /// Posted for Cmd+T. The notification `object` is the window scene of the controller's terminal view
    /// (or `handle`'s `scope`); T8 observes per window with `object: windowScene`, so other iPad windows
    /// ignore it. If there is no scene the object is nil and only `object: nil` observers receive it.
    static let termNewTab = Notification.Name("TermUI.newTab")
    /// Posted for Cmd+W; `object` as for `termNewTab`.
    static let termCloseTab = Notification.Name("TermUI.closeTab")
    /// Posted for Cmd+1…9; `object` as for `termNewTab`; `userInfo["index"]` is the zero-based tab index (`Int`).
    static let termSwitchTab = Notification.Name("TermUI.switchTab")
}

/// `UIKeyCommand`s for the hardware-keyboard layer. Pass `commands` and `handle` to
/// `TerminalHostView(keyCommands:onKeyCommand:)`. Ctrl+letter and Alt-as-Meta come from SwiftTerm's own
/// hardware key handling (`optionAsMetaKey` defaults to true); `KeyEncoder` pins the expected bytes.
@MainActor
public enum HardwareKeyCommands {
    public static let tabIndexKey = "index"

    /// Builds the commands with `action` (use `TerminalHostView.keyCommandAction`).
    public static func commands(action: Selector) -> [UIKeyCommand] {
        func cmd(_ title: String, _ input: String, modifiers: UIKeyModifierFlags = .command) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        var list = [
            cmd("New Tab", "t"), cmd("Close Tab", "w"), cmd("Clear", "k"),
            cmd("Increase Font Size", "="),
            cmd("Increase Font Size", "+", modifiers: [.command, .shift]),
            cmd("Decrease Font Size", "-"),
        ]
        list += (1...9).map { cmd("Tab \($0)", String($0)) }
        return list
    }

    /// Runs the command. Tab actions post notifications whose object is the window scene of
    /// `controller`'s terminal view, so each window observes only its own (`object: scene`).
    /// `scope` overrides that object (tests). Cmd+K and font size call `controller`.
    public static func handle(_ command: UIKeyCommand, controller: TerminalController?, scope: AnyObject? = nil, center: NotificationCenter = .default) {
        guard let input = command.input else { return }
        let windowScene: AnyObject? = scope ?? controller?.view?.window?.windowScene
        switch (input, command.modifierFlags) {
        case ("t", .command): center.post(name: .termNewTab, object: windowScene)
        case ("w", .command): center.post(name: .termCloseTab, object: windowScene)
        case ("k", .command): controller?.clear()
        case ("=", .command), ("+", [.command, .shift]): controller?.increaseFont()
        case ("-", .command): controller?.decreaseFont()
        default:
            if command.modifierFlags == .command, let n = Int(input), (1...9).contains(n) {
                center.post(name: .termSwitchTab, object: windowScene, userInfo: [tabIndexKey: n - 1])
            }
        }
    }
}
