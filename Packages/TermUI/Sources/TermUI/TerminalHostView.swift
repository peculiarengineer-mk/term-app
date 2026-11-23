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
    public internal(set) var fontFamily: TerminalFontFamily
    public var onFontSizeChange: ((CGFloat) -> Void)?

    public init(fontSize: CGFloat = 14, fontFamily: TerminalFontFamily = .sfMono) {
        self.fontSize = Self.clampFontSize(fontSize)
        self.fontFamily = fontFamily
    }

    /// Clears the screen and scrollback locally (does not talk to the remote).
    public func clear() {
        view?.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
    }

    public func increaseFont() { setFontSize(fontSize + 1) }
    public func decreaseFont() { setFontSize(fontSize - 1) }

    /// Updates the active font family and applies it to the attached terminal view.
    public func setFontFamily(_ family: TerminalFontFamily) {
        fontFamily = family
        applyFont()
    }

    /// Dismisses the software keyboard by resigning first responder from the terminal view.
    public func dismissKeyboard() {
        _ = view?.resignFirstResponder()
    }

    /// Sends bytes to the remote side as if typed.
    public func send(_ bytes: [UInt8]) { io?.send(bytes) }

    static func clampFontSize(_ size: CGFloat) -> CGFloat {
        guard !size.isNaN else { return 14 }
        return min(max(size, minFontSize), maxFontSize)
    }

    func setFontSize(_ size: CGFloat, notify: Bool = true) {
        let clamped = Self.clampFontSize(size)
        let changed = clamped != fontSize
        fontSize = clamped
        applyFont()
        if changed && notify {
            onFontSizeChange?(clamped)
        }
    }

    private func applyFont() {
        let targetFont = fontFamily.uiFont(ofSize: fontSize)
        if view?.font != targetFont {
            view?.font = targetFont
        }
    }
}

/// TerminalView subclass that exposes extra key commands for the hardware-keyboard layer (T6) and pinch-to-zoom.
final class HostTerminalView: TerminalView {
    var extraKeyCommands: [UIKeyCommand] = []
    var keyCommandHandler: ((UIKeyCommand) -> Void)?
    var onPinchFontSize: ((CGFloat) -> Void)?
    var hapticsEnabled: Bool = true
    private var fontPinchGesture: UIPinchGestureRecognizer?
    private var pinchStartFontSize: CGFloat = 14
    private let selectionFeedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        installPinchGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installPinchGesture()
    }

    private func installPinchGesture() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        fontPinchGesture = pinch
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartFontSize = font.pointSize
            if hapticsEnabled {
                selectionFeedback.prepare()
            }
        case .changed:
            let scaled = pinchStartFontSize * gesture.scale
            let stepped = (scaled * 2).rounded() / 2
            let clamped = TerminalController.clampFontSize(stepped)
            guard clamped != font.pointSize else { return }
            if hapticsEnabled {
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }
            onPinchFontSize?(clamped)
        default:
            break
        }
    }

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
    private(set) var hasSizedLayout = false
    override func layoutSubviews() {
        super.layoutSubviews()
        // Wait for a grid larger than SwiftTerm's minimum, not just a non-zero frame.
        let t = getTerminal()
        if bounds.width > 0, bounds.height > 0, t.cols > 2, t.rows > 1 {
            hasSizedLayout = true
            if let start = onFirstSizedLayout {
                onFirstSizedLayout = nil
                start()
            }
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
    let fontSize: CGFloat?
    let fontFamily: TerminalFontFamily
    let cursorStyle: TerminalCursorStyle
    let controller: TerminalController?
    let accessoryView: UIView?
    let keyCommands: [UIKeyCommand]
    let autoFocus: Bool
    let hapticsEnabled: Bool
    let onKeyCommand: ((UIKeyCommand) -> Void)?
    let onFontSizeChange: ((CGFloat) -> Void)?

    public init(
        io: any TerminalIO,
        theme: TerminalTheme = .dark,
        fontSize: CGFloat? = nil,
        fontFamily: TerminalFontFamily = .sfMono,
        cursorStyle: TerminalCursorStyle = .block,
        controller: TerminalController? = nil,
        accessoryView: UIView? = nil,
        keyCommands: [UIKeyCommand] = [],
        autoFocus: Bool = true,
        hapticsEnabled: Bool = true,
        onKeyCommand: ((UIKeyCommand) -> Void)? = nil,
        onFontSizeChange: ((CGFloat) -> Void)? = nil
    ) {
        self.autoFocus = autoFocus
        self.hapticsEnabled = hapticsEnabled
        self.onKeyCommand = onKeyCommand
        self.onFontSizeChange = onFontSizeChange
        self.io = io; self.theme = theme; self.fontSize = fontSize
        self.fontFamily = fontFamily; self.cursorStyle = cursorStyle
        self.controller = controller; self.accessoryView = accessoryView; self.keyCommands = keyCommands
    }

    private var resolvedFontSize: CGFloat {
        TerminalController.clampFontSize(fontSize ?? controller?.fontSize ?? 14)
    }

    private func bindCallbacks(view: HostTerminalView, coordinator: Coordinator) {
        if let onFontSizeChange {
            controller?.onFontSizeChange = onFontSizeChange
        }
        let callback = onFontSizeChange
        let fallbackFamily = fontFamily
        view.onPinchFontSize = { [weak controller, weak view, weak coordinator] newSize in
            let clamped = TerminalController.clampFontSize(newSize)
            coordinator?.appliedFontSize = clamped
            if let controller {
                controller.setFontSize(clamped)
            } else {
                let targetFamily = coordinator?.appliedFontFamily ?? fallbackFamily
                view?.font = targetFamily.uiFont(ofSize: clamped)
                callback?(clamped)
            }
        }
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
        let initialFontSize = resolvedFontSize
        controller?.view = view
        controller?.io = io
        if let controller {
            controller.setFontFamily(fontFamily)
            controller.setFontSize(initialFontSize, notify: false)
        } else {
            view.font = fontFamily.uiFont(ofSize: initialFontSize)
        }
        theme.apply(to: view)
        cursorStyle.apply(to: view)
        view.inputAccessoryView = accessoryView
        view.extraKeyCommands = keyCommands
        view.keyCommandHandler = onKeyCommand
        view.hapticsEnabled = hapticsEnabled
        context.coordinator.appliedFontSize = initialFontSize
        context.coordinator.appliedFontFamily = fontFamily
        context.coordinator.appliedTheme = theme
        context.coordinator.appliedCursorStyle = cursorStyle
        bindCallbacks(view: view, coordinator: context.coordinator)
        if autoFocus {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil else { return }
                _ = view.becomeFirstResponder()
            }
        }
        return view
    }

    public func updateUIView(_ view: TerminalView, context: Context) {
        guard let view = view as? HostTerminalView else { return }
        let c = context.coordinator
        if c.io !== io {
            c.detach()
            c.io = io
            if view.hasSizedLayout {
                c.attach(view)
            }
        }
        controller?.view = view
        controller?.io = io
        if c.appliedTheme != theme {
            theme.apply(to: view)
            c.appliedTheme = theme
        }
        if c.appliedCursorStyle != cursorStyle {
            cursorStyle.apply(to: view)
            c.appliedCursorStyle = cursorStyle
        }
        if c.appliedFontFamily != fontFamily {
            if let controller {
                controller.setFontFamily(fontFamily)
            } else {
                view.font = fontFamily.uiFont(ofSize: resolvedFontSize)
            }
            c.appliedFontFamily = fontFamily
        }
        let targetFontSize = resolvedFontSize
        if c.appliedFontSize != targetFontSize {
            if let controller {
                controller.setFontSize(targetFontSize, notify: false)
            } else {
                view.font = fontFamily.uiFont(ofSize: targetFontSize)
            }
            c.appliedFontSize = targetFontSize
        }
        if view.inputAccessoryView !== accessoryView {
            view.inputAccessoryView = accessoryView
            if view.isFirstResponder { view.reloadInputViews() }
        }
        view.extraKeyCommands = keyCommands
        view.keyCommandHandler = onKeyCommand
        view.hapticsEnabled = hapticsEnabled
        bindCallbacks(view: view, coordinator: c)
    }

    public static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        if let host = view as? HostTerminalView {
            host.onFirstSizedLayout = nil  // a late layout must not attach after detach
            host.onPinchFontSize = nil
        }
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, TerminalViewDelegate {
        var io: any TerminalIO
        var appliedFontSize: CGFloat = 0
        var appliedFontFamily: TerminalFontFamily?
        var appliedTheme: TerminalTheme?
        var appliedCursorStyle: TerminalCursorStyle?
        private var pump: Task<Void, Never>?
        /// True while replayed output is being fed: the terminal's answers to queries in it
        /// (DA, DSR, OSC colour) were already sent by an earlier view and must not reach the remote again.
        private var replaying = false

        init(io: any TerminalIO) { self.io = io }

        func attach(_ view: TerminalView) {
            detach()
            let (replay, stream) = io.subscribe()
            if !replay.isEmpty {
                replaying = true
                view.feed(byteArray: [UInt8](replay)[...])
                replaying = false
            }
            pump = Task { @MainActor [weak view] in
                for await data in stream {
                    guard !Task.isCancelled, let view else { return }
                    view.feed(byteArray: [UInt8](data)[...])
                }
            }
        }

        func detach() { pump?.cancel(); pump = nil }

        public nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm calls delegates on the main thread, synchronously from `feed`.
            MainActor.assumeIsolated {
                if !replaying { io.send(Array(data)) }
            }
        }
        public nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                io.resized(cols: newCols, rows: newRows)
            }
        }
        public nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public nonisolated func scrolled(source: TerminalView, position: Double) {}
        public nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
        public nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            MainActor.assumeIsolated {
                guard !replaying else { return }
                UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
            }
        }
        public nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
