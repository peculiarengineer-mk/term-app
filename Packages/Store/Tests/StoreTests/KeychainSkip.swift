import XCTest
@testable import Store

/// Unhosted simulator package tests have no keychain entitlement at all (-34018 on every call).
/// Skip on that status. No hosted test target exists yet, so these round-trips are unverified until one is added (owner follow-up).
func skippingMissingEntitlement<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as KeychainError where e.status == errSecMissingEntitlement {
        throw XCTSkip("Keychain unavailable in unhosted package tests (errSecMissingEntitlement -34018)")
    }
}
