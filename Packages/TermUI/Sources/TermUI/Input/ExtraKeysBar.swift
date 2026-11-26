import UIKit
import SwiftTerm

/// `inputAccessoryView` with Esc, sticky/lockable Ctrl/Alt, Tab, auto-repeating arrows, `|`, `/`, `-`, `~`,
/// safe Paste (bracketed + multi-line guard), and Dismiss Keyboard.
///
/// Built from a `TerminalController`; the terminal view is resolved from the controller at tap time, so the
/// caller never handles it. Bytes go out through `controller.send`. Ctrl/Alt toggles also drive SwiftTerm's
/// `controlModifier`/`metaModifier`, so the next character typed on the software keyboard is modified;
/// SwiftTerm resets them after use and the bar follows (or re-arms them when locked).
///
/// Each terminal needs its own bar: the bar's modifier state and application-cursor lookup belong to one
/// controller, so never share one instance between terminals.
@MainActor
public final class ExtraKeysBar: UIView, UIScrollViewDelegate {
    private static let regularHeight: CGFloat = 48
    private static let accessibilityHeight: CGFloat = 56
    private static let minimumKeyWidth: CGFloat = 36
    private static let doubleTapWindow: TimeInterval = 0.35
    private static let arrowRepeatDelay: TimeInterval = 0.35
    private static let arrowRepeatInterval: TimeInterval = 0.08
    private static let scrollFadeWidth: CGFloat = 18

    public private(set) var ctrlActive = false {
        didSet { updateModifierButton(ctrlButton, active: ctrlActive, locked: ctrlLocked) }
    }
    public private(set) var ctrlLocked = false {
        didSet { updateModifierButton(ctrlButton, active: ctrlActive, locked: ctrlLocked) }
    }
    public private(set) var altActive = false {
        didSet { updateModifierButton(altButton, active: altActive, locked: altLocked) }
    }
    public private(set) var altLocked = false {
        didSet { updateModifierButton(altButton, active: altActive, locked: altLocked) }
    }

    public var onDismissKeyboard: (() -> Void)?
    public var onConfirmMultilinePaste: ((_ text: String, _ proceed: @escaping @MainActor () -> Void) -> Void)?
    public var hapticsEnabled: Bool = true
    var clock: () -> Date = Date.init
    var readPasteboard: @MainActor () -> String? = { UIPasteboard.general.string }

    private weak var controller: TerminalController?
    private var theme: TerminalTheme = .appleProDark
    private let scrollView = UIScrollView()
    private let scrollFadeMask = CAGradientLayer()
    private let ctrlButton = UIButton(type: .system)
    private let altButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let topDivider = UIView()
    private let trailingSeparator = UIView()
    private var styledButtons: [UIButton] = []
    private var lockDots: [ObjectIdentifier: UIView] = [:]
    private var lastCtrlTapTime: Date?
    private var lastAltTapTime: Date?
    private nonisolated(unsafe) var arrowRepeatTimer: Timer?
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationFeedback = UINotificationFeedbackGenerator()
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []  // only touched in init and deinit

    public init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.regularHeight))
        frame.size.height = currentBarHeight
        autoresizingMask = .flexibleWidth
        build()
        apply(theme: .appleProDark)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: ExtraKeysBar, _) in
            bar.preferredContentSizeDidChange()
        }
        // The notification object is the terminal view that reset its modifier; the view only exists once
        // the controller is attached, so match it against the controller's view when the notification fires.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .terminalViewControlModifierReset, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let view = self.controller?.view, sender == ObjectIdentifier(view) else { return }
                if self.ctrlLocked {
                    if !view.controlModifier { view.controlModifier = true }
                    self.ctrlActive = true
                } else if !view.controlModifier {
                    self.ctrlActive = false
                }
            }
        })
        observers.append(nc.addObserver(forName: .terminalViewMetaModifierReset, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let view = self.controller?.view, sender == ObjectIdentifier(view) else { return }
                if self.altLocked {
                    if !view.metaModifier { view.metaModifier = true }
                    self.altActive = true
                } else if !view.metaModifier {
                    self.altActive = false
                }
            }
        })
    }

    public convenience init(controller: TerminalController, theme: TerminalTheme) {
        self.init(controller: controller)
        apply(theme: theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        arrowRepeatTimer?.invalidate()
    }

    private var currentBarHeight: CGFloat {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? Self.accessibilityHeight : Self.regularHeight
    }

    public override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: currentBarHeight) }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopArrowRepeat()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.layoutIfNeeded()
        updateScrollFade()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollFade()
    }

    public func apply(theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = theme.background.uiColor
        tintColor = theme.accentUIColor
        let dividerColor = theme.hairlineDividerUIColor
        topDivider.backgroundColor = dividerColor
        trailingSeparator.backgroundColor = dividerColor
        styledButtons.forEach { $0.setNeedsUpdateConfiguration() }
    }

    /// Encodes pasted text for the terminal, wrapping in bracketed-paste markers (`ESC[200~` … `ESC[201~`) when
    /// `bracketed` is true. Embedded 7-bit (`ESC[200~`, `ESC[201~`) and 8-bit C1 (`0x9B 200~`, `0x9B 201~`)
    /// bracketed-paste markers are stripped repeatedly to prevent bracketed-paste escape injection.
    public nonisolated static func encodedPaste(_ text: String, bracketed: Bool) -> [UInt8] {
        guard bracketed else { return Array(text.utf8) }
        let startMarker = "\u{1b}[200~"
        let endMarker = "\u{1b}[201~"
        let forbiddenMarkers = [
            startMarker,
            endMarker,
            "\u{009b}200~",
            "\u{009b}201~",
        ]
        var sanitized = text
        var didStrip = true
        while didStrip {
            didStrip = false
            for marker in forbiddenMarkers where sanitized.range(of: marker, options: .literal) != nil {
                sanitized = sanitized.replacingOccurrences(of: marker, with: "", options: .literal)
                didStrip = true
            }
        }
        return Array((startMarker + sanitized + endMarker).utf8)
    }

    private var terminal: TerminalView? { controller?.view }

    private func preferredContentSizeDidChange() {
        frame.size.height = currentBarHeight
        invalidateIntrinsicContentSize()
        styledButtons.forEach { $0.setNeedsUpdateConfiguration() }
        setNeedsLayout()
    }

    private func build() {
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        trailingSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingSeparator)

        configure(dismissButton, title: nil, symbolName: "keyboard.chevron.compact.down", label: "Dismiss Keyboard")
        dismissButton.addAction(UIAction { [weak self] _ in self?.dismissKeyboardTapped() }, for: .touchUpInside)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dismissButton)

        // Horizontal scroll so keys stay usable on a 375 pt phone while Dismiss stays pinned on the trailing edge.
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        scrollFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        scrollFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.layer.mask = scrollFadeMask

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillProportionally
        stack.spacing = 5
        stack.clipsToBounds = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let guide = safeAreaLayoutGuide
        let content = scrollView.contentLayoutGuide
        let frameGuide = scrollView.frameLayoutGuide
        let fill = stack.widthAnchor.constraint(greaterThanOrEqualTo: frameGuide.widthAnchor, constant: -12)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: topAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            dismissButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 42),
            dismissButton.heightAnchor.constraint(equalToConstant: 38),

            trailingSeparator.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -6),
            trailingSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingSeparator.widthAnchor.constraint(equalToConstant: 1),
            trailingSeparator.heightAnchor.constraint(equalToConstant: 22),

            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingSeparator.leadingAnchor, constant: -2),
            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: frameGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: frameGuide.bottomAnchor, constant: -4),
            content.heightAnchor.constraint(equalTo: frameGuide.heightAnchor),  // horizontal scrolling only
            fill,
        ])

        func key(_ title: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            configure(b, title: title, symbolName: nil, label: label)
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }

        func arrowKey(_ title: String, _ label: String, _ direction: KeyEncoder.Arrow) -> UIButton {
            let b = key(title, label) { [weak self] in self?.arrow(direction) }
            let longPress = ArrowLongPressGestureRecognizer(
                direction: direction,
                target: self,
                action: #selector(handleArrowLongPress(_:))
            )
            longPress.minimumPressDuration = Self.arrowRepeatDelay
            b.addGestureRecognizer(longPress)
            return b
        }

        func symbolKey(_ symbolName: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            configure(b, title: nil, symbolName: symbolName, label: label)
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }

        configure(ctrlButton, title: "Ctrl", symbolName: nil, label: "Control")
        ctrlButton.addAction(UIAction { [weak self] _ in self?.toggleCtrl() }, for: .touchUpInside)
        installLockDot(on: ctrlButton)

        configure(altButton, title: "Alt", symbolName: nil, label: "Alt")
        altButton.addAction(UIAction { [weak self] _ in self?.toggleAlt() }, for: .touchUpInside)
        installLockDot(on: altButton)

        let views: [UIButton] = [
            key("Esc", "Escape") { [weak self] in self?.emit(KeyEncoder.escape) },
            ctrlButton,
            altButton,
            key("Tab", "Tab") { [weak self] in self?.emit(KeyEncoder.tab) },
            arrowKey("←", "Left arrow", .left),
            arrowKey("↓", "Down arrow", .down),
            arrowKey("↑", "Up arrow", .up),
            arrowKey("→", "Right arrow", .right),
            key("|", "Pipe") { [weak self] in self?.type("|") },
            key("/", "Slash") { [weak self] in self?.type("/") },
            key("-", "Hyphen") { [weak self] in self?.type("-") },
            key("~", "Tilde") { [weak self] in self?.type("~") },
            symbolKey("doc.on.clipboard", "Paste") { [weak self] in self?.pasteTapped() },
        ]
        views.forEach {
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumKeyWidth).isActive = true
            stack.addArrangedSubview($0)
        }
    }

    private func installLockDot(on button: UIButton) {
        let dot = UIView()
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        dot.layer.cornerRadius = 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 4),
            dot.heightAnchor.constraint(equalToConstant: 4),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
        ])
        lockDots[ObjectIdentifier(button)] = dot
    }

    private func isModifierLocked(for button: UIButton) -> Bool {
        if button === ctrlButton { return ctrlLocked }
        if button === altButton { return altLocked }
        return false
    }

    private func updateModifierButton(_ button: UIButton, active: Bool, locked: Bool) {
        button.isSelected = active
        button.accessibilityValue = locked ? "Locked" : (active ? "Active" : "Off")
        button.setNeedsUpdateConfiguration()
    }

    private func configure(_ b: UIButton, title: String?, symbolName: String?, label: String) {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        if let symbolName {
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            cfg.image = UIImage(systemName: symbolName, withConfiguration: symbolConfig)
        }
        cfg.cornerStyle = .fixed
        cfg.background.cornerRadius = 7
        cfg.background.strokeWidth = 0.5
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak self] c in
            var c = c
            let isAccessibility = self?.traitCollection.preferredContentSizeCategory.isAccessibilityCategory == true
            c.font = UIFont.monospacedSystemFont(ofSize: isAccessibility ? 15 : 13, weight: .semibold)
            return c
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7)
        b.configuration = cfg
        b.accessibilityLabel = label
        b.clipsToBounds = false
        b.layer.masksToBounds = false
        b.configurationUpdateHandler = { [weak self] button in
            guard let self, var config = button.configuration else { return }
            let theme = self.theme
            let accent = theme.accentUIColor
            let locked = self.isModifierLocked(for: button)
            let dot = self.lockDots[ObjectIdentifier(button)]
            dot?.isHidden = !locked
            dot?.backgroundColor = theme.accentForegroundUIColor

            if button.isSelected {
                config.baseBackgroundColor = accent
                config.baseForegroundColor = theme.accentForegroundUIColor
                if locked {
                    config.background.strokeColor = theme.background.uiColor
                    config.background.strokeWidth = 1.5
                    button.layer.borderWidth = 1.5
                    button.layer.borderColor = accent.cgColor
                    button.layer.cornerRadius = 7
                    button.layer.shadowOpacity = 0.85
                    button.layer.shadowRadius = 5
                } else {
                    config.background.strokeColor = accent
                    config.background.strokeWidth = 0.75
                    button.layer.borderWidth = 0
                    button.layer.borderColor = nil
                    button.layer.shadowOpacity = 0.65
                    button.layer.shadowRadius = 4
                }
                button.layer.shadowColor = accent.cgColor
                button.layer.shadowOffset = .zero
            } else {
                config.baseBackgroundColor = theme.elevatedSurfaceUIColor(highlighted: button.isHighlighted)
                config.baseForegroundColor = theme.foreground.uiColor
                config.background.strokeColor = theme.hairlineDividerUIColor
                config.background.strokeWidth = 0.5
                button.layer.borderWidth = 0
                button.layer.borderColor = nil
                button.layer.shadowColor = UIColor.black.cgColor
                button.layer.shadowOffset = CGSize(width: 0, height: 1)
                button.layer.shadowRadius = 0.5
                button.layer.shadowOpacity = theme.isDark ? 0.35 : 0.18
            }
            button.configuration = config
        }
        styledButtons.append(b)
    }

    private func updateScrollFade() {
        let bounds = scrollView.bounds
        guard bounds.width > 0 else { return }

        let remaining = scrollView.contentSize.width - (scrollView.contentOffset.x + bounds.width)
        let fadeProgress = remaining > 1 ? min(1, max(0, remaining / Self.scrollFadeWidth)) : 0
        let trailingAlpha = 1 - fadeProgress
        let fadeStart = max(0, 1 - (Self.scrollFadeWidth / bounds.width))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollFadeMask.frame = bounds
        scrollFadeMask.locations = [0, NSNumber(value: Double(fadeStart)), 1]
        scrollFadeMask.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.black.withAlphaComponent(trailingAlpha).cgColor,
        ]
        CATransaction.commit()
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard hapticsEnabled else { return }
        switch style {
        case .medium:
            mediumImpact.impactOccurred()
        case .heavy:
            heavyImpact.impactOccurred()
        default:
            lightImpact.impactOccurred()
        }
    }

    private func updateModifier(
        active: ReferenceWritableKeyPath<ExtraKeysBar, Bool>,
        locked: ReferenceWritableKeyPath<ExtraKeysBar, Bool>,
        lastTap: ReferenceWritableKeyPath<ExtraKeysBar, Date?>,
        syncTerminal: (Bool) -> Void
    ) {
        let timestamp = clock()
        if self[keyPath: locked] {
            self[keyPath: locked] = false
            self[keyPath: active] = false
            self[keyPath: lastTap] = nil
            syncTerminal(false)
            triggerHaptic(.medium)
        } else if self[keyPath: active], let previous = self[keyPath: lastTap],
                  timestamp.timeIntervalSince(previous) <= Self.doubleTapWindow {
            self[keyPath: locked] = true
            self[keyPath: active] = true
            self[keyPath: lastTap] = nil
            syncTerminal(true)
            triggerHaptic(.heavy)
        } else {
            let next = !self[keyPath: active]
            self[keyPath: active] = next
            self[keyPath: lastTap] = next ? timestamp : nil
            syncTerminal(next)
            triggerHaptic(.medium)
        }
    }

    private func toggleCtrl() {
        updateModifier(active: \.ctrlActive, locked: \.ctrlLocked, lastTap: \.lastCtrlTapTime) { [weak self] active in
            self?.terminal?.controlModifier = active
        }
    }

    private func toggleAlt() {
        updateModifier(active: \.altActive, locked: \.altLocked, lastTap: \.lastAltTapTime) { [weak self] active in
            self?.terminal?.metaModifier = active
        }
    }

    private func clearModifiers() {
        if ctrlLocked {
            ctrlActive = true
            if let terminal, !terminal.controlModifier {
                terminal.controlModifier = true
            }
        } else {
            ctrlActive = false
            lastCtrlTapTime = nil
            terminal?.controlModifier = false
        }
        if altLocked {
            altActive = true
            if let terminal, !terminal.metaModifier {
                terminal.metaModifier = true
            }
        } else {
            altActive = false
            lastAltTapTime = nil
            terminal?.metaModifier = false
        }
    }

    private func emit(_ bytes: [UInt8]) {
        triggerHaptic(.light)
        let out = altActive ? KeyEncoder.meta(bytes) : bytes
        clearModifiers()
        controller?.send(out)
    }

    private func type(_ s: String) {
        triggerHaptic(.light)
        let out = KeyEncoder.text(s, ctrl: ctrlActive, alt: altActive)
        clearModifiers()
        controller?.send(out)
    }

    private func arrow(_ a: KeyEncoder.Arrow) {
        triggerHaptic(.light)
        let app = terminal?.getTerminal().applicationCursor ?? false
        let out = KeyEncoder.arrow(a, applicationCursor: app, ctrl: ctrlActive, alt: altActive)
        clearModifiers()
        controller?.send(out)
    }

    @objc private func handleArrowLongPress(_ gesture: ArrowLongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopArrowRepeat()
            let direction = gesture.direction
            arrow(direction)
            let timer = Timer(timeInterval: Self.arrowRepeatInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.arrow(direction)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            arrowRepeatTimer = timer
        case .ended, .cancelled, .failed:
            stopArrowRepeat()
        default:
            break
        }
    }

    private func stopArrowRepeat() {
        arrowRepeatTimer?.invalidate()
        arrowRepeatTimer = nil
    }

    private func pasteTapped() {
        guard let text = readPasteboard(), !text.isEmpty else {
            if hapticsEnabled {
                notificationFeedback.notificationOccurred(.warning)
            }
            return
        }
        triggerHaptic(.light)

        let sendPaste: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let isBracketed = self.terminal?.getTerminal().bracketedPasteMode ?? false
            self.controller?.send(Self.encodedPaste(text, bracketed: isBracketed))
        }

        if text.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineCount = max(2, text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count)
            if let onConfirmMultilinePaste {
                onConfirmMultilinePaste(text, sendPaste)
            } else {
                presentMultilinePasteConfirmation(lineCount: lineCount, onConfirm: sendPaste)
            }
        } else {
            sendPaste()
        }
    }

    private func presentMultilinePasteConfirmation(lineCount: Int, onConfirm: @escaping @MainActor () -> Void) {
        guard let presenter = activeTopViewController() else { return }
        let alert = UIAlertController(
            title: "Paste Multiple Lines?",
            message: "This text contains \(lineCount) lines and may immediately execute commands in your shell.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Paste", style: .destructive) { _ in
            onConfirm()
        })
        presenter.present(alert, animated: true)
    }

    private func activeTopViewController() -> UIViewController? {
        let activeScene = window?.windowScene
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first

        let candidateWindows = activeScene?.windows ?? []
        let rootWindow = candidateWindows.first { $0.isKeyWindow && !$0.isHidden && $0.windowLevel == .normal }
            ?? candidateWindows.first { !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController != nil }
            ?? candidateWindows.first { $0.isKeyWindow && $0.rootViewController != nil }
            ?? window

        return topViewController(from: rootWindow?.rootViewController)
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        var current = root
        while let vc = current {
            if let presented = vc.presentedViewController, !presented.isBeingDismissed {
                current = presented
            } else if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
                current = visible
            } else if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
                current = selected
            } else {
                return (vc is UIAlertController) ? nil : vc
            }
        }
        return nil
    }

    private func dismissKeyboardTapped() {
        triggerHaptic(.light)
        if let onDismissKeyboard {
            onDismissKeyboard()
        } else {
            controller?.dismissKeyboard()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

private final class ArrowLongPressGestureRecognizer: UILongPressGestureRecognizer {
    let direction: KeyEncoder.Arrow

    init(direction: KeyEncoder.Arrow, target: Any?, action: Selector?) {
        self.direction = direction
        super.init(target: target, action: action)
    }
}
