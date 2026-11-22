import UIKit
import SwiftTerm

/// `inputAccessoryView` with Esc, sticky Ctrl/Alt, Tab, arrows, `|`, `~`, `/`.
///
/// Built from a `TerminalController`; the terminal view is resolved from the controller at tap time, so the
/// caller never handles it. Bytes go out through `controller.send`. Ctrl/Alt toggles also drive SwiftTerm's
/// `controlModifier`/`metaModifier`, so the next character typed on the software keyboard is modified;
/// SwiftTerm resets them after use and the bar follows (only for its own terminal view).
///
/// Each terminal needs its own bar: the bar's sticky state and application-cursor lookup belong to one
/// controller, so never share one instance between terminals.
@MainActor
public final class ExtraKeysBar: UIView {
    public private(set) var ctrlActive = false { didSet { ctrlButton.isSelected = ctrlActive } }
    public private(set) var altActive = false { didSet { altButton.isSelected = altActive } }

    private weak var controller: TerminalController?
    private let ctrlButton = UIButton(type: .system)
    private let altButton = UIButton(type: .system)
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []  // only touched in init and deinit

    public init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        backgroundColor = .secondarySystemBackground
        build()
        // The notification object is the terminal view that reset its modifier; the view only exists once
        // the controller is attached, so match it against the controller's view when the notification fires.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .terminalViewControlModifierReset, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let view = self.controller?.view, sender == ObjectIdentifier(view) else { return }
                self.ctrlActive = false
            }
        })
        observers.append(nc.addObserver(forName: .terminalViewMetaModifierReset, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let view = self.controller?.view, sender == ObjectIdentifier(view) else { return }
                self.altActive = false
            }
        })
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    public override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    private var terminal: TerminalView? { controller?.view }

    private func build() {
        // Horizontal scroll so 11 keys stay usable on a 375 pt phone; pinned to the safe area.
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillProportionally
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let guide = safeAreaLayoutGuide
        let content = scroll.contentLayoutGuide
        let frameGuide = scroll.frameLayoutGuide
        let fill = stack.widthAnchor.constraint(greaterThanOrEqualTo: frameGuide.widthAnchor, constant: -8)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: frameGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: frameGuide.bottomAnchor, constant: -4),
            content.heightAnchor.constraint(equalTo: frameGuide.heightAnchor),  // horizontal scrolling only
            fill,
        ])
        func key(_ title: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            configure(b, title: title, label: label)
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
        configure(ctrlButton, title: "Ctrl", label: "Control")
        ctrlButton.addAction(UIAction { [weak self] _ in self?.toggleCtrl() }, for: .touchUpInside)
        configure(altButton, title: "Alt", label: "Alt")
        altButton.addAction(UIAction { [weak self] _ in self?.toggleAlt() }, for: .touchUpInside)

        let views: [UIView] = [
            key("Esc", "Escape") { [weak self] in self?.emit(KeyEncoder.escape) },
            ctrlButton, altButton,
            key("Tab", "Tab") { [weak self] in self?.emit(KeyEncoder.tab) },
            key("←", "Left arrow") { [weak self] in self?.arrow(.left) },
            key("↓", "Down arrow") { [weak self] in self?.arrow(.down) },
            key("↑", "Up arrow") { [weak self] in self?.arrow(.up) },
            key("→", "Right arrow") { [weak self] in self?.arrow(.right) },
            key("|", "Pipe") { [weak self] in self?.type("|") },
            key("~", "Tilde") { [weak self] in self?.type("~") },
            key("/", "Slash") { [weak self] in self?.type("/") },
        ]
        views.forEach {
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            stack.addArrangedSubview($0)
        }
    }

    private func configure(_ b: UIButton, title: String, label: String) {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { c in
            var c = c
            c.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            return c
        }
        cfg.baseForegroundColor = .label
        cfg.baseBackgroundColor = .tertiarySystemFill
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        b.configuration = cfg
        b.accessibilityLabel = label
        b.configurationUpdateHandler = { button in
            button.configuration?.baseBackgroundColor = button.isSelected ? .tintColor : .tertiarySystemFill
            button.configuration?.baseForegroundColor = button.isSelected ? .white : .label
        }
    }

    private func toggleCtrl() {
        ctrlActive.toggle()
        terminal?.controlModifier = ctrlActive
    }

    private func toggleAlt() {
        altActive.toggle()
        terminal?.metaModifier = altActive
    }

    private func clearModifiers() {
        ctrlActive = false; altActive = false
        terminal?.controlModifier = false
        terminal?.metaModifier = false
    }

    private func emit(_ bytes: [UInt8]) {
        let out = altActive ? KeyEncoder.meta(bytes) : bytes
        clearModifiers()
        controller?.send(out)
    }

    private func type(_ s: String) {
        let out = KeyEncoder.text(s, ctrl: ctrlActive, alt: altActive)
        clearModifiers()
        controller?.send(out)
    }

    private func arrow(_ a: KeyEncoder.Arrow) {
        let app = terminal?.getTerminal().applicationCursor ?? false
        let out = KeyEncoder.arrow(a, applicationCursor: app, ctrl: ctrlActive, alt: altActive)
        clearModifiers()
        controller?.send(out)
    }
}
