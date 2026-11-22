import Foundation

public enum SSHError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case timeout
    case hostKeyRejected
    case authenticationFailed(String)
    case protocolError(code: Int, message: String)
    case channelFailed(String)
    case notConnected
    case closed
}
