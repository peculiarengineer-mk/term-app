import Foundation
import OSLog
import Security

/// Local-only Keychain store for the user's DigitalOcean personal access token.
/// Always persists with `synchronizable: false` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
/// so the token never syncs to iCloud Keychain or CloudKit.
public enum DigitalOceanTokenStore {
    public static let service = "termapp.digitalocean.token"
    public static let account = "pat"

    private static let logger = Logger(subsystem: "com.peculiarengineer.termapp", category: "digitalocean")

    /// Reads the locally stored DigitalOcean personal access token, if present and non-empty.
    public static func read(keychain: KeychainStore = KeychainStore()) -> String? {
        read(storage: keychain)
    }

    /// Reads the locally stored DigitalOcean personal access token, throwing on Keychain or UTF-8 decoding failures.
    public static func readToken(keychain: KeychainStore = KeychainStore()) throws -> String? {
        try readToken(storage: keychain)
    }

    /// Trims whitespace and stores the token locally (`synchronizable: false`).
    /// Throws `DOError.missingToken` if empty or `DOError.invalidToken` if it contains whitespace or control characters.
    public static func save(_ token: String, keychain: KeychainStore = KeychainStore()) throws {
        try save(token, storage: keychain)
    }

    /// Removes the stored DigitalOcean personal access token from the Keychain.
    public static func delete(keychain: KeychainStore = KeychainStore()) throws {
        try delete(storage: keychain)
    }

    /// Whether a non-empty DigitalOcean personal access token is currently stored locally.
    public static var hasToken: Bool {
        read() != nil
    }

    internal static func read(storage: any KeychainStoring) -> String? {
        do {
            return try readToken(storage: storage)
        } catch {
            logger.error("Failed to read DigitalOcean token from Keychain: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    internal static func readToken(storage: any KeychainStoring) throws -> String? {
        guard let data = try storage.read(service: service, account: account, synchronizable: false) else {
            return nil
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    internal static func save(_ token: String, storage: any KeychainStoring) throws {
        let trimmed = try DigitalOceanClient.validatedToken(token)
        try storage.save(Data(trimmed.utf8), service: service, account: account, synchronizable: false)
    }

    internal static func delete(storage: any KeychainStoring) throws {
        try storage.delete(service: service, account: account)
    }

    internal static func hasToken(storage: any KeychainStoring) -> Bool {
        read(storage: storage) != nil
    }
}

/// Errors produced by `DigitalOceanClient` and `DigitalOceanTokenStore`.
public enum DOError: Error, Equatable, Sendable, LocalizedError {
    case missingToken
    case invalidToken
    case unauthorized
    case httpError(Int, String)
    case invalidResponse
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "DigitalOcean API token is missing."
        case .invalidToken:
            return "DigitalOcean API token contains invalid whitespace or control characters."
        case .unauthorized:
            return "DigitalOcean API token is invalid or unauthorized (401)."
        case .httpError(let statusCode, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "DigitalOcean API error (HTTP \(statusCode))."
                : "DigitalOcean API error (HTTP \(statusCode)): \(trimmed)"
        case .invalidResponse:
            return "Received an invalid response from the DigitalOcean API."
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

/// Supported power and lifecycle actions for a DigitalOcean droplet.
public enum DODropletActionType: String, Codable, Equatable, CaseIterable, Sendable {
    case powerOn = "power_on"
    case powerOff = "power_off"
    case shutdown = "shutdown"
    case reboot = "reboot"
}

/// A DigitalOcean droplet decoded from REST API v2 payloads or flat cached JSON.
public struct DODroplet: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public var name: String
    public var status: String
    public var memory: Int
    public var vcpus: Int
    public var disk: Int
    public var regionSlug: String
    public var regionName: String
    public var sizeSlug: String
    /// Combined distribution and image name (e.g. `"Ubuntu 24.04 (LTS) x64"`) when decoded from API v2 JSON.
    public var imageName: String
    public var publicIPv4: String?
    public var privateIPv4: String?
    public var tags: [String]
    public var createdAt: String?

    public init(
        id: Int,
        name: String,
        status: String,
        memory: Int,
        vcpus: Int,
        disk: Int,
        regionSlug: String,
        regionName: String,
        sizeSlug: String,
        imageName: String,
        publicIPv4: String? = nil,
        privateIPv4: String? = nil,
        tags: [String] = [],
        createdAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.memory = memory
        self.vcpus = vcpus
        self.disk = disk
        self.regionSlug = regionSlug
        self.regionName = regionName
        self.sizeSlug = sizeSlug
        self.imageName = imageName
        self.publicIPv4 = publicIPv4
        self.privateIPv4 = privateIPv4
        self.tags = tags
        self.createdAt = createdAt
    }

    public var isActive: Bool {
        status.lowercased() == "active"
    }

    /// Concise hardware and location summary, e.g. `"1 vCPU · 1 GB · nyc3"`.
    public var specsSummary: String {
        let cpuText = vcpus == 1 ? "1 vCPU" : "\(vcpus) vCPUs"
        let memoryText: String
        if memory < 1024 {
            memoryText = "\(memory) MB"
        } else if memory % 1024 == 0 {
            memoryText = "\(memory / 1024) GB"
        } else {
            let gb = Double(memory) / 1024.0
            memoryText = String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), gb)
        }
        return [cpuText, memoryText, regionSlug]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case memory
        case vcpus
        case disk
        case regionSlug
        case regionName
        case sizeSlug
        case imageName
        case publicIPv4
        case privateIPv4
        case tags
        case createdAt
        // DigitalOcean API v2 nested/snake_case keys
        case region
        case size
        case sizeSlugSnake = "size_slug"
        case image
        case networks
        case createdAtSnake = "created_at"
    }

    private struct APIRegionRef: Decodable {
        let slug: String?
        let name: String?
    }

    private struct APISizeRef: Decodable {
        let slug: String?
    }

    private struct APIImageRef: Decodable {
        let name: String?
        let distribution: String?
        let slug: String?
    }

    private struct APINetworks: Decodable {
        struct IPv4: Decodable {
            let ipAddress: String
            let type: String

            enum CodingKeys: String, CodingKey {
                case ipAddress = "ip_address"
                case type
            }
        }

        let v4: [IPv4]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        memory = try container.decode(Int.self, forKey: .memory)
        vcpus = try container.decode(Int.self, forKey: .vcpus)
        disk = try container.decode(Int.self, forKey: .disk)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []

        // Flat Codable representation written by `encode(to:)`.
        if container.contains(.regionSlug) {
            regionSlug = try container.decode(String.self, forKey: .regionSlug)
            regionName = try container.decode(String.self, forKey: .regionName)
            sizeSlug = try container.decode(String.self, forKey: .sizeSlug)
            imageName = try container.decode(String.self, forKey: .imageName)
            publicIPv4 = try container.decodeIfPresent(String.self, forKey: .publicIPv4)
            privateIPv4 = try container.decodeIfPresent(String.self, forKey: .privateIPv4)
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            return
        }

        // DigitalOcean REST API v2 JSON representation.
        let regionRef = try container.decodeIfPresent(APIRegionRef.self, forKey: .region)
        let resolvedRegionSlug = regionRef?.slug ?? ""
        regionSlug = resolvedRegionSlug
        regionName = regionRef?.name ?? resolvedRegionSlug

        if let slug = try container.decodeIfPresent(String.self, forKey: .sizeSlugSnake) {
            sizeSlug = slug
        } else {
            sizeSlug = try container.decodeIfPresent(APISizeRef.self, forKey: .size)?.slug ?? ""
        }

        let imageRef = try container.decodeIfPresent(APIImageRef.self, forKey: .image)
        imageName = Self.formatImageName(
            distribution: imageRef?.distribution,
            name: imageRef?.name,
            slug: imageRef?.slug
        )

        let networks = try container.decodeIfPresent(APINetworks.self, forKey: .networks)
        let v4Entries = networks?.v4 ?? []
        publicIPv4 = v4Entries.first { $0.type == "public" && !$0.ipAddress.isEmpty }?.ipAddress
        privateIPv4 = v4Entries.first { $0.type == "private" && !$0.ipAddress.isEmpty }?.ipAddress

        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encode(memory, forKey: .memory)
        try container.encode(vcpus, forKey: .vcpus)
        try container.encode(disk, forKey: .disk)
        try container.encode(regionSlug, forKey: .regionSlug)
        try container.encode(regionName, forKey: .regionName)
        try container.encode(sizeSlug, forKey: .sizeSlug)
        try container.encode(imageName, forKey: .imageName)
        try container.encodeIfPresent(publicIPv4, forKey: .publicIPv4)
        try container.encodeIfPresent(privateIPv4, forKey: .privateIPv4)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    private static func formatImageName(distribution: String?, name: String?, slug: String?) -> String {
        let dist = distribution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !dist.isEmpty && !rawName.isEmpty {
            if rawName.lowercased().hasPrefix(dist.lowercased()) {
                return rawName
            }
            return "\(dist) \(rawName)"
        }
        if !rawName.isEmpty { return rawName }
        if !rawSlug.isEmpty { return rawSlug }
        return dist
    }
}

/// An SSH public key registered with the user's DigitalOcean account.
public struct DOSSHKey: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public var name: String
    public var fingerprint: String
    public var publicKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fingerprint
        case publicKey = "public_key"
    }

    public init(id: Int, name: String, fingerprint: String, publicKey: String) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.publicKey = publicKey
    }
}

/// A DigitalOcean datacenter region.
public struct DORegion: Codable, Equatable, Sendable, Identifiable {
    public let slug: String
    public var name: String
    public var available: Bool

    public var id: String { slug }

    public init(slug: String, name: String, available: Bool = true) {
        self.slug = slug
        self.name = name
        self.available = available
    }
}

/// A DigitalOcean droplet size plan.
public struct DOSize: Codable, Equatable, Sendable, Identifiable {
    public let slug: String
    public var memory: Int
    public var vcpus: Int
    public var disk: Int
    public var priceMonthly: Double
    public var available: Bool

    public var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case memory
        case vcpus
        case disk
        case priceMonthly = "price_monthly"
        case available
    }

    public init(
        slug: String,
        memory: Int,
        vcpus: Int,
        disk: Int,
        priceMonthly: Double,
        available: Bool = true
    ) {
        self.slug = slug
        self.memory = memory
        self.vcpus = vcpus
        self.disk = disk
        self.priceMonthly = priceMonthly
        self.available = available
    }
}

/// A DigitalOcean OS distribution image.
public struct DOImage: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public var slug: String?
    public var name: String
    public var distribution: String

    public init(id: Int, slug: String? = nil, name: String, distribution: String) {
        self.id = id
        self.slug = slug
        self.name = name
        self.distribution = distribution
    }
}

/// Request payload for `POST /v2/droplets`.
public struct DOCreateDropletRequest: Codable, Equatable, Sendable {
    public var name: String
    public var region: String
    public var size: String
    public var image: String
    public var sshKeys: [Int]
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case region
        case size
        case image
        case sshKeys = "ssh_keys"
        case tags
    }

    public init(
        name: String,
        region: String,
        size: String,
        image: String,
        sshKeys: [Int] = [],
        tags: [String] = []
    ) {
        self.name = name
        self.region = region
        self.size = size
        self.image = image
        self.sshKeys = sshKeys
        self.tags = tags
    }
}

/// Async REST API v2 client for DigitalOcean.
public struct DigitalOceanClient: Sendable {
    public static let baseURL = URL(string: "https://api.digitalocean.com/v2")!
    private static let expectedHost = "api.digitalocean.com"
    private static let maxPaginationPages = 20
    private static let requestTimeoutSeconds: TimeInterval = 30

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Lists droplets on the account (`GET /droplets?per_page=100`), following pagination up to 20 pages.
    public func listDroplets() async throws -> [DODroplet] {
        try await sendPaginated(
            path: "droplets",
            queryItems: [URLQueryItem(name: "per_page", value: "100")],
            envelopeType: DropletsEnvelope.self
        )
    }

    /// Creates a new droplet (`POST /droplets`).
    public func createDroplet(_ request: DOCreateDropletRequest) async throws -> DODroplet {
        let bodyData = try encodeJSON(request)
        let response: DropletEnvelope = try await sendJSON(
            path: "droplets",
            method: "POST",
            bodyData: bodyData,
            responseType: DropletEnvelope.self
        )
        return response.droplet
    }

    /// Triggers a power or lifecycle action on a droplet (`POST /droplets/{id}/actions`).
    public func performAction(_ action: DODropletActionType, dropletID: Int) async throws {
        let bodyData = try encodeJSON(ActionBody(type: action.rawValue))
        try await sendVoid(
            path: "droplets/\(dropletID)/actions",
            method: "POST",
            bodyData: bodyData
        )
    }

    /// Destroys a droplet (`DELETE /droplets/{id}`).
    public func deleteDroplet(id: Int) async throws {
        try await sendVoid(path: "droplets/\(id)", method: "DELETE")
    }

    /// Lists SSH keys registered on the account (`GET /account/keys?per_page=100`), following pagination up to 20 pages.
    public func listSSHKeys() async throws -> [DOSSHKey] {
        try await sendPaginated(
            path: "account/keys",
            queryItems: [URLQueryItem(name: "per_page", value: "100")],
            envelopeType: SSHKeysEnvelope.self
        )
    }

    /// Registers a new SSH public key on the account (`POST /account/keys`).
    public func createSSHKey(name: String, publicKey: String) async throws -> DOSSHKey {
        let bodyData = try encodeJSON(CreateSSHKeyBody(name: name, publicKey: publicKey))
        let response: SSHKeyEnvelope = try await sendJSON(
            path: "account/keys",
            method: "POST",
            bodyData: bodyData,
            responseType: SSHKeyEnvelope.self
        )
        return response.sshKey
    }

    /// Lists available regions (`GET /regions?per_page=100`, filtered to `available == true`), following pagination up to 20 pages.
    public func listRegions() async throws -> [DORegion] {
        let regions = try await sendPaginated(
            path: "regions",
            queryItems: [URLQueryItem(name: "per_page", value: "100")],
            envelopeType: RegionsEnvelope.self
        )
        return regions.filter(\.available)
    }

    /// Lists available sizes sorted by monthly price (`GET /sizes?per_page=100`, filtered to `available == true`), following pagination up to 20 pages.
    public func listSizes() async throws -> [DOSize] {
        let sizes = try await sendPaginated(
            path: "sizes",
            queryItems: [URLQueryItem(name: "per_page", value: "100")],
            envelopeType: SizesEnvelope.self
        )
        return sizes
            .filter(\.available)
            .sorted { lhs, rhs in
                lhs.priceMonthly == rhs.priceMonthly
                    ? lhs.slug < rhs.slug
                    : lhs.priceMonthly < rhs.priceMonthly
            }
    }

    /// Lists distribution images (`GET /images?type=distribution&per_page=100`), following pagination up to 20 pages.
    public func listDistributionImages() async throws -> [DOImage] {
        try await sendPaginated(
            path: "images",
            queryItems: [
                URLQueryItem(name: "type", value: "distribution"),
                URLQueryItem(name: "per_page", value: "100"),
            ],
            envelopeType: ImagesEnvelope.self
        )
    }

    /// Destroys the droplet and forgets its cached TOFU host key so future IP reuse never false-alarms.
    public static func destroyDropletAndForgetHostKey(
        id: Int,
        ipv4: String?,
        port: Int = 22,
        client: DigitalOceanClient,
        knownHosts: KnownHostsStore = KnownHostsStore()
    ) async throws {
        try await destroyDropletAndForgetHostKey(
            id: id,
            ipv4: ipv4,
            port: port,
            client: client,
            hostKeyStore: knownHosts
        )
    }

    internal static func destroyDropletAndForgetHostKey(
        id: Int,
        ipv4: String?,
        port: Int = 22,
        client: DigitalOceanClient,
        hostKeyStore: any HostKeyForgetting
    ) async throws {
        try await client.deleteDroplet(id: id)
        if let host = ipv4?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            try? hostKeyStore.forget(host: host, port: port)
        }
    }

    // MARK: - Private HTTP Helpers

    internal static func validatedToken(_ rawToken: String) throws -> String {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DOError.missingToken
        }
        let hasInvalidScalar = trimmed.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
        guard !hasInvalidScalar else {
            throw DOError.invalidToken
        }
        return trimmed
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components?.path = Self.baseURL.path + normalizedPath
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw DOError.invalidResponse
        }
        return url
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        bodyData: Data? = nil
    ) throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        return try makeAuthorizedRequest(url: url, method: method, bodyData: bodyData)
    }

    private func makeAuthorizedRequest(
        url: URL,
        method: String = "GET",
        bodyData: Data? = nil
    ) throws -> URLRequest {
        let validatedToken = try Self.validatedToken(token)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("Bearer \(validatedToken)", forHTTPHeaderField: "Authorization")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData
        return request
    }

    private func validatedNextPageURL(_ raw: String?) throws -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == Self.expectedHost,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443
        else {
            throw DOError.invalidResponse
        }
        return url
    }

    private func encodeJSON<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(body)
        } catch {
            throw DOError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        if Task.isCancelled {
            throw CancellationError()
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw DOError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DOError.invalidResponse
        }

        if http.statusCode == 401 {
            throw DOError.unauthorized
        }

        guard (200..<300).contains(http.statusCode) else {
            throw DOError.httpError(http.statusCode, Self.extractErrorMessage(from: data, statusCode: http.statusCode))
        }

        return data
    }

    private func sendPaginated<Envelope: DOPaginatedEnvelope>(
        path: String,
        queryItems: [URLQueryItem] = [],
        envelopeType: Envelope.Type
    ) async throws -> [Envelope.Item] {
        var collected: [Envelope.Item] = []
        var nextURL: URL? = try makeURL(path: path, queryItems: queryItems)
        var seenURLs: Set<URL> = []

        for _ in 0..<Self.maxPaginationPages {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard let currentURL = nextURL, seenURLs.insert(currentURL).inserted else {
                break
            }
            let request = try makeAuthorizedRequest(url: currentURL)
            let data = try await send(request)
            let envelope: Envelope
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: data)
            } catch {
                throw DOError.invalidResponse
            }
            let pageItems = envelope.items
            collected.append(contentsOf: pageItems)

            guard !pageItems.isEmpty else {
                break
            }
            nextURL = try validatedNextPageURL(envelope.links?.pages?.next)
            if nextURL == nil {
                break
            }
        }

        return collected
    }

    private func sendJSON<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        bodyData: Data? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(path: path, queryItems: queryItems, method: method, bodyData: bodyData)
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DOError.invalidResponse
        }
    }

    private func sendVoid(
        path: String,
        method: String,
        bodyData: Data? = nil
    ) async throws {
        let request = try makeRequest(path: path, method: method, bodyData: bodyData)
        _ = try await send(request)
    }

    private static func extractErrorMessage(from data: Data, statusCode: Int) -> String {
        if let apiError = try? JSONDecoder().decode(APIErrorBody.self, from: data),
           let message = apiError.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }
}

// MARK: - Private API Envelopes & Request Bodies

private protocol DOPaginatedEnvelope: Decodable {
    associatedtype Item
    var items: [Item] { get }
    var links: DOLinks? { get }
}

private struct DOLinks: Decodable {
    let pages: DOPages?
}

private struct DOPages: Decodable {
    let next: String?
}

private struct DropletsEnvelope: DOPaginatedEnvelope {
    let droplets: [DODroplet]
    let links: DOLinks?
    var items: [DODroplet] { droplets }
}

private struct DropletEnvelope: Decodable {
    let droplet: DODroplet
}

private struct SSHKeysEnvelope: DOPaginatedEnvelope {
    let sshKeys: [DOSSHKey]
    let links: DOLinks?
    var items: [DOSSHKey] { sshKeys }

    enum CodingKeys: String, CodingKey {
        case sshKeys = "ssh_keys"
        case links
    }
}

private struct SSHKeyEnvelope: Decodable {
    let sshKey: DOSSHKey

    enum CodingKeys: String, CodingKey {
        case sshKey = "ssh_key"
    }
}

private struct RegionsEnvelope: DOPaginatedEnvelope {
    let regions: [DORegion]
    let links: DOLinks?
    var items: [DORegion] { regions }
}

private struct SizesEnvelope: DOPaginatedEnvelope {
    let sizes: [DOSize]
    let links: DOLinks?
    var items: [DOSize] { sizes }
}

private struct ImagesEnvelope: DOPaginatedEnvelope {
    let images: [DOImage]
    let links: DOLinks?
    var items: [DOImage] { images }
}

private struct ActionBody: Encodable {
    let type: String
}

private struct CreateSSHKeyBody: Encodable {
    let name: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case name
        case publicKey = "public_key"
    }
}

private struct APIErrorBody: Decodable {
    let id: String?
    let message: String?
}

internal protocol HostKeyForgetting: Sendable {
    func forget(host: String, port: Int) throws
}

extension KnownHostsStore: HostKeyForgetting {}
