import XCTest
@testable import Store

final class ProxyJumpResolverTests: XCTestCase {
    func testDirectHostReturnsEmptyChain() throws {
        let direct = Host(label: "direct", hostname: "10.0.0.10")
        let other = Host(label: "bastion", hostname: "bastion.example.com")

        let chain = try ProxyJumpResolver.resolveChain(for: direct, allHosts: [direct, other])
        XCTAssertTrue(chain.isEmpty)

        // Direct host succeeds even if maxHops is 0.
        let zeroHopsChain = try ProxyJumpResolver.resolveChain(for: direct, allHosts: [direct], maxHops: 0)
        XCTAssertTrue(zeroHopsChain.isEmpty)
    }

    func testSingleHopBastion() throws {
        let bastion = Host(label: "bastion", hostname: "bastion.example.com")
        let target = Host(label: "app", hostname: "10.0.1.5", proxyJumpHostID: bastion.id)

        let chain = try ProxyJumpResolver.resolveChain(for: target, allHosts: [target, bastion])
        XCTAssertEqual(chain.map(\.id), [bastion.id])
    }

    func testTwoHopChainedBastionOutermostFirstOrder() throws {
        let outer = Host(label: "outer-bastion", hostname: "edge.example.com")
        let inner = Host(label: "inner-jump", hostname: "10.0.0.2", proxyJumpHostID: outer.id)
        let target = Host(label: "db", hostname: "10.0.2.50", proxyJumpHostID: inner.id)

        let chain = try ProxyJumpResolver.resolveChain(for: target, allHosts: [target, inner, outer])
        XCTAssertEqual(chain.map(\.id), [outer.id, inner.id])
    }

    func testSelfCycleThrowsCycleDetected() {
        let selfID = UUID()
        let target = Host(id: selfID, label: "self", hostname: "10.0.0.1", proxyJumpHostID: selfID)

        XCTAssertThrowsError(try ProxyJumpResolver.resolveChain(for: target, allHosts: [target])) { error in
            XCTAssertEqual(error as? ProxyJumpError, .cycleDetected)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }

        // Also detected when target is absent from allHosts.
        XCTAssertThrowsError(try ProxyJumpResolver.resolveChain(for: target, allHosts: [])) { error in
            XCTAssertEqual(error as? ProxyJumpError, .cycleDetected)
        }
    }

    func testTwoNodeCycleThrowsCycleDetected() {
        let aID = UUID()
        let bID = UUID()
        let hostA = Host(id: aID, label: "a", hostname: "10.0.0.1", proxyJumpHostID: bID)
        let hostB = Host(id: bID, label: "b", hostname: "10.0.0.2", proxyJumpHostID: aID)

        XCTAssertThrowsError(try ProxyJumpResolver.resolveChain(for: hostA, allHosts: [hostA, hostB])) { error in
            XCTAssertEqual(error as? ProxyJumpError, .cycleDetected)
        }
    }

    func testIndirectCycleCheckedBeforeMaxHopsLimit() {
        let target = Host(label: "target", hostname: "10.0.0.3")
        let jump1 = Host(label: "jump1", hostname: "10.0.0.1")
        let jump2 = Host(label: "jump2", hostname: "10.0.0.2", proxyJumpHostID: jump1.id)
        target.proxyJumpHostID = jump2.id
        jump1.proxyJumpHostID = jump2.id

        XCTAssertThrowsError(
            try ProxyJumpResolver.resolveChain(for: target, allHosts: [target, jump1, jump2], maxHops: 2)
        ) { error in
            XCTAssertEqual(error as? ProxyJumpError, .cycleDetected)
        }
    }

    func testMissingJumpHostThrowsJumpHostNotFound() {
        let missingID = UUID()
        let target = Host(label: "orphan", hostname: "10.0.0.9", proxyJumpHostID: missingID)

        XCTAssertThrowsError(try ProxyJumpResolver.resolveChain(for: target, allHosts: [target])) { error in
            XCTAssertEqual(error as? ProxyJumpError, .jumpHostNotFound(missingID))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }

        let validJump = Host(label: "jump", hostname: "jump.example.com", proxyJumpHostID: missingID)
        let chained = Host(label: "chained", hostname: "10.0.0.10", proxyJumpHostID: validJump.id)
        XCTAssertThrowsError(
            try ProxyJumpResolver.resolveChain(for: chained, allHosts: [chained, validJump])
        ) { error in
            XCTAssertEqual(error as? ProxyJumpError, .jumpHostNotFound(missingID))
        }
    }

    func testMaxHopsBoundaryAndExceeded() throws {
        // Build a 6-hop chain: target -> j1 -> j2 -> j3 -> j4 -> j5 -> j6
        let j6 = Host(label: "j6", hostname: "j6.internal")
        let j5 = Host(label: "j5", hostname: "j5.internal", proxyJumpHostID: j6.id)
        let j4 = Host(label: "j4", hostname: "j4.internal", proxyJumpHostID: j5.id)
        let j3 = Host(label: "j3", hostname: "j3.internal", proxyJumpHostID: j4.id)
        let j2 = Host(label: "j2", hostname: "j2.internal", proxyJumpHostID: j3.id)
        let j1 = Host(label: "j1", hostname: "j1.internal", proxyJumpHostID: j2.id)
        let target = Host(label: "target", hostname: "target.internal", proxyJumpHostID: j1.id)
        let all = [target, j1, j2, j3, j4, j5, j6]

        // Default maxHops = 5 fails on 6-hop chain.
        XCTAssertThrowsError(try ProxyJumpResolver.resolveChain(for: target, allHosts: all)) { error in
            XCTAssertEqual(error as? ProxyJumpError, .maxHopsExceeded(5))
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }

        // Exact 5-hop chain (from j1 through j6) succeeds with default maxHops = 5.
        let fiveHops = try ProxyJumpResolver.resolveChain(for: j1, allHosts: all)
        XCTAssertEqual(fiveHops.map(\.id), [j6.id, j5.id, j4.id, j3.id, j2.id])

        // 6-hop chain succeeds when maxHops is raised to 6.
        let sixHops = try ProxyJumpResolver.resolveChain(for: target, allHosts: all, maxHops: 6)
        XCTAssertEqual(sixHops.map(\.id), [j6.id, j5.id, j4.id, j3.id, j2.id, j1.id])
    }
}
