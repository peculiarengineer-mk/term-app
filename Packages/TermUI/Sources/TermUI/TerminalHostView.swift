import SwiftUI
import UIKit
import SwiftTerm

/// Handle a parent keeps to drive the terminal from outside (toolbar buttons, shortcuts).
@MainActor
public final class TerminalController {
    public static let minFontSize: CGFloat = 8
    public static let maxFontSize: CGFloat = 32

    weak var view: HostTerminalView?
    weak var io: (any TerminalIO)?
    public internal(set) var fontSize: CGFloat

    public init(fontSize: CGFloat = 14) { self.fontSize = fontSize }

    /// Clears the screen and scrollback locally (does not talk to the remote).
    public func clear() {
        guard let t = view?.getTerminal() else { return }
        t.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
    }

    public func increaseFont() { setFontSize(fontSize + 1) }
    public func decreaseFont() { setFontSize(fontSize - 1) }

    /// Sends bytes to the remote side as if typed.
    public func send(_ bytes: [UInt8]) { io?.send(bytes) }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        fontSize = clamped
        view?.font = UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
    }
}

/// TerminalView subclass that exposes extra key commands for the hardware-keyboard layer (T6).
final class HostTerminalView: TerminalView {
    var extraKeyCommands: [UIKeyCommand] = []
    var keyCommandHandler: ((UIKeyCommand) -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        let base = super.keyCommands ?? []
        return extraKeyCommands.isEmpty ? super.keyCommands : base + extraKeyCommands
    }

    /// SwiftTerm's `canPerformAction` (not overridable) refuses every non-edit action, so UIKit passes
    /// the extra key commands up the responder chain. This responder sits right after the terminal
    /// in the chain and forwards them to the caller's handler.
    private lazy var commandResponder = KeyCommandResponder(owner: self)

    /// Called once, after the first layout that gives the terminal a real size.
    var onFirstSizedLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        // Wait for a grid larger than SwiftTerm's minimum, not just a non-zero frame.
        let t = getTerminal()
        if bounds.width > 0, bounds.height > 0, t.cols > 2, t.rows > 1, let start = onFirstSizedLayout {
            onFirstSizedLayout = nil
            start()
        }
    }
    override var next: UIResponder? { keyCommandHandler == nil ? super.next : commandResponder }
    fileprivate var superNext: UIResponder? { super.next }
}

/// Receives `TerminalHostView.keyCommandAction` and forwards it to `HostTerminalView.keyCommandHandler`.
final class KeyCommandResponder: UIResponder {
    private weak var owner: HostTerminalView?
    init(owner: HostTerminalView) { self.owner = owner }
    override var next: UIResponder? { owner?.superNext }

    @objc func handleExtraKeyCommand(_ command: UIKeyCommand) { owner?.keyCommandHandler?(command) }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleExtraKeyCommand(_:)) { return owner?.keyCommandHandler != nil }
        return super.canPerformAction(action, withSender: sender)
    }
}

public struct TerminalHostView: UIViewRepresentable {
    let io: any TerminalIO
    let theme: TerminalTheme
    let fontSize: CGFloat
    let controller: TerminalController?
    let accessoryView: UIView?
    let keyCommands: [UIKeyCommand]
    let onKeyCommand: ((UIKeyCommand) -> Void)?

    public init(
        io: any TerminalIO,
        theme: TerminalTheme = .dark,
        fontSize: CGFloat = 14,
        controller: TerminalController? = nil,
        accessoryView: UIView? = nil,
        keyCommands: [UIKeyCommand] = [],
        onKeyCommand: ((UIKeyCommand) -> Void)? = nil
    ) {
        self.onKeyCommand = onKeyCommand
        self.io = io; self.theme = theme; self.fontSize = fontSize
        self.controller = controller; self.accessoryView = accessoryView; self.keyCommands = keyCommands
    }

    /// Action selector callers must use when building `keyCommands`; it reaches `onKeyCommand`.
    public static var keyCommandAction: Selector { #selector(KeyCommandResponder.handleExtraKeyCommand(_:)) }

    public func makeCoordinator() -> Coordinator { Coordinator(io: io) }

    public func makeUIView(context: Context) -> TerminalView {
        let view = HostTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // Output (replay and live) starts only once the view is laid out at its real size with the
        // font and theme applied; fed at the initial 2x1 grid, replayed screens would be mangled.
        let coordinator = context.coordinator
        view.onFirstSizedLayout = { [weak view, weak coordinator] in
            if let view { coordinator?.attach(view) }
        }
        controller?.view = view
        controller?.io = io
        controller?.fontSize = fontSize
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        theme.apply(to: view)
        context.coordinator.appliedFontSize = fontSize
        context.coordinator.appliedThemeName = theme.name
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    public func updateUIView(_ view: TerminalView, context: Context) {
        guard let view = view as? HostTerminalView else { return }
        let c = context.coordinator
        if c.appliedThemeName != theme.name {
            theme.apply(to: view)
            c.appliedThemeName = theme.name
        }
        if c.appliedFontSize != fontSize {
            if let controller {
                controller.setFontSize(fontSize)
            } else {
                view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }
            c.appliedFontSize = fontSize
        }
        // Keep SwiftTerm's default accessory unless the caller supplies one.
        if let accessoryView, view.inputAccessoryView !== accessoryView {
            view.inputAccessoryView = accessoryView
            if view.isFirstResponder { view.reloadInputViews() }
        }
        view.extraKeyCommands = keyCommands
        view.keyCommandHandler = onKeyCommand
    }

    public static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        (view as? HostTerminalView)?.onFirstSizedLayout = nil  // a late layout must not attach after detach
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, TerminalViewDelegate {
        let io: any TerminalIO
        var appliedFontSize: CGFloat = 0
        var appliedThemeName = ""
        private var pump: Task<Void, Never>?
        /// True while replayed output is being fed: the terminal's answers to queries in it
        /// (DA, DSR, OSC colour) were already sent by an earlier view and must not reach the remote again.
        private var replaying = false

        init(io: any TerminalIO) { self.io = io }

        func attach(_ view: TerminalView) {
            let (replay, stream) = io.subscribe()
            if !replay.isEmpty {
                replaying = true
                view.feed(byteArray: [UInt8](replay)[...])
                replaying = false
            }
            pump = Task { @MainActor [weak view] in
                for await data in stream {
                    guard let view else { return }
                    view.feed(byteArray: [UInt8](data)[...])
                }
            }
        }

        func detach() { pump?.cancel(); pump = nil }

        public nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm calls delegates on the main thread, synchronously from `feed`.
            let drop = MainActor.assumeIsolated { replaying }
            if !drop { io.send(Array(data)) }
        }
        public nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            io.resized(cols: newCols, rows: newRows)
        }
        public nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public nonisolated func scrolled(source: TerminalView, position: Double) {}
        public nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), url.scheme == "https" || url.scheme == "http" else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
        public nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            let text = String(decoding: content, as: UTF8.self)
            MainActor.assumeIsolated { UIPasteboard.general.string = text }
        }
        public nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
