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
        let others: [(Character, UInt8)] = [("\\", 0x1c), ("]", 0x1d), ("^", 0x1e), ("_", 0x1f), ("?", 0x7f), ("@", 0x00), (" ", 0x00)]
        for (ch, b) in others { XCTAssertEqual(KeyEncoder.ctrl(ch), [b], "Ctrl+\(ch)") }
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
        XCTAssertEqual(cmds.count, 14)
        HardwareKeyCommands.handle(cmds[0], controller: nil, center: center)
        HardwareKeyCommands.handle(cmds[1], controller: nil, center: center)
        XCTAssertEqual(posted, [.termNewTab, .termCloseTab])
        XCTAssertFalse(otherHeard)
        HardwareKeyCommands.handle(cmds[0], controller: nil, scope: mine, center: center)
        XCTAssertTrue(mineHeard, "a window observing its own scene hears its commands")
        XCTAssertFalse(otherHeard, "another window does not")
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
