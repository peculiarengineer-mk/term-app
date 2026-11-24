import Foundation
import Security

// MARK: - Local-Only Token Store

/// Stores the Cloudflare API token locally on this device (`synchronizable: false`, never synced to iCloud).
public enum CloudflareTokenStore {
    public static let service = "termapp.cloudflare.token"
    public static let account = "api-token"

    /// Reads the locally stored Cloudflare API token, or `nil` if missing or unreadable.
    public static func read(keychain: KeychainStore = KeychainStore()) -> String? {
        read(storage: keychain)
    }

    /// Trims whitespace and saves the Cloudflare API token locally (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
    public static func save(_ token: String, keychain: KeychainStore = KeychainStore()) throws {
        try save(token, storage: keychain)
    }

    /// Removes the stored Cloudflare API token from Keychain (idempotent).
    public static func delete(keychain: KeychainStore = KeychainStore()) throws {
        try delete(storage: keychain)
    }

    /// Whether a non-empty local Cloudflare API token is currently stored.
    public static var hasToken: Bool {
        read() != nil
    }

    internal static func read(storage: any KeychainStoring) -> String? {
        guard let data = try? storage.read(service: service, account: account, synchronizable: false),
              let raw = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    internal static func save(_ token: String, storage: any KeychainStoring) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CloudflareError.missingToken
        }
        try storage.save(Data(trimmed.utf8), service: service, account: account, synchronizable: false)
    }

    internal static func delete(storage: any KeychainStoring) throws {
        try storage.delete(service: service, account: account)
    }
}

// MARK: - Cloudflare API v4 Models

/// A Cloudflare account returned by `GET /accounts`.
public struct CFAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A Cloudflare DNS zone returned by `GET /zones`.
public struct CFZone: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var status: String
    public var accountID: String?

    public init(id: String, name: String, status: String, accountID: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.accountID = accountID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case account
        case accountIDSnake = "account_id"
        case accountIDCamel = "accountID"
    }

    private struct AccountRef: Codable {
        let id: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        if let account = try container.decodeIfPresent(AccountRef.self, forKey: .account) {
            accountID = account.id
        } else if let snake = try container.decodeIfPresent(String.self, forKey: .accountIDSnake) {
            accountID = snake
        } else {
            accountID = try container.decodeIfPresent(String.self, forKey: .accountIDCamel)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        if let accountID {
            try container.encode(AccountRef(id: accountID), forKey: .account)
        }
    }
}

/// A Cloudflare DNS record returned by `/zones/{zoneID}/dns_records`.
public struct CFDNSRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var zoneID: String
    public var type: String
    public var name: String
    public var content: String
    public var proxied: Bool
    public var ttl: Int
    public var comment: String?

    public init(
        id: String,
        zoneID: String,
        type: String,
        name: String,
        content: String,
        proxied: Bool = false,
        ttl: Int = 1,
        comment: String? = nil
    ) {
        self.id = id
        self.zoneID = zoneID
        self.type = type
        self.name = name
        self.content = content
        self.proxied = proxied
        self.ttl = ttl
        self.comment = comment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case zoneID = "zone_id"
        case zoneIDCamel = "zoneID"
        case type
        case name
        case content
        case proxied
        case ttl
        case comment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let snakeZone = try container.decodeIfPresent(String.self, forKey: .zoneID) {
            zoneID = snakeZone
        } else {
            zoneID = try container.decodeIfPresent(String.self, forKey: .zoneIDCamel) ?? ""
        }
        type = try container.decode(String.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        content = try container.decode(String.self, forKey: .content)
        proxied = try container.decodeIfPresent(Bool.self, forKey: .proxied) ?? false
        ttl = try container.decodeIfPresent(Int.self, forKey: .ttl) ?? 1
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(zoneID, forKey: .zoneID)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(content, forKey: .content)
        try container.encode(proxied, forKey: .proxied)
        try container.encode(ttl, forKey: .ttl)
        try container.encodeIfPresent(comment, forKey: .comment)
    }
}

/// Request payload for creating or updating a Cloudflare DNS record (`ttl = 1` means Auto).
public struct CFDNSRecordInput: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var name: String
    public var content: String
    public var proxied: Bool
    public var ttl: Int

    public init(
        type: String,
        name: String,
        content: String,
        proxied: Bool = false,
        ttl: Int = 1
    ) {
        self.type = type
        self.name = name
        self.content = content
        self.proxied = proxied
        self.ttl = ttl
    }
}

/// Health status of a Cloudflare Tunnel.
public enum CFTunnelStatus: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case healthy
    case degraded
    case inactive
    case down
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        self = CFTunnelStatus(rawValue: raw) ?? .unknown
    }
}

/// A Cloudflare Tunnel (`cfd_tunnel`) summary.
public struct CFTunnel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var status: CFTunnelStatus
    public var createdAt: String?
    public var connectionCount: Int

    public init(
        id: String,
        name: String,
        status: CFTunnelStatus,
        createdAt: String? = nil,
        connectionCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.connectionCount = connectionCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case connections
        case connectionCountSnake = "connection_count"
        case connectionCountCamel = "connectionCount"
    }

    private struct RawConnection: Decodable {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decodeIfPresent(CFTunnelStatus.self, forKey: .status) ?? .unknown
        if let snakeDate = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = snakeDate
        } else {
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAtCamel)
        }
        if let connections = try container.decodeIfPresent([RawConnection].self, forKey: .connections) {
            connectionCount = connections.count
        } else if let snakeCount = try container.decodeIfPresent(Int.self, forKey: .connectionCountSnake) {
            connectionCount = snakeCount
        } else {
            connectionCount = try container.decodeIfPresent(Int.self, forKey: .connectionCountCamel) ?? 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encode(connectionCount, forKey: .connectionCountSnake)
    }
}

/// An ingress routing rule in a Cloudflare Tunnel configuration.
public struct CFTunnelIngressRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var hostname: String?
    public var service: String
    public var path: String?

    public var id: String {
        "\(hostname ?? "")|\(path ?? "")|\(service)"
    }

    public init(hostname: String? = nil, service: String, path: String? = nil) {
        self.hostname = hostname
        self.service = service
        self.path = path
    }
}

/// Errors produced by `CloudflareTokenStore` and `CloudflareClient`.
public enum CloudflareError: Error, Equatable, Sendable, LocalizedError {
    case missingToken
    case unauthorized
    case apiError(String)
    case httpError(Int, String)
    case invalidResponse
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Cloudflare API token is missing."
        case .unauthorized:
            return "Cloudflare API token is invalid or lacks permission."
        case .apiError(let message):
            return message.isEmpty ? "Cloudflare API returned an error." : message
        case .httpError(let statusCode, let message):
            return message.isEmpty
                ? "Cloudflare HTTP error (\(statusCode))."
                : "Cloudflare HTTP error (\(statusCode)): \(message)"
        case .invalidResponse:
            return "Invalid response from Cloudflare API."
        case .networkError(let message):
            return message.isEmpty ? "Network error communicating with Cloudflare." : message
        }
    }
}

// MARK: - Cloudflare API v4 Client

/// Async client for Cloudflare REST API v4 (token verification, accounts, DNS zones/records, and Tunnels).
public struct CloudflareClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    private let session: URLSession
    private let token: String
    private let baseURL: URL

    public init(
        token: String,
        session: URLSession = .shared,
        baseURL: URL = CloudflareClient.defaultBaseURL
    ) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.baseURL = baseURL
    }

    /// Verifies that the API token is valid and active (`GET /user/tokens/verify`).
    public func verifyToken() async throws -> Bool {
        let result: VerifyTokenResult = try await request(
            method: "GET",
            pathSegments: ["user", "tokens", "verify"]
        )
        return result.status.lowercased() == "active"
    }

    /// Lists Cloudflare accounts accessible to the token (`GET /accounts?per_page=50`).
    public func listAccounts() async throws -> [CFAccount] {
        try await request(
            method: "GET",
            pathSegments: ["accounts"],
            queryItems: [URLQueryItem(name: "per_page", value: "50")]
        )
    }

    /// Lists DNS zones accessible to the token (`GET /zones?per_page=50`).
    public func listZones() async throws -> [CFZone] {
        try await request(
            method: "GET",
            pathSegments: ["zones"],
            queryItems: [URLQueryItem(name: "per_page", value: "50")]
        )
    }

    /// Lists DNS records for a zone (`GET /zones/{zoneID}/dns_records?per_page=100`).
    public func listDNSRecords(zoneID: String) async throws -> [CFDNSRecord] {
        let records: [CFDNSRecord] = try await request(
            method: "GET",
            pathSegments: ["zones", zoneID, "dns_records"],
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )
        return records.map { withZoneID($0, fallback: zoneID) }
    }

    /// Creates a DNS record in a zone (`POST /zones/{zoneID}/dns_records`).
    public func createDNSRecord(zoneID: String, record: CFDNSRecordInput) async throws -> CFDNSRecord {
        let created: CFDNSRecord = try await request(
            method: "POST",
            pathSegments: ["zones", zoneID, "dns_records"],
            body: record
        )
        return withZoneID(created, fallback: zoneID)
    }

    /// Updates an existing DNS record in a zone (`PATCH /zones/{zoneID}/dns_records/{recordID}`).
    public func updateDNSRecord(zoneID: String, recordID: String, record: CFDNSRecordInput) async throws -> CFDNSRecord {
        let updated: CFDNSRecord = try await request(
            method: "PATCH",
            pathSegments: ["zones", zoneID, "dns_records", recordID],
            body: record
        )
        return withZoneID(updated, fallback: zoneID)
    }

    /// Deletes a DNS record in a zone (`DELETE /zones/{zoneID}/dns_records/{recordID}`).
    public func deleteDNSRecord(zoneID: String, recordID: String) async throws {
        let _: DeleteResult? = try await requestOptional(
            method: "DELETE",
            pathSegments: ["zones", zoneID, "dns_records", recordID]
        )
    }

    /// Lists active Cloudflare Tunnels in an account (`GET /accounts/{accountID}/cfd_tunnel?is_deleted=false&per_page=100`).
    public func listTunnels(accountID: String) async throws -> [CFTunnel] {
        try await request(
            method: "GET",
            pathSegments: ["accounts", accountID, "cfd_tunnel"],
            queryItems: [
                URLQueryItem(name: "is_deleted", value: "false"),
                URLQueryItem(name: "per_page", value: "100"),
            ]
        )
    }

    /// Fetches exposed ingress rules (non-empty `hostname`) for a Cloudflare Tunnel (`GET /accounts/{accountID}/cfd_tunnel/{tunnelID}/configurations`).
    public func getTunnelIngress(accountID: String, tunnelID: String) async throws -> [CFTunnelIngressRule] {
        let configResult: TunnelConfigurationResult? = try await requestOptional(
            method: "GET",
            pathSegments: ["accounts", accountID, "cfd_tunnel", tunnelID, "configurations"]
        )
        let rules = configResult?.config?.ingress ?? []
        return rules.filter { rule in
            guard let hostname = rule.hostname?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !hostname.isEmpty
        }
    }

    // MARK: - Request & Envelope Helpers

    private func withZoneID(_ record: CFDNSRecord, fallback zoneID: String) -> CFDNSRecord {
        guard record.zoneID.isEmpty else { return record }
        var copy = record
        copy.zoneID = zoneID
        return copy
    }

    private func request<Response: Decodable>(
        method: String,
        pathSegments: [String],
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        guard let result: Response = try await requestOptional(
            method: method,
            pathSegments: pathSegments,
            queryItems: queryItems,
            bodyData: nil
        ) else {
            throw CloudflareError.invalidResponse
        }
        return result
    }

    private func request<Body: Encodable, Response: Decodable>(
        method: String,
        pathSegments: [String],
        queryItems: [URLQueryItem] = [],
        body: Body
    ) async throws -> Response {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw CloudflareError.invalidResponse
        }
        guard let result: Response = try await requestOptional(
            method: method,
            pathSegments: pathSegments,
            queryItems: queryItems,
            bodyData: encodedBody
        ) else {
            throw CloudflareError.invalidResponse
        }
        return result
    }

    private func requestOptional<Response: Decodable>(
        method: String,
        pathSegments: [String],
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil
    ) async throws -> Response? {
        guard !token.isEmpty else {
            throw CloudflareError.missingToken
        }

        let url = try makeURL(pathSegments: pathSegments, queryItems: queryItems)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudflareError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudflareError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw CloudflareError.unauthorized
        }

        let decoder = JSONDecoder()

        // Inspect envelope success/errors first so 4xx/5xx Cloudflare JSON errors surface as `.apiError`.
        if let statusEnvelope = try? decoder.decode(CFStatusEnvelope.self, from: data) {
            if !statusEnvelope.success {
                let messages = (statusEnvelope.errors ?? [])
                    .map { $0.message.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !messages.isEmpty {
                    throw CloudflareError.apiError(messages.joined(separator: "; "))
                }
                let codes = (statusEnvelope.errors ?? []).compactMap(\.code).map(String.init)
                if !codes.isEmpty {
                    throw CloudflareError.apiError("Cloudflare error code(s): \(codes.joined(separator: ", "))")
                }
                if !(200..<300).contains(http.statusCode) {
                    throw CloudflareError.httpError(http.statusCode, "")
                }
                throw CloudflareError.apiError("Cloudflare API request failed.")
            }

            guard (200..<300).contains(http.statusCode) else {
                throw CloudflareError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }

            do {
                let envelope = try decoder.decode(CFEnvelope<Response>.self, from: data)
                return envelope.result
            } catch {
                throw CloudflareError.invalidResponse
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CloudflareError.httpError(http.statusCode, preview)
        }

        throw CloudflareError.invalidResponse
    }

    private func makeURL(pathSegments: [String], queryItems: [URLQueryItem]) throws -> URL {
        guard pathSegments.allSatisfy({ !$0.isEmpty }),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw CloudflareError.invalidResponse
        }

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encodedSegments = pathSegments.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = ([basePath] + encodedSegments).joined(separator: "/")

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw CloudflareError.invalidResponse
        }
        return url
    }
}

// MARK: - Internal Response Envelopes

private struct CFAPIErrorDetail: Decodable {
    let code: Int?
    let message: String
}

private struct CFStatusEnvelope: Decodable {
    let success: Bool
    let errors: [CFAPIErrorDetail]?
}

private struct CFEnvelope<Result: Decodable>: Decodable {
    let success: Bool
    let errors: [CFAPIErrorDetail]?
    let result: Result?
}

private struct VerifyTokenResult: Decodable {
    let status: String
}

private struct DeleteResult: Decodable {
    let id: String?
}

private struct TunnelConfigurationResult: Decodable {
    let config: TunnelConfigBody?
}

private struct TunnelConfigBody: Decodable {
    let ingress: [CFTunnelIngressRule]?
}
