import XCTest
import SwiftTerm
@testable import TermUI

private final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class TerminalReplayTests: XCTestCase {
    func testVimStartupReplay() throws {
        // Captured from `vim -u NONE -N -c 'set laststatus=2 ruler' t.txt` in an 80x24 xterm-256color pty.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/vim-startup.bin")
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertFalse(bytes.isEmpty)

        let delegate = NullDelegate()
        let term = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
        term.feed(byteArray: bytes)

        let cursor = term.getCursorLocation()
        XCTAssertEqual(cursor.x, 0)
        XCTAssertEqual(cursor.y, 0)

        let row1 = term.getText(start: Position(col: 0, row: 1), end: Position(col: 80, row: 1))
        XCTAssertTrue(row1.hasPrefix("~"), "row 1 was: \(row1)")

        // Status line is row 23 (1-based), i.e. index 22.
        let status = term.getText(start: Position(col: 0, row: 22), end: Position(col: 80, row: 22))
        XCTAssertTrue(status.hasPrefix("t.txt"), "status line was: \(status)")
        XCTAssertTrue(status.contains("0,0-1"), "status line was: \(status)")
        XCTAssertTrue(status.contains("All"), "status line was: \(status)")
    }

    func testThemesHaveSixteenColours() {
        XCTAssertEqual(TerminalTheme.dark.ansi.count, 16)
        XCTAssertEqual(TerminalTheme.light.ansi.count, 16)
    }
}
