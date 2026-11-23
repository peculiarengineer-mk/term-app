import XCTest
import Foundation
import os
@testable import SSHKit

private func askOffActor(
    _ ctx: KbdContext,
    prompt: Prompt = Prompt(name: "Auth", instruction: "", items: [.init(text: "Code:", echo: false)]),
    timeout: DispatchTimeInterval = .seconds(5)
) async -> [String] {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            cont.resume(returning: ctx.ask(prompt, timeout: timeout))
        }
    }
}

final class KbdContextTests: XCTestCase {
    func testAskDeliversAnswersAndClearHandlerRemovesHandler() async {
        let ctx = KbdContext()
        ctx.setHandler { _ in ["answer-1"] }
        let first = await askOffActor(ctx)
        XCTAssertEqual(first, ["answer-1"])
        XCTAssertNotNil(ctx.lastAnswered())

        ctx.clearHandler()
        let second = await askOffActor(ctx)
        XCTAssertEqual(second, [])
    }

    func testAskTimeoutReturnsEmptyAndDoesNotRecordAnswer() async {
        let ctx = KbdContext()
        ctx.setHandler { _ in
            try? await Task.sleep(for: .seconds(5))
            return ["late"]
        }
        let start = ContinuousClock.now
        let answers = await askOffActor(ctx, timeout: .milliseconds(60))
        XCTAssertEqual(answers, [])
        XCTAssertNil(ctx.lastAnswered())
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testCancelUnblocksPendingAskAndClearsHandler() async throws {
        let ctx = KbdContext()
        ctx.setHandler { _ in
            try? await Task.sleep(for: .seconds(10))
            return ["late"]
        }
        let start = ContinuousClock.now
        let task = Task { await askOffActor(ctx, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(40))
        ctx.cancel()
        let answers = await task.value
        XCTAssertEqual(answers, [])
        XCTAssertNil(ctx.lastAnswered())
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))

        let afterCancel = await askOffActor(ctx)
        XCTAssertEqual(afterCancel, [])
    }

    func testMaxRoundsEnforced() async {
        let ctx = KbdContext()
        let invocations = OSAllocatedUnfairLock(initialState: 0)
        ctx.setHandler { _ in
            invocations.withLock { $0 += 1 }
            return ["ok"]
        }
        for round in 1...KbdContext.maxRounds {
            let res = await askOffActor(ctx)
            XCTAssertEqual(res, ["ok"], "round \(round) should succeed")
        }
        let overflow = await askOffActor(ctx)
        XCTAssertEqual(overflow, [])
        let total = invocations.withLock { $0 }
        XCTAssertEqual(total, KbdContext.maxRounds)
    }

    func testCopyUTF8ForLibSSH2PreservesEmbeddedNULs() {
        let (ptr, len) = SSHConnection.copyUTF8ForLibSSH2("ab\0cd")
        defer { free(ptr) }
        XCTAssertNotNil(ptr)
        XCTAssertEqual(len, 5)
        if let ptr {
            let bytes = (0..<Int(len)).map { UInt8(bitPattern: ptr[$0]) }
            XCTAssertEqual(bytes, [0x61, 0x62, 0x00, 0x63, 0x64])
        }

        let (emptyPtr, emptyLen) = SSHConnection.copyUTF8ForLibSSH2("")
        defer { free(emptyPtr) }
        XCTAssertNotNil(emptyPtr)
        XCTAssertEqual(emptyLen, 0)
    }
}
