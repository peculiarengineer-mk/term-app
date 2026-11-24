import Foundation
import Security
import XCTest
@testable import Store

final class CloudflareClientTests: XCTestCase {
    // MARK: - URLProtocol Stub Infrastructure

    private final class StubRegistry: @unchecked Sendable {
        static let shared = StubRegistry()
        private let lock = NSLock()
        private var handlers: [String: @Sendable (URLRequest) throws -> (Int, Data)] = [:]

        func set(id: String, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
            lock.lock()
            defer { lock.unlock() }
            handlers[id] = handler
        }

        func remove(id: String) {
            lock.lock()
            defer { lock.unlock() }
            handlers.removeValue(forKey: id)
        }

        func handler(for id: String) -> (@Sendable (URLRequest) throws -> (Int, Data))? {
            lock.lock()
            defer { lock.unlock() }
            return handlers[id]
        }
    }

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        static let stubHeader = "X-CF-Stub-ID"

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let stubID = request.value(forHTTPHeaderField: Self.stubHeader),
                  let handler = StubRegistry.shared.handler(for: stubID)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }

            do {
                let (statusCode, data) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url ?? CloudflareClient.defaultBaseURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeStubClient(
        token: String = "cf-test-token",
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
    ) -> (CloudflareClient, () -> Void) {
        let stubID = UUID().uuidString
        StubRegistry.shared.set(id: stubID, handler: handler)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [MockURLProtocol.stubHeader: stubID]
        let session = URLSession(configuration: config)
        let client = CloudflareClient(token: token, session: session)

        return (client, {
            session.invalidateAndCancel()
            StubRegistry.shared.remove(id: stubID)
        })
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func assertStandardHeaders(_ request: URLRequest, token: String = "cf-test-token", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", file: file, line: line)
    }

    // MARK: - Mock Keychain Storage for Deterministic Token Store Tests

    private final class MockKeychainStorage: KeychainStoring, @unchecked Sendable {
        struct Entry {
            var data: Data
            var synchronizable: Bool
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        var savedSynchronizableFlags: [Bool] = []

        private func key(_ service: String, _ account: String) -> String {
            "\(service)|\(account)"
        }

        func save(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
            lock.lock()
            defer { lock.unlock() }
            savedSynchronizableFlags.append(synchronizable)
            entries[key(service, account)] = Entry(data: data, synchronizable: synchronizable)
        }

        func read(service: String, account: String) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key(service, account)]?.data
        }

        func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key(service, account)], entry.synchronizable == synchronizable else {
                return nil
            }
            return entry.data
        }

        func readAll(service: String) throws -> [(account: String, data: Data, synchronizable: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return entries.compactMap { k, entry in
                let parts = k.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, String(parts[0]) == service else { return nil }
                return (String(parts[1]), entry.data, entry.synchronizable)
            }
        }

        func delete(service: String, account: String) throws {
            lock.lock()
            defer { lock.unlock() }
            entries.removeValue(forKey: key(service, account))
        }

        func setSynchronizable(_ synchronizable: Bool, service: String, account: String) throws {
            lock.lock()
            defer { lock.unlock() }
            let k = key(service, account)
            guard var entry = entries[k] else {
                throw KeychainError(status: errSecItemNotFound)
            }
            entry.synchronizable = synchronizable
            entries[k] = entry
        }
    }

    // MARK: - Token Store Tests

    func testTokenStoreConstantsAndValidation() throws {
        XCTAssertEqual(CloudflareTokenStore.service, "termapp.cloudflare.token")
        XCTAssertEqual(CloudflareTokenStore.account, "api-token")

        let mockStorage = MockKeychainStorage()

        XCTAssertThrowsError(try CloudflareTokenStore.save("", storage: mockStorage)) { error in
            XCTAssertEqual(error as? CloudflareError, .missingToken)
        }
        XCTAssertThrowsError(try CloudflareTokenStore.save("   \n\t ", storage: mockStorage)) { error in
            XCTAssertEqual(error as? CloudflareError, .missingToken)
        }
        XCTAssertTrue(mockStorage.savedSynchronizableFlags.isEmpty)
        XCTAssertNil(CloudflareTokenStore.read(storage: mockStorage))

        try CloudflareTokenStore.save("  cf_live_token_123 \n", storage: mockStorage)
        XCTAssertEqual(mockStorage.savedSynchronizableFlags, [false])
        XCTAssertEqual(CloudflareTokenStore.read(storage: mockStorage), "cf_live_token_123")

        // Never returns a synchronizable item even if one somehow existed.
        try mockStorage.save(Data("synced_copy".utf8), service: CloudflareTokenStore.service, account: CloudflareTokenStore.account, synchronizable: true)
        XCTAssertNil(CloudflareTokenStore.read(storage: mockStorage))

        try CloudflareTokenStore.save("local_replacement", storage: mockStorage)
        XCTAssertEqual(CloudflareTokenStore.read(storage: mockStorage), "local_replacement")
        XCTAssertEqual(mockStorage.savedSynchronizableFlags, [false, true, false])

        try CloudflareTokenStore.delete(storage: mockStorage)
        XCTAssertNil(CloudflareTokenStore.read(storage: mockStorage))
    }

    func testTokenStoreKeychainRoundTripLocalOnly() throws {
        do {
            try skippingMissingEntitlement {
                let previous = CloudflareTokenStore.read()
                defer {
                    if let previous {
                        try? CloudflareTokenStore.save(previous)
                    } else {
                        try? CloudflareTokenStore.delete()
                    }
                }

                try CloudflareTokenStore.save("  cf-local-only-token \n")
                XCTAssertTrue(CloudflareTokenStore.hasToken)
                XCTAssertEqual(CloudflareTokenStore.read(), "cf-local-only-token")

                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: CloudflareTokenStore.service,
                    kSecAttrAccount as String: CloudflareTokenStore.account,
                    kSecAttrSynchronizable as String: kCFBooleanFalse!,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status != errSecMissingEntitlement else {
                    throw KeychainError(status: status)
                }
                XCTAssertEqual(status, errSecSuccess)
                let attrs = result as? [String: Any]
                XCTAssertEqual(attrs?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

                try CloudflareTokenStore.delete()
                XCTAssertNil(CloudflareTokenStore.read())
                XCTAssertFalse(CloudflareTokenStore.hasToken)
            }
        } catch let e as KeychainError where e.status == errSecParam {
            throw XCTSkip("Keychain unavailable in unhosted/sandboxed macOS test runner (errSecParam -50)")
        }
    }

    // MARK: - API Client Tests

    func testVerifyTokenActiveAndInactive() async throws {
        let (activeClient, cleanupActive) = makeStubClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/user/tokens/verify")
            Self.assertStandardHeaders(request)
            let json = #"{"success":true,"errors":[],"result":{"id":"tok-1","status":"active"}}"#
            return (200, Data(json.utf8))
        }
        defer { cleanupActive() }
        let isActive = try await activeClient.verifyToken()
        XCTAssertTrue(isActive)

        let (inactiveClient, cleanupInactive) = makeStubClient { _ in
            let json = #"{"success":true,"errors":[],"result":{"id":"tok-1","status":"disabled"}}"#
            return (200, Data(json.utf8))
        }
        defer { cleanupInactive() }
        let isDisabledActive = try await inactiveClient.verifyToken()
        XCTAssertFalse(isDisabledActive)
    }

    func testListAccounts() async throws {
        let (client, cleanup) = makeStubClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts?per_page=50")
            Self.assertStandardHeaders(request)
            let json = """
            {
              "success": true,
              "errors": [],
              "result": [
                {"id": "acc-1", "name": "Personal Lab"},
                {"id": "acc-2", "name": "Work Infra"}
              ]
            }
            """
            return (200, Data(json.utf8))
        }
        defer { cleanup() }

        let accounts = try await client.listAccounts()
        XCTAssertEqual(accounts, [
            CFAccount(id: "acc-1", name: "Personal Lab"),
            CFAccount(id: "acc-2", name: "Work Infra"),
        ])
    }

    func testListZonesAndListDNSRecords() async throws {
        let (client, cleanup) = makeStubClient { request in
            Self.assertStandardHeaders(request)
            switch request.url?.absoluteString {
            case "https://api.cloudflare.com/client/v4/zones?per_page=50":
                let json = """
                {
                  "success": true,
                  "errors": [],
                  "result": [
                    {
                      "id": "zone-1",
                      "name": "example.com",
                      "status": "active",
                      "account": {"id": "acc-1", "name": "Personal Lab"}
                    },
                    {
                      "id": "zone-2",
                      "name": "pending.dev",
                      "status": "pending"
                    }
                  ]
                }
                """
                return (200, Data(json.utf8))
            case "https://api.cloudflare.com/client/v4/zones/zone-1/dns_records?per_page=100":
                let json = """
                {
                  "success": true,
                  "errors": [],
                  "result": [
                    {
                      "id": "rec-a",
                      "zone_id": "zone-1",
                      "type": "A",
                      "name": "box.example.com",
                      "content": "203.0.113.10",
                      "proxied": true,
                      "ttl": 1,
                      "comment": "Primary droplet"
                    },
                    {
                      "id": "rec-cname",
                      "zone_id": "zone-1",
                      "type": "CNAME",
                      "name": "www.example.com",
                      "content": "box.example.com",
                      "proxied": false,
                      "ttl": 300
                    },
                    {
                      "id": "rec-txt",
                      "type": "TXT",
                      "name": "_acme.example.com",
                      "content": "token-value",
                      "proxied": false,
                      "ttl": 120
                    }
                  ]
                }
                """
                return (200, Data(json.utf8))
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return (404, Data())
            }
        }
        defer { cleanup() }

        let zones = try await client.listZones()
        XCTAssertEqual(zones, [
            CFZone(id: "zone-1", name: "example.com", status: "active", accountID: "acc-1"),
            CFZone(id: "zone-2", name: "pending.dev", status: "pending", accountID: nil),
        ])

        let records = try await client.listDNSRecords(zoneID: "zone-1")
        XCTAssertEqual(records, [
            CFDNSRecord(
                id: "rec-a",
                zoneID: "zone-1",
                type: "A",
                name: "box.example.com",
                content: "203.0.113.10",
                proxied: true,
                ttl: 1,
                comment: "Primary droplet"
            ),
            CFDNSRecord(
                id: "rec-cname",
                zoneID: "zone-1",
                type: "CNAME",
                name: "www.example.com",
                content: "box.example.com",
                proxied: false,
                ttl: 300,
                comment: nil
            ),
            CFDNSRecord(
                id: "rec-txt",
                zoneID: "zone-1",
                type: "TXT",
                name: "_acme.example.com",
                content: "token-value",
                proxied: false,
                ttl: 120,
                comment: nil
            ),
        ])
    }

    func testCreateAndUpdateDNSRecordSendExactJSONBody() async throws {
        let (client, cleanup) = makeStubClient { request in
            Self.assertStandardHeaders(request)
            let bodyData = try XCTUnwrap(Self.readBody(from: request))
            let jsonObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/zones/zone-1/dns_records")
                XCTAssertEqual(Set(jsonObject.keys), Set(["type", "name", "content", "proxied", "ttl"]))
                XCTAssertEqual(jsonObject["type"] as? String, "A")
                XCTAssertEqual(jsonObject["name"] as? String, "api.example.com")
                XCTAssertEqual(jsonObject["content"] as? String, "198.51.100.42")
                XCTAssertEqual(jsonObject["proxied"] as? Bool, true)
                XCTAssertEqual(jsonObject["ttl"] as? Int, 1)

                let responseJSON = """
                {
                  "success": true,
                  "errors": [],
                  "result": {
                    "id": "rec-new",
                    "zone_id": "zone-1",
                    "type": "A",
                    "name": "api.example.com",
                    "content": "198.51.100.42",
                    "proxied": true,
                    "ttl": 1
                  }
                }
                """
                return (200, Data(responseJSON.utf8))
            } else if request.httpMethod == "PATCH" {
                XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/zones/zone-1/dns_records/rec-new")
                XCTAssertEqual(Set(jsonObject.keys), Set(["type", "name", "content", "proxied", "ttl"]))
                XCTAssertEqual(jsonObject["type"] as? String, "CNAME")
                XCTAssertEqual(jsonObject["name"] as? String, "api.example.com")
                XCTAssertEqual(jsonObject["content"] as? String, "origin.example.com")
                XCTAssertEqual(jsonObject["proxied"] as? Bool, false)
                XCTAssertEqual(jsonObject["ttl"] as? Int, 600)

                let responseJSON = """
                {
                  "success": true,
                  "errors": [],
                  "result": {
                    "id": "rec-new",
                    "zone_id": "zone-1",
                    "type": "CNAME",
                    "name": "api.example.com",
                    "content": "origin.example.com",
                    "proxied": false,
                    "ttl": 600
                  }
                }
                """
                return (200, Data(responseJSON.utf8))
            } else {
                XCTFail("Unexpected HTTP method: \(request.httpMethod ?? "nil")")
                return (405, Data())
            }
        }
        defer { cleanup() }

        let created = try await client.createDNSRecord(
            zoneID: "zone-1",
            record: CFDNSRecordInput(type: "A", name: "api.example.com", content: "198.51.100.42", proxied: true)
        )
        XCTAssertEqual(created.id, "rec-new")
        XCTAssertEqual(created.proxied, true)
        XCTAssertEqual(created.ttl, 1)

        let updated = try await client.updateDNSRecord(
            zoneID: "zone-1",
            recordID: "rec-new",
            record: CFDNSRecordInput(type: "CNAME", name: "api.example.com", content: "origin.example.com", proxied: false, ttl: 600)
        )
        XCTAssertEqual(updated.type, "CNAME")
        XCTAssertEqual(updated.content, "origin.example.com")
        XCTAssertEqual(updated.proxied, false)
        XCTAssertEqual(updated.ttl, 600)
    }

    func testDeleteDNSRecordHandlesEnvelopeWithID() async throws {
        let (client, cleanup) = makeStubClient { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/zones/zone-1/dns_records/rec-del")
            Self.assertStandardHeaders(request)
            let json = #"{"success":true,"errors":[],"result":{"id":"rec-del"}}"#
            return (200, Data(json.utf8))
        }
        defer { cleanup() }

        try await client.deleteDNSRecord(zoneID: "zone-1", recordID: "rec-del")
    }

    func testListTunnelsAndGetTunnelIngress() async throws {
        let (client, cleanup) = makeStubClient { request in
            Self.assertStandardHeaders(request)
            switch request.url?.absoluteString {
            case "https://api.cloudflare.com/client/v4/accounts/acc-1/cfd_tunnel?is_deleted=false&per_page=100":
                let json = """
                {
                  "success": true,
                  "errors": [],
                  "result": [
                    {
                      "id": "tun-1",
                      "name": "prod-box",
                      "status": "healthy",
                      "created_at": "2026-01-10T12:00:00Z",
                      "connections": [{"id": "c1"}, {"id": "c2"}]
                    },
                    {
                      "id": "tun-2",
                      "name": "staging",
                      "status": "degraded",
                      "created_at": "2026-02-01T00:00:00Z",
                      "connections": [{"id": "c3"}]
                    },
                    {
                      "id": "tun-3",
                      "name": "dormant",
                      "status": "inactive",
                      "connections": []
                    },
                    {
                      "id": "tun-4",
                      "name": "offline",
                      "status": "down",
                      "connections": null
                    },
                    {
                      "id": "tun-5",
                      "name": "future-status",
                      "status": "migrating"
                    }
                  ]
                }
                """
                return (200, Data(json.utf8))
            case "https://api.cloudflare.com/client/v4/accounts/acc-1/cfd_tunnel/tun-1/configurations":
                let json = """
                {
                  "success": true,
                  "errors": [],
                  "result": {
                    "tunnel_id": "tun-1",
                    "version": 3,
                    "config": {
                      "ingress": [
                        {"hostname": "ssh.example.com", "service": "ssh://localhost:22"},
                        {"hostname": "app.example.com", "path": "/admin", "service": "http://localhost:8080"},
                        {"service": "http_status:404"}
                      ]
                    }
                  }
                }
                """
                return (200, Data(json.utf8))
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return (404, Data())
            }
        }
        defer { cleanup() }

        let tunnels = try await client.listTunnels(accountID: "acc-1")
        XCTAssertEqual(tunnels, [
            CFTunnel(id: "tun-1", name: "prod-box", status: .healthy, createdAt: "2026-01-10T12:00:00Z", connectionCount: 2),
            CFTunnel(id: "tun-2", name: "staging", status: .degraded, createdAt: "2026-02-01T00:00:00Z", connectionCount: 1),
            CFTunnel(id: "tun-3", name: "dormant", status: .inactive, createdAt: nil, connectionCount: 0),
            CFTunnel(id: "tun-4", name: "offline", status: .down, createdAt: nil, connectionCount: 0),
            CFTunnel(id: "tun-5", name: "future-status", status: .unknown, createdAt: nil, connectionCount: 0),
        ])

        let ingress = try await client.getTunnelIngress(accountID: "acc-1", tunnelID: "tun-1")
        XCTAssertEqual(ingress, [
            CFTunnelIngressRule(hostname: "ssh.example.com", service: "ssh://localhost:22", path: nil),
            CFTunnelIngressRule(hostname: "app.example.com", service: "http://localhost:8080", path: "/admin"),
        ])
    }

    func testErrorMappingUnauthorizedAndAPIErrors() async throws {
        // 401 -> .unauthorized
        let (unauthClient, cleanupUnauth) = makeStubClient { _ in
            let json = #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#
            return (401, Data(json.utf8))
        }
        defer { cleanupUnauth() }
        do {
            _ = try await unauthClient.verifyToken()
            XCTFail("Expected .unauthorized")
        } catch let error as CloudflareError {
            XCTAssertEqual(error, .unauthorized)
        }

        // 403 -> .unauthorized
        let (forbiddenClient, cleanupForbidden) = makeStubClient { _ in
            (403, Data(#"{"success":false,"errors":[{"code":9109,"message":"Forbidden"}]}"#.utf8))
        }
        defer { cleanupForbidden() }
        do {
            _ = try await forbiddenClient.listZones()
            XCTFail("Expected .unauthorized")
        } catch let error as CloudflareError {
            XCTAssertEqual(error, .unauthorized)
        }

        // success == false with error array -> .apiError(joinedMessages)
        let (apiErrClient, cleanupAPIErr) = makeStubClient { _ in
            let json = """
            {
              "success": false,
              "errors": [
                {"code": 81057, "message": "The record already exists."},
                {"code": 1004, "message": "DNS Validation Error"}
              ],
              "result": null
            }
            """
            return (400, Data(json.utf8))
        }
        defer { cleanupAPIErr() }
        do {
            _ = try await apiErrClient.createDNSRecord(
                zoneID: "zone-1",
                record: CFDNSRecordInput(type: "A", name: "dup.example.com", content: "1.2.3.4", proxied: false)
            )
            XCTFail("Expected .apiError")
        } catch let error as CloudflareError {
            XCTAssertEqual(error, .apiError("The record already exists.; DNS Validation Error"))
        }

        // Empty token -> .missingToken
        let emptyClient = CloudflareClient(token: "   ")
        do {
            _ = try await emptyClient.listAccounts()
            XCTFail("Expected .missingToken")
        } catch let error as CloudflareError {
            XCTAssertEqual(error, .missingToken)
        }

        // Non-JSON 502 -> .httpError
        let (httpErrClient, cleanupHTTPErr) = makeStubClient { _ in
            (502, Data("Bad Gateway".utf8))
        }
        defer { cleanupHTTPErr() }
        do {
            _ = try await httpErrClient.listAccounts()
            XCTFail("Expected .httpError")
        } catch let error as CloudflareError {
            XCTAssertEqual(error, .httpError(502, "Bad Gateway"))
        }

        // Malformed 200 JSON -> .invalidResponse
        let (badJSONClient, cleanupBadJSON) = makeStubClient { _ in
            (200, Data("not json".utf8))
        }
        defer { cleanupBadJSON() }
        do {
            _ = try await badJSONClient.listAccounts()
            XCTFail("Expected .invalidResponse")
        } catch let error as CloudflareError {
            XCTAssertEqual(error, .invalidResponse)
        }

        // Transport failure -> .networkError
        let (netErrClient, cleanupNetErr) = makeStubClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { cleanupNetErr() }
        do {
            _ = try await netErrClient.listAccounts()
            XCTFail("Expected .networkError")
        } catch let error as CloudflareError {
            if case .networkError(let msg) = error {
                XCTAssertFalse(msg.isEmpty)
            } else {
                XCTFail("Expected .networkError, got \(error)")
            }
        }
    }

    func testTunnelIngressEmptyConfigAndCodableRoundTrips() async throws {
        let (client, cleanup) = makeStubClient { _ in
            let json = #"{"success":true,"errors":[],"result":{"tunnel_id":"tun-empty","config":null}}"#
            return (200, Data(json.utf8))
        }
        defer { cleanup() }

        let emptyRules = try await client.getTunnelIngress(accountID: "acc-1", tunnelID: "tun-empty")
        XCTAssertEqual(emptyRules, [])

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let zone = CFZone(id: "z1", name: "example.com", status: "active", accountID: "a1")
        XCTAssertEqual(try decoder.decode(CFZone.self, from: encoder.encode(zone)), zone)

        let record = CFDNSRecord(id: "r1", zoneID: "z1", type: "A", name: "a.example.com", content: "1.2.3.4", proxied: true, ttl: 1, comment: "web")
        XCTAssertEqual(try decoder.decode(CFDNSRecord.self, from: encoder.encode(record)), record)

        let tunnel = CFTunnel(id: "t1", name: "box", status: .healthy, createdAt: "2026-01-01T00:00:00Z", connectionCount: 3)
        XCTAssertEqual(try decoder.decode(CFTunnel.self, from: encoder.encode(tunnel)), tunnel)

        let rule = CFTunnelIngressRule(hostname: "ssh.example.com", service: "ssh://localhost:22", path: "/ssh")
        XCTAssertEqual(try decoder.decode(CFTunnelIngressRule.self, from: encoder.encode(rule)), rule)
        XCTAssertEqual(rule.id, "ssh.example.com|/ssh|ssh://localhost:22")
    }
}
