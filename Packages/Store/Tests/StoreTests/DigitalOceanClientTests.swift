import Foundation
import XCTest
@testable import Store

final class DigitalOceanClientTests: XCTestCase {
    private static let testToken = "dop_v1_test_secret_token"

    override func tearDown() {
        StubURLProtocolStore.shared.reset()
        super.tearDown()
    }

    private func makeStubbedClient(
        token: String = testToken,
        handler: @escaping @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)
    ) -> DigitalOceanClient {
        let sessionID = UUID().uuidString
        StubURLProtocolStore.shared.register(sessionID: sessionID, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = [StubURLProtocol.sessionIDHeader: sessionID]
        let session = URLSession(configuration: config)
        return DigitalOceanClient(token: token, session: session)
    }

    private static func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    // MARK: - DigitalOceanTokenStore

    func testTokenStoreLocalOnlySaveReadDeleteAndValidation() throws {
        let storage = MockTokenKeychainStorage()

        XCTAssertEqual(DigitalOceanTokenStore.service, "termapp.digitalocean.token")
        XCTAssertEqual(DigitalOceanTokenStore.account, "pat")
        XCTAssertNil(DigitalOceanTokenStore.read(storage: storage))
        XCTAssertFalse(DigitalOceanTokenStore.hasToken(storage: storage))

        // Empty or whitespace-only tokens must fail validation.
        XCTAssertThrowsError(try DigitalOceanTokenStore.save("", storage: storage)) { error in
            XCTAssertEqual(error as? DOError, .missingToken)
        }
        XCTAssertThrowsError(try DigitalOceanTokenStore.save("   \n\t  ", storage: storage)) { error in
            XCTAssertEqual(error as? DOError, .missingToken)
        }

        // Seed a synced entry with the same service/account to ensure read ignores it and save removes it.
        try storage.save(
            Data("stale_synced_token".utf8),
            service: DigitalOceanTokenStore.service,
            account: DigitalOceanTokenStore.account,
            synchronizable: true
        )
        XCTAssertNil(DigitalOceanTokenStore.read(storage: storage))

        // Saving trims whitespace and persists strictly with synchronizable == false.
        try DigitalOceanTokenStore.save("  dop_v1_abc123 \n", storage: storage)
        XCTAssertEqual(DigitalOceanTokenStore.read(storage: storage), "dop_v1_abc123")
        XCTAssertTrue(DigitalOceanTokenStore.hasToken(storage: storage))
        XCTAssertEqual(
            storage.syncFlag(service: DigitalOceanTokenStore.service, account: DigitalOceanTokenStore.account),
            false
        )
        XCTAssertEqual(storage.saveHistory.last?.synchronizable, false)
        XCTAssertNil(
            try storage.read(
                service: DigitalOceanTokenStore.service,
                account: DigitalOceanTokenStore.account,
                synchronizable: true
            )
        )

        // Delete removes token and is idempotent.
        try DigitalOceanTokenStore.delete(storage: storage)
        XCTAssertNil(DigitalOceanTokenStore.read(storage: storage))
        XCTAssertFalse(DigitalOceanTokenStore.hasToken(storage: storage))
        try DigitalOceanTokenStore.delete(storage: storage)
    }

    // MARK: - Droplets

    func testListDropletsDecodesNetworksRegionSpecsAndStatus() async throws {
        let payload = """
        {
          "droplets": [
            {
              "id": 3164444,
              "name": "prod-web-1",
              "memory": 1024,
              "vcpus": 1,
              "disk": 25,
              "status": "active",
              "size_slug": "s-1vcpu-1gb",
              "created_at": "2026-10-01T12:00:00Z",
              "tags": ["web", "prod"],
              "region": {
                "slug": "nyc3",
                "name": "New York 3"
              },
              "image": {
                "id": 158148204,
                "name": "24.04 (LTS) x64",
                "distribution": "Ubuntu",
                "slug": "ubuntu-24-04-x64"
              },
              "networks": {
                "v4": [
                  {
                    "ip_address": "10.132.100.5",
                    "type": "private"
                  },
                  {
                    "ip_address": "104.236.32.182",
                    "type": "public"
                  }
                ]
              }
            },
            {
              "id": 3164445,
              "name": "worker-2",
              "memory": 512,
              "vcpus": 2,
              "disk": 10,
              "status": "off",
              "size_slug": "s-1vcpu-512mb-10gb",
              "tags": [],
              "region": {
                "slug": "sfo3",
                "name": "San Francisco 3"
              },
              "image": {
                "id": 158148205,
                "name": "Debian 12 x64",
                "distribution": "Debian",
                "slug": "debian-12-x64"
              },
              "networks": {
                "v4": []
              }
            }
          ]
        }
        """

        let client = makeStubbedClient { request, body in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/droplets?per_page=100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.testToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(body)
            return (Self.httpResponse(url: request.url!, statusCode: 200), Data(payload.utf8))
        }

        let droplets = try await client.listDroplets()
        XCTAssertEqual(droplets.count, 2)

        let first = droplets[0]
        XCTAssertEqual(first.id, 3164444)
        XCTAssertEqual(first.name, "prod-web-1")
        XCTAssertEqual(first.status, "active")
        XCTAssertTrue(first.isActive)
        XCTAssertEqual(first.memory, 1024)
        XCTAssertEqual(first.vcpus, 1)
        XCTAssertEqual(first.disk, 25)
        XCTAssertEqual(first.regionSlug, "nyc3")
        XCTAssertEqual(first.regionName, "New York 3")
        XCTAssertEqual(first.sizeSlug, "s-1vcpu-1gb")
        XCTAssertEqual(first.imageName, "Ubuntu 24.04 (LTS) x64")
        XCTAssertEqual(first.publicIPv4, "104.236.32.182")
        XCTAssertEqual(first.privateIPv4, "10.132.100.5")
        XCTAssertEqual(first.tags, ["web", "prod"])
        XCTAssertEqual(first.createdAt, "2026-10-01T12:00:00Z")
        XCTAssertEqual(first.specsSummary, "1 vCPU · 1 GB · nyc3")

        let second = droplets[1]
        XCTAssertEqual(second.id, 3164445)
        XCTAssertFalse(second.isActive)
        XCTAssertNil(second.publicIPv4)
        XCTAssertNil(second.privateIPv4)
        XCTAssertEqual(second.imageName, "Debian 12 x64")
        XCTAssertEqual(second.specsSummary, "2 vCPUs · 512 MB · sfo3")

        // Verify flat Codable round-trip as well.
        let encoded = try JSONEncoder().encode(droplets)
        let roundTripped = try JSONDecoder().decode([DODroplet].self, from: encoded)
        XCTAssertEqual(roundTripped, droplets)
    }

    func testCreateDropletSendsExactJSONBodyAndBearerHeader() async throws {
        let responsePayload = """
        {
          "droplet": {
            "id": 99001,
            "name": "termapp-box",
            "memory": 2048,
            "vcpus": 1,
            "disk": 50,
            "status": "new",
            "size_slug": "s-1vcpu-2gb",
            "created_at": "2026-11-23T23:00:00Z",
            "tags": ["termapp", "dev"],
            "region": {
              "slug": "fra1",
              "name": "Frankfurt 1"
            },
            "image": {
              "id": 158148204,
              "name": "24.04 (LTS) x64",
              "distribution": "Ubuntu",
              "slug": "ubuntu-24-04-x64"
            },
            "networks": {
              "v4": []
            }
          }
        }
        """

        let client = makeStubbedClient { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/droplets")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.testToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let rawBody = try XCTUnwrap(body)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: rawBody) as? [String: Any])
            XCTAssertEqual(
                Set(json.keys),
                ["name", "region", "size", "image", "ssh_keys", "tags"]
            )
            XCTAssertEqual(json["name"] as? String, "termapp-box")
            XCTAssertEqual(json["region"] as? String, "fra1")
            XCTAssertEqual(json["size"] as? String, "s-1vcpu-2gb")
            XCTAssertEqual(json["image"] as? String, "ubuntu-24-04-x64")
            XCTAssertEqual(json["ssh_keys"] as? [Int], [101, 202])
            XCTAssertEqual(json["tags"] as? [String], ["termapp", "dev"])

            return (Self.httpResponse(url: request.url!, statusCode: 202), Data(responsePayload.utf8))
        }

        let created = try await client.createDroplet(
            DOCreateDropletRequest(
                name: "termapp-box",
                region: "fra1",
                size: "s-1vcpu-2gb",
                image: "ubuntu-24-04-x64",
                sshKeys: [101, 202],
                tags: ["termapp", "dev"]
            )
        )

        XCTAssertEqual(created.id, 99001)
        XCTAssertEqual(created.name, "termapp-box")
        XCTAssertEqual(created.status, "new")
        XCTAssertFalse(created.isActive)
        XCTAssertEqual(created.specsSummary, "1 vCPU · 2 GB · fra1")
        XCTAssertNil(created.publicIPv4)
    }

    func testPerformActionRebootSendsExpectedJSONPayload() async throws {
        for action in DODropletActionType.allCases {
            let client = makeStubbedClient { request, body in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/droplets/4242/actions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.testToken)")

                let rawBody = try XCTUnwrap(body)
                XCTAssertEqual(String(data: rawBody, encoding: .utf8), #"{"type":"\#(action.rawValue)"}"#)
                return (
                    Self.httpResponse(url: request.url!, statusCode: 201),
                    Data(#"{"action":{"id":1,"status":"in-progress"}}"#.utf8)
                )
            }

            try await client.performAction(action, dropletID: 4242)
        }
        XCTAssertEqual(DODropletActionType.reboot.rawValue, "reboot")
        XCTAssertEqual(DODropletActionType.powerOn.rawValue, "power_on")
        XCTAssertEqual(DODropletActionType.powerOff.rawValue, "power_off")
        XCTAssertEqual(DODropletActionType.shutdown.rawValue, "shutdown")
    }

    func testDeleteDropletHandles204NoContent() async throws {
        let client = makeStubbedClient { request, _ in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/droplets/7788")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.testToken)")
            return (Self.httpResponse(url: request.url!, statusCode: 204), Data())
        }

        try await client.deleteDroplet(id: 7788)
    }

    // MARK: - SSH Keys

    func testListAndCreateSSHKeys() async throws {
        let listPayload = """
        {
          "ssh_keys": [
            {
              "id": 512189,
              "name": "iPhone Key",
              "fingerprint": "3b:16:bf:e4:8b:00:8b:b8:59:8c:a9:d3:f0:19:45:fa",
              "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey iphone"
            }
          ]
        }
        """

        let listClient = makeStubbedClient { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/account/keys?per_page=100")
            return (Self.httpResponse(url: request.url!, statusCode: 200), Data(listPayload.utf8))
        }

        let keys = try await listClient.listSSHKeys()
        XCTAssertEqual(keys, [
            DOSSHKey(
                id: 512189,
                name: "iPhone Key",
                fingerprint: "3b:16:bf:e4:8b:00:8b:b8:59:8c:a9:d3:f0:19:45:fa",
                publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey iphone"
            ),
        ])

        let createPayload = """
        {
          "ssh_key": {
            "id": 512190,
            "name": "Work iPad",
            "fingerprint": "aa:bb:cc:dd",
            "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewKey ipad"
          }
        }
        """

        let createClient = makeStubbedClient { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/account/keys")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.testToken)")

            let rawBody = try XCTUnwrap(body)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: rawBody) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "Work iPad")
            XCTAssertEqual(json["public_key"] as? String, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewKey ipad")

            return (Self.httpResponse(url: request.url!, statusCode: 201), Data(createPayload.utf8))
        }

        let created = try await createClient.createSSHKey(
            name: "Work iPad",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewKey ipad"
        )
        XCTAssertEqual(created.id, 512190)
        XCTAssertEqual(created.name, "Work iPad")
        XCTAssertEqual(created.fingerprint, "aa:bb:cc:dd")
        XCTAssertEqual(created.publicKey, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewKey ipad")
    }

    // MARK: - Regions, Sizes, and Images

    func testListRegionsSizesAndDistributionImagesFilteringAndSorting() async throws {
        let regionsPayload = """
        {
          "regions": [
            {"slug": "nyc1", "name": "New York 1", "available": false},
            {"slug": "nyc3", "name": "New York 3", "available": true},
            {"slug": "lon1", "name": "London 1", "available": true}
          ]
        }
        """
        let regionsClient = makeStubbedClient { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/regions?per_page=100")
            return (Self.httpResponse(url: request.url!, statusCode: 200), Data(regionsPayload.utf8))
        }
        let regions = try await regionsClient.listRegions()
        XCTAssertEqual(regions, [
            DORegion(slug: "nyc3", name: "New York 3", available: true),
            DORegion(slug: "lon1", name: "London 1", available: true),
        ])
        XCTAssertEqual(regions.map(\.id), ["nyc3", "lon1"])

        let sizesPayload = """
        {
          "sizes": [
            {"slug": "s-2vcpu-4gb", "memory": 4096, "vcpus": 2, "disk": 80, "price_monthly": 24.0, "available": true},
            {"slug": "s-unavailable", "memory": 512, "vcpus": 1, "disk": 10, "price_monthly": 2.0, "available": false},
            {"slug": "s-1vcpu-1gb", "memory": 1024, "vcpus": 1, "disk": 25, "price_monthly": 6.0, "available": true},
            {"slug": "s-1vcpu-512mb-10gb", "memory": 512, "vcpus": 1, "disk": 10, "price_monthly": 4.0, "available": true}
          ]
        }
        """
        let sizesClient = makeStubbedClient { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/sizes?per_page=100")
            return (Self.httpResponse(url: request.url!, statusCode: 200), Data(sizesPayload.utf8))
        }
        let sizes = try await sizesClient.listSizes()
        XCTAssertEqual(sizes.map(\.slug), ["s-1vcpu-512mb-10gb", "s-1vcpu-1gb", "s-2vcpu-4gb"])
        XCTAssertEqual(sizes.map(\.priceMonthly), [4.0, 6.0, 24.0])

        let imagesPayload = """
        {
          "images": [
            {"id": 10, "slug": "ubuntu-24-04-x64", "name": "24.04 (LTS) x64", "distribution": "Ubuntu"},
            {"id": 11, "slug": null, "name": "Custom", "distribution": "Linux"}
          ]
        }
        """
        let imagesClient = makeStubbedClient { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/images?type=distribution&per_page=100")
            return (Self.httpResponse(url: request.url!, statusCode: 200), Data(imagesPayload.utf8))
        }
        let images = try await imagesClient.listDistributionImages()
        XCTAssertEqual(images, [
            DOImage(id: 10, slug: "ubuntu-24-04-x64", name: "24.04 (LTS) x64", distribution: "Ubuntu"),
            DOImage(id: 11, slug: nil, name: "Custom", distribution: "Linux"),
        ])
    }

    // MARK: - Error Mapping

    func testHTTPError401And422AndInvalidAndNetworkAndMissingToken() async throws {
        // 401 Unauthorized -> DOError.unauthorized
        let client401 = makeStubbedClient { request, _ in
            let body = Data(#"{"id":"unauthorized","message":"Unable to authenticate you."}"#.utf8)
            return (Self.httpResponse(url: request.url!, statusCode: 401), body)
        }
        do {
            _ = try await client401.listDroplets()
            XCTFail("Expected DOError.unauthorized")
        } catch let error as DOError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertNotNil(error.errorDescription)
        }

        // 422 Unprocessable Entity -> DOError.httpError(422, message)
        let client422 = makeStubbedClient { request, _ in
            let body = Data(#"{"id":"unprocessable_entity","message":"Droplet name is already in use."}"#.utf8)
            return (Self.httpResponse(url: request.url!, statusCode: 422), body)
        }
        do {
            _ = try await client422.createDroplet(
                DOCreateDropletRequest(name: "dup", region: "nyc3", size: "s-1vcpu-1gb", image: "ubuntu-24-04-x64")
            )
            XCTFail("Expected DOError.httpError")
        } catch let error as DOError {
            XCTAssertEqual(error, .httpError(422, "Droplet name is already in use."))
            XCTAssertTrue(error.errorDescription?.contains("422") == true)
        }

        // Invalid JSON with 200 -> DOError.invalidResponse
        let invalidClient = makeStubbedClient { request, _ in
            (Self.httpResponse(url: request.url!, statusCode: 200), Data("not-json".utf8))
        }
        do {
            _ = try await invalidClient.listRegions()
            XCTFail("Expected DOError.invalidResponse")
        } catch let error as DOError {
            XCTAssertEqual(error, .invalidResponse)
            XCTAssertNotNil(error.errorDescription)
        }

        // Network failure -> DOError.networkError
        let networkClient = makeStubbedClient { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await networkClient.listSizes()
            XCTFail("Expected DOError.networkError")
        } catch let error as DOError {
            guard case .networkError(let message) = error else {
                return XCTFail("Expected DOError.networkError, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertNotNil(error.errorDescription)
        }

        // Blank token -> DOError.missingToken without issuing any request
        let emptyClient = makeStubbedClient(token: "   ") { _, _ in
            XCTFail("Network should not be called when token is missing")
            throw URLError(.cancelled)
        }
        do {
            _ = try await emptyClient.listDroplets()
            XCTFail("Expected DOError.missingToken")
        } catch let error as DOError {
            XCTAssertEqual(error, .missingToken)
            XCTAssertNotNil(error.errorDescription)
        }
    }

    // MARK: - Destroy + Forget Host Key

    func testDestroyDropletAndForgetHostKey() async throws {
        let deleteClient = makeStubbedClient { request, _ in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/droplets/555")
            return (Self.httpResponse(url: request.url!, statusCode: 204), Data())
        }

        // Public API succeeds even when Keychain is unavailable in unhosted/sandboxed tests.
        try await DigitalOceanClient.destroyDropletAndForgetHostKey(
            id: 555,
            ipv4: "198.51.100.25",
            port: 2222,
            client: deleteClient,
            knownHosts: KnownHostsStore(service: "com.peculiarengineer.termapp.tests.do.\(UUID().uuidString)")
        )

        // When delete fails, error propagates and host key is NOT forgotten.
        let failingClient = makeStubbedClient { request, _ in
            (Self.httpResponse(url: request.url!, statusCode: 401), Data())
        }
        let hostKeyMock = MockHostKeyForgetter()
        do {
            try await DigitalOceanClient.destroyDropletAndForgetHostKey(
                id: 555,
                ipv4: "198.51.100.25",
                port: 2222,
                client: failingClient,
                hostKeyStore: hostKeyMock
            )
            XCTFail("Expected unauthorized error")
        } catch let error as DOError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertTrue(hostKeyMock.forgottenHosts().isEmpty)

        // Empty/nil IPv4 skips host key forget even after successful delete.
        try await DigitalOceanClient.destroyDropletAndForgetHostKey(
            id: 555,
            ipv4: "   ",
            port: 22,
            client: deleteClient,
            hostKeyStore: hostKeyMock
        )
        try await DigitalOceanClient.destroyDropletAndForgetHostKey(
            id: 555,
            ipv4: nil,
            port: 22,
            client: deleteClient,
            hostKeyStore: hostKeyMock
        )
        XCTAssertTrue(hostKeyMock.forgottenHosts().isEmpty)

        // Successful delete with non-empty IPv4 forgets (host, port), and swallows forget errors.
        hostKeyMock.shouldThrow = true
        try await DigitalOceanClient.destroyDropletAndForgetHostKey(
            id: 555,
            ipv4: " 198.51.100.25 ",
            port: 2222,
            client: deleteClient,
            hostKeyStore: hostKeyMock
        )
        XCTAssertEqual(hostKeyMock.forgottenHosts().count, 1)
        XCTAssertEqual(hostKeyMock.forgottenHosts().first?.host, "198.51.100.25")
        XCTAssertEqual(hostKeyMock.forgottenHosts().first?.port, 2222)

        // If Keychain is available in the current host environment, also verify live KnownHostsStore round-trip.
        let liveKnownHosts = KnownHostsStore(service: "com.peculiarengineer.termapp.tests.do.\(UUID().uuidString)")
        do {
            _ = try liveKnownHosts.fingerprint(host: "198.51.100.25", port: 2222)
            try liveKnownHosts.trust(host: "198.51.100.25", port: 2222, fingerprint: "SHA256:live")
            try await DigitalOceanClient.destroyDropletAndForgetHostKey(
                id: 555,
                ipv4: "198.51.100.25",
                port: 2222,
                client: deleteClient,
                knownHosts: liveKnownHosts
            )
            XCTAssertNil(try liveKnownHosts.fingerprint(host: "198.51.100.25", port: 2222))
        } catch let e as KeychainError where e.status == errSecMissingEntitlement || e.status == errSecNotAvailable {
            // Keychain unavailable in unhosted/sandboxed test runner; MockHostKeyForgetter above covered forget behavior.
        }
    }
}

// MARK: - Test Doubles

private final class StubURLProtocolStore: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

    static let shared = StubURLProtocolStore()

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(sessionID: String, handler: @escaping Handler) {
        lock.lock()
        handlers[sessionID] = handler
        lock.unlock()
    }

    func handler(for sessionID: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[sessionID]
    }

    func reset() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let sessionIDHeader = "X-TermApp-Test-Session"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let sessionID = request.value(forHTTPHeaderField: Self.sessionIDHeader),
              let handler = StubURLProtocolStore.shared.handler(for: sessionID) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let body = Self.readBody(from: request)
        do {
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

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
}

private final class MockTokenKeychainStorage: KeychainStoring, @unchecked Sendable {
    private struct ItemKey: Hashable {
        let service: String
        let account: String
        let synchronizable: Bool
    }

    private var items: [ItemKey: Data] = [:]
    private(set) var saveHistory: [(service: String, account: String, synchronizable: Bool)] = []

    func syncFlag(service: String, account: String) -> Bool? {
        if items[ItemKey(service: service, account: account, synchronizable: true)] != nil { return true }
        if items[ItemKey(service: service, account: account, synchronizable: false)] != nil { return false }
        return nil
    }

    func save(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        saveHistory.append((service, account, synchronizable))
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)] = data
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: !synchronizable))
    }

    func read(service: String, account: String) throws -> Data? {
        if let synced = try read(service: service, account: account, synchronizable: true) { return synced }
        return try read(service: service, account: account, synchronizable: false)
    }

    func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)]
    }

    func readAll(service: String) throws -> [(account: String, data: Data, synchronizable: Bool)] {
        items.compactMap { key, data in
            key.service == service ? (key.account, data, key.synchronizable) : nil
        }
    }

    func delete(service: String, account: String) throws {
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: true))
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: false))
    }

    func setSynchronizable(_ synchronizable: Bool, service: String, account: String) throws {
        guard let data = try read(service: service, account: account, synchronizable: !synchronizable) else {
            if try read(service: service, account: account, synchronizable: synchronizable) != nil { return }
            throw KeychainError(status: errSecItemNotFound)
        }
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)] = data
        items.removeValue(forKey: ItemKey(service: service, account: account, synchronizable: !synchronizable))
    }
}

private final class MockHostKeyForgetter: HostKeyForgetting, @unchecked Sendable {
    private let lock = NSLock()
    private var forgotten: [(host: String, port: Int)] = []
    var shouldThrow = false

    func forget(host: String, port: Int) throws {
        lock.lock()
        forgotten.append((host, port))
        let fail = shouldThrow
        lock.unlock()
        if fail {
            throw KeychainError(status: errSecNotAvailable)
        }
    }

    func forgottenHosts() -> [(host: String, port: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return forgotten
    }
}
