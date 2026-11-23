import XCTest
import UIKit
import SwiftTerm
@testable import TermUI

final class TerminalAppearanceTests: XCTestCase {
    func testFontFamilyCasesAndUIFontResolution() {
        XCTAssertEqual(TerminalFontFamily.allCases, [.sfMono, .menlo, .courier])
        XCTAssertEqual(TerminalFontFamily.sfMono.rawValue, "SF Mono")
        XCTAssertEqual(TerminalFontFamily.menlo.rawValue, "Menlo")
        XCTAssertEqual(TerminalFontFamily.courier.rawValue, "Courier")

        for family in TerminalFontFamily.allCases {
            XCTAssertEqual(family.id, family.rawValue)
            let font = family.uiFont(ofSize: 16)
            XCTAssertEqual(font.pointSize, 16, accuracy: 0.01)
            XCTAssertTrue(
                font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
                "\(family.rawValue) should resolve to a monospace font"
            )
        }

        if let menlo = UIFont(name: "Menlo-Regular", size: 15) {
            XCTAssertEqual(TerminalFontFamily.menlo.uiFont(ofSize: 15).fontName, menlo.fontName)
        }
        if let courier = UIFont(name: "Courier", size: 15) {
            XCTAssertEqual(TerminalFontFamily.courier.uiFont(ofSize: 15).fontName, courier.fontName)
        }
    }

    func testCursorStyleCasesAndSwiftTermMapping() {
        XCTAssertEqual(TerminalCursorStyle.allCases, [.block, .bar, .underline])
        XCTAssertEqual(TerminalCursorStyle.block.rawValue, "Block")
        XCTAssertEqual(TerminalCursorStyle.bar.rawValue, "Bar")
        XCTAssertEqual(TerminalCursorStyle.underline.rawValue, "Underline")

        for style in TerminalCursorStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue)
        }

        XCTAssertEqual(TerminalCursorStyle.block.swiftTermStyle, .steadyBlock)
        XCTAssertEqual(TerminalCursorStyle.bar.swiftTermStyle, .steadyBar)
        XCTAssertEqual(TerminalCursorStyle.underline.swiftTermStyle, .steadyUnderline)
    }

    @MainActor func testCursorStyleAppliesToTerminalView() {
        let view = HostTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { view.updateUiClosed() }

        TerminalCursorStyle.bar.apply(to: view)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)

        TerminalCursorStyle.underline.apply(to: view)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyUnderline)

        TerminalCursorStyle.block.apply(to: view)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBlock)
    }

    @MainActor func testControllerFontFamilyAndHostViewCompatibility() {
        let io = StubIO()
        let controller = TerminalController(fontSize: 15)
        XCTAssertEqual(controller.fontFamily, .sfMono)

        let view = HostTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { view.updateUiClosed() }
        controller.view = view

        controller.setFontFamily(.menlo)
        XCTAssertEqual(controller.fontFamily, .menlo)
        XCTAssertEqual(view.font, TerminalFontFamily.menlo.uiFont(ofSize: 15))

        controller.increaseFont()
        XCTAssertEqual(controller.fontSize, 16)
        XCTAssertEqual(view.font, TerminalFontFamily.menlo.uiFont(ofSize: 16))

        _ = TerminalHostView(io: io)
        _ = TerminalHostView(
            io: io,
            theme: .appleProDark,
            fontSize: 14,
            fontFamily: .courier,
            cursorStyle: .bar,
            controller: controller
        )
    }
}

private final class StubIO: TerminalIO, @unchecked Sendable {
    func send(_ bytes: [UInt8]) {}
    func resized(cols: Int, rows: Int) {}
    var incoming: AsyncStream<Data> { AsyncStream { $0.finish() } }
}
