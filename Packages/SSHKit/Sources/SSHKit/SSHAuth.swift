import Foundation

public struct Prompt: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let text: String
        public let echo: Bool
        public init(text: String, echo: Bool) { self.text = text; self.echo = echo }
    }
    public let name: String
    public let instruction: String
    public let items: [Item]
    public init(name: String, instruction: String, items: [Item]) {
        self.name = name; self.instruction = instruction; self.items = items
    }
}

public enum SSHAuth: Sendable {
    case password(String)
    case privateKey(pem: Data, passphrase: String?)
    /// The handler receives one server prompt set and returns one answer per item.
    case keyboardInteractive(handler: @Sendable (Prompt) async -> [String])
}
