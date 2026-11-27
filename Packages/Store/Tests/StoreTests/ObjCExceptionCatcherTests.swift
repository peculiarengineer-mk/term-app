import Foundation
import XCTest
@testable import Store

final class ObjCExceptionCatcherTests: XCTestCase {
    private enum SampleSwiftError: Error, Equatable {
        case expected(Int)
    }

    func testReturnsValueVoidAndOptionalNil() throws {
        let intValue = try catchingObjCException { 42 }
        XCTAssertEqual(intValue, 42)

        var executed = false
        try catchingObjCException {
            executed = true
        }
        XCTAssertTrue(executed)

        let optionalValue: Int? = try catchingObjCException { nil }
        XCTAssertNil(optionalValue)
    }

    func testPreservesThrownSwiftErrors() {
        XCTAssertThrowsError(try catchingObjCException {
            throw SampleSwiftError.expected(7)
        }) { error in
            XCTAssertEqual(error as? SampleSwiftError, .expected(7))
        }
    }

    func testCatchesNSExceptionAndExposesDiagnosticDetails() {
        XCTAssertThrowsError(try catchingObjCException {
            NSException(
                name: .internalInconsistencyException,
                reason: "Missing CloudKit container entitlement",
                userInfo: ["container": "iCloud.com.peculiarengineer.termapp"]
            ).raise()
        }) { error in
            guard let objcError = error as? ObjCExceptionError else {
                return XCTFail("Expected ObjCExceptionError, got \(error)")
            }
            XCTAssertEqual(objcError.name, NSExceptionName.internalInconsistencyException.rawValue)
            XCTAssertEqual(objcError.reason, "Missing CloudKit container entitlement")
            XCTAssertEqual(objcError.userInfoDescription, "container=iCloud.com.peculiarengineer.termapp")
            XCTAssertEqual(
                objcError.errorDescription,
                "\(NSExceptionName.internalInconsistencyException.rawValue): Missing CloudKit container entitlement"
            )
            XCTAssertTrue(objcError.description.contains("iCloud.com.peculiarengineer.termapp"))
        }
    }

    func testCatchesFoundationRuntimeObjCException() {
        let emptyArray = NSArray()
        XCTAssertThrowsError(try catchingObjCException {
            _ = emptyArray.object(at: 0)
        }) { error in
            guard let objcError = error as? ObjCExceptionError else {
                return XCTFail("Expected ObjCExceptionError, got \(error)")
            }
            XCTAssertEqual(objcError.name, NSExceptionName.rangeException.rawValue)
        }
    }

    func testObjCExceptionErrorWithoutReasonUsesName() {
        XCTAssertThrowsError(try catchingObjCException {
            NSException(name: NSExceptionName("CustomObjCException"), reason: nil, userInfo: nil).raise()
        }) { error in
            guard let objcError = error as? ObjCExceptionError else {
                return XCTFail("Expected ObjCExceptionError, got \(error)")
            }
            XCTAssertEqual(objcError.name, "CustomObjCException")
            XCTAssertNil(objcError.reason)
            XCTAssertNil(objcError.userInfoDescription)
            XCTAssertEqual(objcError.errorDescription, "CustomObjCException")
            XCTAssertEqual(objcError.description, "CustomObjCException")
        }
    }
}
