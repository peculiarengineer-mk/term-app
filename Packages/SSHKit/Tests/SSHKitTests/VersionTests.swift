import XCTest
@testable import SSHKit

final class VersionTests: XCTestCase {
    func testLibraryVersionIsAtLeast1_11() {
        let v = SSHKit.libraryVersion()
        let parts = v.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else {
            XCTFail("unparseable version: \(v)")
            return
        }
        XCTAssertTrue(parts[0] > 1 || (parts[0] == 1 && parts[1] >= 11), "libssh2 \(v) is older than 1.11")
    }
}
