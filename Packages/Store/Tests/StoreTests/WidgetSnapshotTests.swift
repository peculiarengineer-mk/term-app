import XCTest
@testable import Store

final class WidgetSnapshotTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "termapp.tests.widgets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - WidgetHostSnapshot

    func testHostSnapshotDisplayNameAndCodable() throws {
        let hostID = UUID()
        let connectedAt = Date(timeIntervalSince1970: 1_750_000_123.5)

        let labeled = WidgetHostSnapshot(
            id: hostID,
            label: "  Production Bastion \n",
            hostname: "bastion.example.com",
            username: "deploy",
            tags: ["prod", "eu-west"],
            lastConnectedAt: connectedAt,
            source: "manual"
        )
        XCTAssertEqual(labeled.displayName, "Production Bastion")

        let emptyLabel = WidgetHostSnapshot(
            id: hostID,
            label: "",
            hostname: "10.0.1.42",
            username: "ubuntu"
        )
        XCTAssertEqual(emptyLabel.displayName, "10.0.1.42")
        XCTAssertEqual(emptyLabel.tags, [])
        XCTAssertNil(emptyLabel.lastConnectedAt)
        XCTAssertNil(emptyLabel.source)

        let whitespaceLabel = WidgetHostSnapshot(
            id: hostID,
            label: "   \t\n  ",
            hostname: "db-01.internal",
            username: "postgres"
        )
        XCTAssertEqual(whitespaceLabel.displayName, "db-01.internal")

        let encoded = try JSONEncoder().encode(labeled)
        let decoded = try JSONDecoder().decode(WidgetHostSnapshot.self, from: encoded)
        XCTAssertEqual(decoded, labeled)

        let set: Set<WidgetHostSnapshot> = [labeled, decoded, emptyLabel]
        XCTAssertEqual(set.count, 2)

        // Legacy/minimal payload without optional keys decodes with safe defaults.
        let minimalJSON = """
        {"id":"\(hostID.uuidString)","label":"Web","hostname":"web.local","username":"root"}
        """
        let minimalDecoded = try JSONDecoder().decode(
            WidgetHostSnapshot.self,
            from: Data(minimalJSON.utf8)
        )
        XCTAssertEqual(minimalDecoded.id, hostID)
        XCTAssertEqual(minimalDecoded.displayName, "Web")
        XCTAssertEqual(minimalDecoded.tags, [])
        XCTAssertNil(minimalDecoded.lastConnectedAt)
        XCTAssertNil(minimalDecoded.source)
    }

    // MARK: - WidgetAgentStatus & WidgetAgentSnapshot

    func testAgentStatusRawValuesDisplayTitlesAndCodable() throws {
        let expected: [(WidgetAgentStatus, String, String)] = [
            (.running, "running", "Running"),
            (.approval, "approval", "Approval"),
            (.done, "done", "Done"),
            (.idle, "idle", "Idle"),
        ]

        XCTAssertEqual(WidgetAgentStatus.allCases.count, expected.count)

        for (status, rawValue, title) in expected {
            XCTAssertEqual(status.rawValue, rawValue)
            XCTAssertEqual(status.displayTitle, title)
            XCTAssertEqual(WidgetAgentStatus(rawValue: rawValue), status)

            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(WidgetAgentStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testAgentSnapshotIdentityAndCodable() throws {
        let sessionID = UUID()
        let hostID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_750_001_000.25)

        let live = WidgetAgentSnapshot(
            sessionID: sessionID,
            hostID: hostID,
            hostLabel: "Prod Mac Studio",
            sessionName: "termapp-ai-claude-term-app",
            agentSlug: "claude",
            agentName: "Claude Code",
            projectSlug: "term-app",
            status: .approval,
            promptSnippet: "Run swift test? [y/N]",
            updatedAt: updatedAt
        )
        XCTAssertEqual(live.id, "\(hostID.uuidString):termapp-ai-claude-term-app")
        XCTAssertEqual(live.sessionID, sessionID)

        let detached = WidgetAgentSnapshot(
            hostID: hostID,
            hostLabel: "Prod Mac Studio",
            sessionName: "termapp-ai-codex-api",
            agentSlug: "codex",
            agentName: "Codex",
            projectSlug: "api",
            status: .idle,
            updatedAt: updatedAt
        )
        XCTAssertNil(detached.sessionID)
        XCTAssertNil(detached.promptSnippet)
        XCTAssertEqual(detached.id, "\(hostID.uuidString):termapp-ai-codex-api")

        let encoded = try JSONEncoder().encode(live)
        let decoded = try JSONDecoder().decode(WidgetAgentSnapshot.self, from: encoded)
        XCTAssertEqual(decoded, live)

        let set: Set<WidgetAgentSnapshot> = [live, decoded, detached]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - WidgetSnapshotStore

    func testSnapshotStoreConstantsAndRoundTrip() throws {
        XCTAssertEqual(WidgetSnapshotStore.appGroupID, "group.com.peculiarengineer.termapp")
        XCTAssertEqual(WidgetSnapshotStore.hostsStorageKey, "termapp.widget.hosts.v1")
        XCTAssertEqual(WidgetSnapshotStore.agentsStorageKey, "termapp.widget.agents.v1")
        _ = WidgetSnapshotStore.sharedDefaults()

        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        // Empty defaults return empty arrays.
        XCTAssertEqual(WidgetSnapshotStore.loadHosts(defaults: defaults), [])
        XCTAssertEqual(WidgetSnapshotStore.loadAgents(defaults: defaults), [])

        // Corrupt payloads safely fall back to empty arrays.
        defaults.set(Data("corrupt-hosts".utf8), forKey: WidgetSnapshotStore.hostsStorageKey)
        defaults.set(Data("{not-an-array}".utf8), forKey: WidgetSnapshotStore.agentsStorageKey)
        XCTAssertEqual(WidgetSnapshotStore.loadHosts(defaults: defaults), [])
        XCTAssertEqual(WidgetSnapshotStore.loadAgents(defaults: defaults), [])

        let host1 = WidgetHostSnapshot(
            id: UUID(),
            label: "Mac Studio",
            hostname: "studio.local",
            username: "keith",
            tags: ["work", "m2"],
            lastConnectedAt: Date(timeIntervalSince1970: 1_750_000_500),
            source: "manual"
        )
        let host2 = WidgetHostSnapshot(
            id: UUID(),
            label: "",
            hostname: "203.0.113.10",
            username: "root",
            tags: ["cloud"],
            lastConnectedAt: nil,
            source: "digitalocean"
        )

        WidgetSnapshotStore.saveHosts([host1, host2], defaults: defaults)
        XCTAssertEqual(WidgetSnapshotStore.loadHosts(defaults: defaults), [host1, host2])
        // Agents remain unaffected.
        XCTAssertEqual(WidgetSnapshotStore.loadAgents(defaults: defaults), [])

        let agent1 = WidgetAgentSnapshot(
            sessionID: UUID(),
            hostID: host1.id,
            hostLabel: host1.displayName,
            sessionName: "termapp-ai-claude-term-app",
            agentSlug: "claude",
            agentName: "Claude Code",
            projectSlug: "term-app",
            status: .running,
            promptSnippet: nil,
            updatedAt: Date(timeIntervalSince1970: 1_750_002_000)
        )
        let agent2 = WidgetAgentSnapshot(
            sessionID: nil,
            hostID: host2.id,
            hostLabel: host2.displayName,
            sessionName: "termapp-ai-agy-infra",
            agentSlug: "agy",
            agentName: "Antigravity",
            projectSlug: "infra",
            status: .approval,
            promptSnippet: "Apply terraform plan? (y/n)",
            updatedAt: Date(timeIntervalSince1970: 1_750_002_100)
        )
        let agent3 = WidgetAgentSnapshot(
            sessionID: UUID(),
            hostID: host1.id,
            hostLabel: host1.displayName,
            sessionName: "termapp-ai-codex-web",
            agentSlug: "codex",
            agentName: "Codex",
            projectSlug: "web",
            status: .done,
            promptSnippet: "Finished test suite",
            updatedAt: Date(timeIntervalSince1970: 1_750_002_200)
        )
        let agent4 = WidgetAgentSnapshot(
            sessionID: nil,
            hostID: host2.id,
            hostLabel: host2.displayName,
            sessionName: "termapp-ai-aider-docs",
            agentSlug: "aider",
            agentName: "Aider",
            projectSlug: "docs",
            status: .idle,
            promptSnippet: nil,
            updatedAt: Date(timeIntervalSince1970: 1_750_002_300)
        )

        WidgetSnapshotStore.saveAgents([agent1, agent2, agent3, agent4], defaults: defaults)
        XCTAssertEqual(
            WidgetSnapshotStore.loadAgents(defaults: defaults),
            [agent1, agent2, agent3, agent4]
        )
        XCTAssertEqual(WidgetSnapshotStore.loadHosts(defaults: defaults), [host1, host2])

        // Overwriting with empty arrays clears both snapshots cleanly.
        WidgetSnapshotStore.saveHosts([], defaults: defaults)
        WidgetSnapshotStore.saveAgents([], defaults: defaults)
        XCTAssertEqual(WidgetSnapshotStore.loadHosts(defaults: defaults), [])
        XCTAssertEqual(WidgetSnapshotStore.loadAgents(defaults: defaults), [])
    }

    // MARK: - TermAppDeepLink

    func testDeepLinkGenerationAndParseRoundTrip() {
        XCTAssertEqual(TermAppDeepLink.scheme, "termapp")

        let hostID = UUID()
        let sessionID = UUID()

        let connect = TermAppDeepLink.connectHost(hostID: hostID)
        XCTAssertEqual(connect.url.absoluteString, "termapp://host/\(hostID.uuidString)")
        XCTAssertEqual(TermAppDeepLink.parse(connect.url), connect)

        let focus = TermAppDeepLink.focusSession(sessionID: sessionID)
        XCTAssertEqual(focus.url.absoluteString, "termapp://session/\(sessionID.uuidString)")
        XCTAssertEqual(TermAppDeepLink.parse(focus.url), focus)

        let agentsTab = TermAppDeepLink.openAgentsTab
        XCTAssertEqual(agentsTab.url.absoluteString, "termapp://agents")
        XCTAssertEqual(TermAppDeepLink.parse(agentsTab.url), agentsTab)

        let launchFull = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: "claude",
            sessionName: "termapp-ai-claude-term-app"
        )
        XCTAssertEqual(
            launchFull.url.absoluteString,
            "termapp://agent/\(hostID.uuidString)?agent=claude&session=termapp-ai-claude-term-app"
        )
        XCTAssertEqual(TermAppDeepLink.parse(launchFull.url), launchFull)

        let launchSpecialChars = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: "custom agent+1",
            sessionName: "feat/fix & test=1+2? #42 100% 🚀"
        )
        XCTAssertEqual(TermAppDeepLink.parse(launchSpecialChars.url), launchSpecialChars)

        let launchHostOnly = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: nil,
            sessionName: nil
        )
        XCTAssertEqual(launchHostOnly.url.absoluteString, "termapp://agent/\(hostID.uuidString)")
        XCTAssertEqual(TermAppDeepLink.parse(launchHostOnly.url), launchHostOnly)

        let launchAgentOnly = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: "codex",
            sessionName: nil
        )
        XCTAssertEqual(
            launchAgentOnly.url.absoluteString,
            "termapp://agent/\(hostID.uuidString)?agent=codex"
        )
        XCTAssertEqual(TermAppDeepLink.parse(launchAgentOnly.url), launchAgentOnly)

        let launchSessionOnly = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: nil,
            sessionName: "custom session"
        )
        XCTAssertEqual(
            launchSessionOnly.url.absoluteString,
            "termapp://agent/\(hostID.uuidString)?session=custom%20session"
        )
        XCTAssertEqual(TermAppDeepLink.parse(launchSessionOnly.url), launchSessionOnly)

        let launchEmptyStrings = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: "",
            sessionName: ""
        )
        XCTAssertEqual(launchEmptyStrings.url.absoluteString, "termapp://agent/\(hostID.uuidString)")
        XCTAssertEqual(
            TermAppDeepLink.parse(launchEmptyStrings.url),
            .launchAgent(hostID: hostID, agentSlug: nil, sessionName: nil)
        )
    }

    func testDeepLinkParsingCaseInsensitivityAndMalformedURLs() throws {
        let hostID = UUID()
        let sessionID = UUID()

        // Case-insensitive scheme, route, and lowercase UUIDs.
        let upperSchemeURL = try XCTUnwrap(
            URL(string: "TERMAPP://HOST/\(hostID.uuidString.lowercased())")
        )
        XCTAssertEqual(TermAppDeepLink.parse(upperSchemeURL), .connectHost(hostID: hostID))

        let mixedAgentsURL = try XCTUnwrap(URL(string: "TermApp://Agents/"))
        XCTAssertEqual(TermAppDeepLink.parse(mixedAgentsURL), .openAgentsTab)

        let trailingSlashSessionURL = try XCTUnwrap(
            URL(string: "termapp://session/\(sessionID.uuidString.lowercased())/")
        )
        XCTAssertEqual(
            TermAppDeepLink.parse(trailingSlashSessionURL),
            .focusSession(sessionID: sessionID)
        )

        let encodedAgentURL = try XCTUnwrap(
            URL(string: "termapp://agent/\(hostID.uuidString)?agent=&session=my%20repo%26dev%3D1")
        )
        XCTAssertEqual(
            TermAppDeepLink.parse(encodedAgentURL),
            .launchAgent(hostID: hostID, agentSlug: nil, sessionName: "my repo&dev=1")
        )

        // Malformed URLs must return nil.
        let invalidURLStrings = [
            "https://host/\(hostID.uuidString)",
            "http://agents",
            "ssh://host/\(hostID.uuidString)",
            "termapp://",
            "termapp:///host/\(hostID.uuidString)",
            "termapp:///agents",
            "termapp:agents",
            "termapp://unknown/\(hostID.uuidString)",
            "termapp://host",
            "termapp://host/",
            "termapp://host/not-a-uuid",
            "termapp://host/\(hostID.uuidString)/extra",
            "termapp://agent",
            "termapp://agent/",
            "termapp://agent/invalid-uuid?agent=claude",
            "termapp://agent/\(hostID.uuidString)/extra?agent=claude",
            "termapp://session",
            "termapp://session/",
            "termapp://session/bad-uuid",
            "termapp://session/\(sessionID.uuidString)/extra",
            "termapp://agents/extra",
            "termapp://user@host/\(hostID.uuidString)",
            "termapp://host:8080/\(hostID.uuidString)",
        ]

        for raw in invalidURLStrings {
            let url = try XCTUnwrap(URL(string: raw), "Expected valid URL syntax for test fixture: \(raw)")
            XCTAssertNil(TermAppDeepLink.parse(url), "Expected nil for malformed deep link: \(raw)")
        }
    }
}
