import XCTest
import UIKit
@testable import TermUI

final class KeyEncodingTests: XCTestCase {
    func testCtrlLetters() {
        for (i, ch) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            XCTAssertEqual(KeyEncoder.ctrl(ch), [UInt8(i + 1)])
            XCTAssertEqual(KeyEncoder.ctrl(Character(ch.lowercased())), [UInt8(i + 1)])
        }
        XCTAssertEqual(KeyEncoder.ctrl("["), [0x1b])
        let others: [(Character, UInt8)] = [("\\", 0x1c), ("]", 0x1d), ("^", 0x1e), ("_", 0x1f), ("/", 0x1f), ("?", 0x7f), ("@", 0x00), (" ", 0x00)]
        for (ch, b) in others { XCTAssertEqual(KeyEncoder.ctrl(ch), [b], "Ctrl+\(ch)") }
        XCTAssertEqual(KeyEncoder.text("/", ctrl: true), [0x1f])
        XCTAssertNil(KeyEncoder.ctrl("1"))
    }

    func testAltLetter() {
        XCTAssertEqual(KeyEncoder.meta(Array("b".utf8)), [0x1b, 0x62])
        XCTAssertEqual(KeyEncoder.text("f", alt: true), [0x1b, 0x66])
        XCTAssertEqual(KeyEncoder.text("c", ctrl: true), [0x03])
        XCTAssertEqual(KeyEncoder.text("c", ctrl: true, alt: true), [0x1b, 0x03])
    }

    func testArrowsNormalAndApplication() {
        let cases: [(KeyEncoder.Arrow, String)] = [(.up, "A"), (.down, "B"), (.right, "C"), (.left, "D")]
        for (a, l) in cases {
            XCTAssertEqual(KeyEncoder.arrow(a, applicationCursor: false), Array("\u{1b}[\(l)".utf8))
            XCTAssertEqual(KeyEncoder.arrow(a, applicationCursor: true), Array("\u{1b}O\(l)".utf8))
        }
        XCTAssertEqual(KeyEncoder.arrow(.left, applicationCursor: false, alt: true), [0x1b, 0x62])
        XCTAssertEqual(KeyEncoder.arrow(.right, applicationCursor: true, alt: true), [0x1b, 0x66])
        XCTAssertEqual(KeyEncoder.arrow(.up, applicationCursor: false, alt: true), Array("\u{1b}[A".utf8))  // SwiftTerm ignores Alt on Up/Down
        XCTAssertEqual(KeyEncoder.arrow(.down, applicationCursor: true, alt: true), Array("\u{1b}OB".utf8))
        XCTAssertEqual(KeyEncoder.arrow(.right, applicationCursor: false, ctrl: true, alt: true), Array("\u{1b}[1;7C".utf8))
        XCTAssertEqual(KeyEncoder.arrow(.right, applicationCursor: true, ctrl: true), Array("\u{1b}[1;5C".utf8))
    }

    func testEscAndTab() {
        XCTAssertEqual(KeyEncoder.escape, [0x1b])
        XCTAssertEqual(KeyEncoder.tab, [0x09])
    }

    @MainActor func testBarSendsBytes() {
        let io = RecordingIO()
        let controller = TerminalController()
        controller.io = io
        let bar = ExtraKeysBar(controller: controller)
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 44)
        bar.layoutIfNeeded()
        func tap(_ label: String) {
            func find(_ v: UIView) -> UIButton? {
                if let b = v as? UIButton, b.accessibilityLabel == label { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            find(bar)?.sendActions(for: .touchUpInside)
        }
        tap("Escape"); tap("Tab"); tap("Left arrow")
        tap("Control"); tap("Pipe")
        XCTAssertEqual(io.sent, [[0x1b], [0x09], [0x1b, 0x5b, 0x44], Array("|".utf8)])
    }

    @MainActor func testHardwareCommands() {
        var posted: [Notification.Name] = []
        let center = NotificationCenter()
        let tokens = [Notification.Name.termNewTab, .termCloseTab].map { n in
            center.addObserver(forName: n, object: nil, queue: nil) { posted.append($0.name) }
        }
        let other = NSObject(), mine = NSObject()
        var otherHeard = false, mineHeard = false
        let scoped = center.addObserver(forName: .termNewTab, object: other, queue: nil) { _ in otherHeard = true }
        let own = center.addObserver(forName: .termNewTab, object: mine, queue: nil) { _ in mineHeard = true }
        defer { center.removeObserver(scoped); center.removeObserver(own) }
        defer { tokens.forEach(center.removeObserver) }
        let cmds = HardwareKeyCommands.commands(action: #selector(NSObject.description))
        XCTAssertEqual(cmds.count, 15)
        HardwareKeyCommands.handle(cmds[0], controller: nil, center: center)
        HardwareKeyCommands.handle(cmds[1], controller: nil, center: center)
        XCTAssertEqual(posted, [.termNewTab, .termCloseTab])
        XCTAssertFalse(otherHeard)
        HardwareKeyCommands.handle(cmds[0], controller: nil, scope: mine, center: center)
        XCTAssertTrue(mineHeard, "a window observing its own scene hears its commands")
        XCTAssertFalse(otherHeard, "another window does not")

        let increasePlus = cmds.first { $0.input == "+" && $0.modifierFlags == [.command, .shift] }
        XCTAssertNotNil(increasePlus)
        let controller = TerminalController()
        if let increasePlus {
            HardwareKeyCommands.handle(increasePlus, controller: controller, center: center)
        }
        XCTAssertEqual(controller.fontSize, 15)
        if let decrease = cmds.first(where: { $0.input == "-" && $0.modifierFlags == .command }) {
            HardwareKeyCommands.handle(decrease, controller: controller, center: center)
        }
        XCTAssertEqual(controller.fontSize, 14)

        let wrongModifiers = UIKeyCommand(title: "Ignore", action: #selector(NSObject.description), input: "t", modifierFlags: [.command, .shift])
        HardwareKeyCommands.handle(wrongModifiers, controller: nil, center: center)
        XCTAssertEqual(posted, [.termNewTab, .termCloseTab])
    }

    @MainActor func testControllerFontSizeClamping() {
        let low = TerminalController(fontSize: 4)
        XCTAssertEqual(low.fontSize, TerminalController.minFontSize)
        low.decreaseFont()
        XCTAssertEqual(low.fontSize, TerminalController.minFontSize)

        let high = TerminalController(fontSize: 50)
        XCTAssertEqual(high.fontSize, TerminalController.maxFontSize)
        high.increaseFont()
        XCTAssertEqual(high.fontSize, TerminalController.maxFontSize)

        let normal = TerminalController(fontSize: 20)
        XCTAssertEqual(normal.fontSize, 20)
        normal.increaseFont()
        XCTAssertEqual(normal.fontSize, 21)
        normal.decreaseFont()
        XCTAssertEqual(normal.fontSize, 20)
    }

    @MainActor func testControllerOnFontSizeChange() {
        var reported: [CGFloat] = []
        let controller = TerminalController(fontSize: 14)
        controller.onFontSizeChange = { reported.append($0) }

        controller.increaseFont()
        controller.decreaseFont()
        XCTAssertEqual(reported, [15, 14])

        reported.removeAll()
        let atMin = TerminalController(fontSize: TerminalController.minFontSize)
        atMin.onFontSizeChange = { reported.append($0) }
        atMin.decreaseFont()
        XCTAssertTrue(reported.isEmpty, "onFontSizeChange must not fire when already at minFontSize")
        atMin.increaseFont()
        XCTAssertEqual(reported, [TerminalController.minFontSize + 1])

        reported.removeAll()
        let atMax = TerminalController(fontSize: TerminalController.maxFontSize)
        atMax.onFontSizeChange = { reported.append($0) }
        atMax.increaseFont()
        XCTAssertTrue(reported.isEmpty, "onFontSizeChange must not fire when already at maxFontSize")
        atMax.decreaseFont()
        XCTAssertEqual(reported, [TerminalController.maxFontSize - 1])
    }

    @MainActor func testBarHyphenPasteDismissAndTheme() {
        let io = RecordingIO()
        let controller = TerminalController()
        controller.io = io
        let bar = ExtraKeysBar(controller: controller)
        bar.hapticsEnabled = false
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 44)
        bar.layoutIfNeeded()

        func find(_ v: UIView, _ label: String) -> UIButton? {
            if let b = v as? UIButton, b.accessibilityLabel == label { return b }
            return v.subviews.lazy.compactMap { find($0, label) }.first
        }

        find(bar, "Hyphen")?.sendActions(for: .touchUpInside)
        find(bar, "Slash")?.sendActions(for: .touchUpInside)
        find(bar, "Tilde")?.sendActions(for: .touchUpInside)

        var dismissed = false
        bar.onDismissKeyboard = { dismissed = true }
        find(bar, "Dismiss Keyboard")?.sendActions(for: .touchUpInside)
        XCTAssertTrue(dismissed)

        let previousPasteboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previousPasteboard }
        UIPasteboard.general.string = "ls -la"
        find(bar, "Control")?.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.ctrlActive)
        find(bar, "Paste")?.sendActions(for: .touchUpInside)

        XCTAssertEqual(io.sent, [
            Array("-".utf8),
            Array("/".utf8),
            Array("~".utf8),
            Array("ls -la".utf8),
        ])

        bar.apply(theme: .tokyoNight)
        XCTAssertEqual(bar.backgroundColor, TerminalTheme.tokyoNight.background.uiColor)
        bar.apply(theme: .light)
        XCTAssertEqual(bar.backgroundColor, TerminalTheme.light.background.uiColor)
    }

    func testEncodedPasteAndInjectionPrevention() {
        XCTAssertEqual(ExtraKeysBar.encodedPaste("ls", bracketed: false), Array("ls".utf8))
        XCTAssertEqual(
            ExtraKeysBar.encodedPaste("ls", bracketed: true),
            Array("\u{1b}[200~ls\u{1b}[201~".utf8)
        )
        XCTAssertEqual(
            ExtraKeysBar.encodedPaste("echo hi\u{1b}[201~; rm -rf /", bracketed: true),
            Array("\u{1b}[200~echo hi; rm -rf /\u{1b}[201~".utf8)
        )
        XCTAssertEqual(
            ExtraKeysBar.encodedPaste("a\u{1b}[20\u{1b}[201~1~b", bracketed: true),
            Array("\u{1b}[200~ab\u{1b}[201~".utf8)
        )
        XCTAssertEqual(
            ExtraKeysBar.encodedPaste("a\u{1b}[201~b", bracketed: false),
            Array("a\u{1b}[201~b".utf8)
        )
    }

    @MainActor func testMultilinePasteRequiresConfirmation() {
        let io = RecordingIO()
        let controller = TerminalController()
        controller.io = io
        let bar = ExtraKeysBar(controller: controller)
        bar.hapticsEnabled = false
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 48)
        bar.layoutIfNeeded()

        func find(_ v: UIView, _ label: String) -> UIButton? {
            if let b = v as? UIButton, b.accessibilityLabel == label { return b }
            return v.subviews.lazy.compactMap { find($0, label) }.first
        }

        let previousPasteboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previousPasteboard }

        var capturedText: String?
        var pendingProceed: (@MainActor () -> Void)?
        bar.onConfirmMultilinePaste = { text, proceed in
            capturedText = text
            pendingProceed = proceed
        }

        UIPasteboard.general.string = "echo one\necho two"
        find(bar, "Paste")?.sendActions(for: .touchUpInside)
        XCTAssertEqual(capturedText, "echo one\necho two")
        XCTAssertTrue(io.sent.isEmpty, "multiline paste must wait for confirmation")

        pendingProceed?()
        XCTAssertEqual(io.sent, [Array("echo one\necho two".utf8)])

        capturedText = nil
        pendingProceed = nil
        UIPasteboard.general.string = "first\r\nsecond"
        find(bar, "Paste")?.sendActions(for: .touchUpInside)
        XCTAssertEqual(capturedText, "first\r\nsecond")
        XCTAssertEqual(io.sent.count, 1, "declined multiline paste must not send")
    }

    @MainActor func testDoubleTapCtrlAndAltLock() {
        let io = RecordingIO()
        let controller = TerminalController()
        controller.io = io
        let bar = ExtraKeysBar(controller: controller)
        bar.hapticsEnabled = false
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        bar.clock = { now }
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 48)
        bar.layoutIfNeeded()

        func tap(_ label: String) {
            func find(_ v: UIView) -> UIButton? {
                if let b = v as? UIButton, b.accessibilityLabel == label { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            find(bar)?.sendActions(for: .touchUpInside)
        }

        // Single tap past the 0.35s window toggles sticky off instead of locking.
        tap("Control")
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertFalse(bar.ctrlLocked)
        now = now.addingTimeInterval(0.5)
        tap("Control")
        XCTAssertFalse(bar.ctrlActive)
        XCTAssertFalse(bar.ctrlLocked)

        // Double tap within 0.35s locks Ctrl across multiple keypresses until tapped again.
        tap("Control")
        now = now.addingTimeInterval(0.15)
        tap("Control")
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertTrue(bar.ctrlLocked)

        tap("Slash")
        tap("Slash")
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertTrue(bar.ctrlLocked)
        XCTAssertEqual(io.sent, [[0x1f], [0x1f]])

        tap("Control")
        XCTAssertFalse(bar.ctrlActive)
        XCTAssertFalse(bar.ctrlLocked)
        tap("Slash")
        XCTAssertEqual(io.sent, [[0x1f], [0x1f], Array("/".utf8)])

        // Double tap Alt within 0.35s locks Alt across multiple keypresses until tapped again.
        tap("Alt")
        now = now.addingTimeInterval(0.15)
        tap("Alt")
        XCTAssertTrue(bar.altActive)
        XCTAssertTrue(bar.altLocked)

        tap("Pipe")
        tap("Hyphen")
        XCTAssertTrue(bar.altActive)
        XCTAssertTrue(bar.altLocked)

        tap("Alt")
        XCTAssertFalse(bar.altActive)
        XCTAssertFalse(bar.altLocked)
        tap("Pipe")

        XCTAssertEqual(io.sent, [
            [0x1f],
            [0x1f],
            Array("/".utf8),
            [0x1b] + Array("|".utf8),
            [0x1b] + Array("-".utf8),
            Array("|".utf8),
        ])
    }

    @MainActor func testExtraKeysBarErgonomicsArrowRepeatAndHostInit() {
        let io = RecordingIO()
        let controller = TerminalController()
        controller.io = io
        let bar = ExtraKeysBar(controller: controller)
        bar.frame = CGRect(x: 0, y: 0, width: 375, height: bar.intrinsicContentSize.height)
        bar.layoutIfNeeded()

        XCTAssertEqual(bar.intrinsicContentSize.height, 48)
        bar.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        bar.updateTraitsIfNeeded()
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.height, 56)

        func find(_ v: UIView, _ label: String) -> UIButton? {
            if let b = v as? UIButton, b.accessibilityLabel == label { return b }
            return v.subviews.lazy.compactMap { find($0, label) }.first
        }

        for arrowLabel in ["Left arrow", "Down arrow", "Up arrow", "Right arrow"] {
            let button = find(bar, arrowLabel)
            XCTAssertNotNil(button)
            XCTAssertGreaterThanOrEqual(button?.bounds.width ?? 0, 36)
            let longPress = button?.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first
            XCTAssertNotNil(longPress, "\(arrowLabel) should have long press auto-repeat")
            XCTAssertEqual(longPress?.minimumPressDuration ?? 0, 0.35, accuracy: 0.001)
        }

        let dismiss = find(bar, "Dismiss Keyboard")
        XCTAssertEqual(dismiss?.bounds.size, CGSize(width: 42, height: 38))

        // Backward-compatible default init and new autoFocus/hapticsEnabled options compile cleanly.
        _ = TerminalHostView(io: io)
        _ = TerminalHostView(io: io, autoFocus: false, hapticsEnabled: false)
    }

    @MainActor func testScrollFadeUpdatesOnLayoutAndScroll() {
        let controller = TerminalController()
        let bar = ExtraKeysBar(controller: controller)
        bar.frame = CGRect(x: 0, y: 0, width: 375, height: 48)
        bar.layoutIfNeeded()

        guard let scrollView = bar.subviews.compactMap({ $0 as? UIScrollView }).first,
              let mask = scrollView.layer.mask as? CAGradientLayer else {
            XCTFail("Expected UIScrollView with CAGradientLayer fade mask")
            return
        }

        XCTAssertGreaterThan(scrollView.contentSize.width, scrollView.bounds.width)
        XCTAssertEqual(mask.frame, scrollView.bounds)
        if let colors = mask.colors, let last = colors.last {
            let lastCG = last as! CGColor
            XCTAssertLessThan(lastCG.alpha, 0.1)
        } else {
            XCTFail("Expected fade mask gradient colors")
        }

        scrollView.contentOffset.x = scrollView.contentSize.width - scrollView.bounds.width
        bar.scrollViewDidScroll(scrollView)
        XCTAssertEqual(mask.frame, scrollView.bounds)
        if let colors = mask.colors, let last = colors.last {
            let lastCG = last as! CGColor
            XCTAssertEqual(lastCG.alpha, 1.0, accuracy: 0.001)
        } else {
            XCTFail("Expected fade mask gradient colors after scrolling to end")
        }
    }

    @MainActor func testBracketedPasteAndLockedModifierReArmWithHostTerminalView() {
        let io = RecordingIO()
        let controller = TerminalController()
        controller.io = io
        let view = HostTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { view.updateUiClosed() }
        controller.view = view

        let bar = ExtraKeysBar(controller: controller)
        bar.hapticsEnabled = false
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        bar.clock = { now }
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 48)
        bar.layoutIfNeeded()

        func find(_ v: UIView, _ label: String) -> UIButton? {
            if let b = v as? UIButton, b.accessibilityLabel == label { return b }
            return v.subviews.lazy.compactMap { find($0, label) }.first
        }

        // Enable DECSET 2004 (bracketed paste mode) on SwiftTerm and verify Paste wraps output.
        view.feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)

        let previousPasteboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previousPasteboard }
        UIPasteboard.general.string = "echo ok"
        find(bar, "Paste")?.sendActions(for: .touchUpInside)
        XCTAssertEqual(io.sent, [Array("\u{1b}[200~echo ok\u{1b}[201~".utf8)])

        // Double tap Ctrl to lock, simulate SwiftTerm resetting controlModifier, verify bar re-arms it.
        find(bar, "Control")?.sendActions(for: .touchUpInside)
        now = now.addingTimeInterval(0.1)
        find(bar, "Control")?.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.ctrlLocked)
        XCTAssertTrue(view.controlModifier)

        view.controlModifier = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertTrue(bar.ctrlLocked)
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertTrue(view.controlModifier)
    }

    @MainActor func testExtraKeysBarDefaultsToAppleProDarkAndKeycapShadows() {
        let controller = TerminalController()
        let bar = ExtraKeysBar(controller: controller)
        bar.hapticsEnabled = false
        bar.frame = CGRect(x: 0, y: 0, width: 800, height: 48)
        bar.layoutIfNeeded()

        XCTAssertEqual(bar.backgroundColor, TerminalTheme.appleProDark.background.uiColor)
        XCTAssertEqual(bar.tintColor, TerminalTheme.appleProDark.accentUIColor)

        func find(_ v: UIView, _ label: String) -> UIButton? {
            if let b = v as? UIButton, b.accessibilityLabel == label { return b }
            return v.subviews.lazy.compactMap { find($0, label) }.first
        }

        guard let escButton = find(bar, "Escape"), let ctrlButton = find(bar, "Control") else {
            XCTFail("Expected Escape and Control buttons")
            return
        }
        escButton.updateConfiguration()
        ctrlButton.updateConfiguration()

        XCTAssertEqual(escButton.configuration?.background.strokeWidth ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(escButton.layer.shadowOffset, CGSize(width: 0, height: 1))
        XCTAssertEqual(escButton.layer.shadowRadius, 0.5, accuracy: 0.001)
        XCTAssertEqual(escButton.layer.shadowOpacity, 0.35, accuracy: 0.001)
        XCTAssertEqual(escButton.layer.shadowColor, UIColor.black.cgColor)

        // Latched Ctrl keeps the glowing accent shadow.
        ctrlButton.sendActions(for: .touchUpInside)
        ctrlButton.updateConfiguration()
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertEqual(ctrlButton.layer.shadowOffset, .zero)
        XCTAssertEqual(ctrlButton.layer.shadowOpacity, 0.65, accuracy: 0.001)
        XCTAssertEqual(ctrlButton.layer.shadowColor, TerminalTheme.appleProDark.accentUIColor.cgColor)

        // Light theme softens normal keycap drop shadow opacity to 0.18.
        bar.apply(theme: .light)
        escButton.updateConfiguration()
        XCTAssertEqual(escButton.layer.shadowOpacity, 0.18, accuracy: 0.001)
        XCTAssertEqual(escButton.layer.shadowColor, UIColor.black.cgColor)
    }
}

/// Records bytes sent through a `TerminalController`. The lock makes the `Sendable` conformance real.
private final class RecordingIO: TerminalIO, @unchecked Sendable {  // @unchecked: state guarded by `lock`
    private let lock = NSLock()
    private var _sent: [[UInt8]] = []
    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _sent }
    func send(_ bytes: [UInt8]) { lock.lock(); _sent.append(bytes); lock.unlock() }
    func resized(cols: Int, rows: Int) {}
    var incoming: AsyncStream<Data> { AsyncStream { $0.finish() } }
}
