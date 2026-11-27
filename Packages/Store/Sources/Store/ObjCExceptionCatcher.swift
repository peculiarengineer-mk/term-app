import Foundation
internal import StoreObjC

/// Swift `Error` bridging a caught Objective-C `NSException`.
public struct ObjCExceptionError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let name: String
    public let reason: String?
    public let userInfoDescription: String?

    public init(name: String, reason: String?, userInfoDescription: String? = nil) {
        self.name = name
        self.reason = reason
        self.userInfoDescription = userInfoDescription
    }

    init(exception: NSException) {
        self.name = exception.name.rawValue
        self.reason = exception.reason
        if let userInfo = exception.userInfo, !userInfo.isEmpty {
            let formatted = userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            self.userInfoDescription = formatted
        } else {
            self.userInfoDescription = nil
        }
    }

    public var errorDescription: String? {
        if let reason, !reason.isEmpty {
            return "\(name): \(reason)"
        }
        return name
    }

    public var description: String {
        var parts = [name]
        if let reason, !reason.isEmpty {
            parts.append(reason)
        }
        if let userInfoDescription, !userInfoDescription.isEmpty {
            parts.append("userInfo: {\(userInfoDescription)}")
        }
        return parts.joined(separator: " — ")
    }
}

/// Runs `block` inside an Objective-C `@try/@catch` frame, converting any thrown `NSException`
/// into an `ObjCExceptionError` while preserving Swift errors and return values.
public func catchingObjCException<T>(_ block: () throws -> T) throws -> T {
    var outcome: Result<T, any Error>?
    if let exception = TermStoreCatchObjCException({
        do {
            outcome = .success(try block())
        } catch {
            outcome = .failure(error)
        }
    }) {
        throw ObjCExceptionError(exception: exception)
    }

    switch outcome {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    case nil:
        throw ObjCExceptionError(
            name: "UnknownObjCException",
            reason: "Objective-C try block exited without producing a result."
        )
    }
}
