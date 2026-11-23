import XCTest
@testable import Store

final class SnippetAndSSHConfigTests: XCTestCase {
    func testCommandSnippetPayloadBytes() {
        let basic = CommandSnippet(name: "Status", command: "git status")
        XCTAssertEqual(basic.payloadBytes, Array("git status\r".utf8))

        let noNewline = CommandSnippet(name: "Prefix", command: "kubectl get ", appendNewline: false)
        XCTAssertEqual(noNewline.payloadBytes, Array("kubectl get ".utf8))

        let trailingCR = CommandSnippet(name: "CR", command: "ls\r", appendNewline: true)
        XCTAssertEqual(trailingCR.payloadBytes, Array("ls\r".utf8))

        let trailingLF = CommandSnippet(name: "LF", command: "ls\n", appendNewline: true)
        XCTAssertEqual(trailingLF.payloadBytes, Array("ls\n".utf8))

        let trailingCRLF = CommandSnippet(name: "CRLF", command: "ls\r\n", appendNewline: true)
        XCTAssertEqual(trailingCRLF.payloadBytes, Array("ls\r\n".utf8))

        let emptyWithNewline = CommandSnippet(name: "Enter", command: "", appendNewline: true)
        XCTAssertEqual(emptyWithNewline.payloadBytes, [0x0D])

        let emptyNoNewline = CommandSnippet(name: "Empty", command: "", appendNewline: false)
        XCTAssertTrue(emptyNoNewline.payloadBytes.isEmpty)
    }

    func testSnippetStoreLoadSaveAndEmptyPersistence() {
        let suiteName = "termapp.tests.snippets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // First load returns the 4 starter snippets when key has never been written.
        let initial = SnippetStore.load(defaults: defaults)
        XCTAssertEqual(initial, SnippetStore.starterSnippets)
        XCTAssertEqual(initial.map(\.name), ["Docker PS", "Git Status", "Disk Usage", "System Logs"])
        XCTAssertEqual(initial.map(\.command), ["docker ps", "git status", "df -h", "journalctl -n 50 --no-pager"])

        // Saving custom snippets persists across loads.
        let custom = [
            CommandSnippet(name: "Top", command: "htop", appendNewline: true),
            CommandSnippet(name: "Tail", command: "tail -f /var/log/syslog", appendNewline: false),
        ]
        SnippetStore.save(custom, defaults: defaults)
        XCTAssertEqual(SnippetStore.load(defaults: defaults), custom)

        // Explicitly deleting all snippets persists [] instead of falling back to starterSnippets.
        SnippetStore.save([], defaults: defaults)
        XCTAssertEqual(SnippetStore.load(defaults: defaults), [])
    }

    func testSSHConfigParserMultiHostCommentsKeyValueAndIdentityFile() {
        let config = """
        # Global comment
        Host prod # inline comment
            HostName 10.0.1.50
            User deploy # user comment
            Port=2222
            IdentityFile "~/.ssh/id_prod#1"

        Host staging
            HostName=staging.example.com
            User = ubuntu
            IdentityFile ~/.ssh/id_ed25519
        """

        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 2)

        XCTAssertEqual(entries[0].alias, "prod")
        XCTAssertEqual(entries[0].hostname, "10.0.1.50")
        XCTAssertEqual(entries[0].username, "deploy")
        XCTAssertEqual(entries[0].port, 2222)
        XCTAssertEqual(entries[0].identityFile, "~/.ssh/id_prod#1")

        XCTAssertEqual(entries[1].alias, "staging")
        XCTAssertEqual(entries[1].hostname, "staging.example.com")
        XCTAssertEqual(entries[1].username, "ubuntu")
        XCTAssertEqual(entries[1].port, 22)
        XCTAssertEqual(entries[1].identityFile, "~/.ssh/id_ed25519")
    }

    func testSSHConfigParserWildcardsHostStarDefaultsAndValidation() {
        let config = """
        Host *
            User defaultuser
            Port 2022
            IdentityFile ~/.ssh/id_default

        Host *.internal ?box !excluded
            User wildcarduser
            Port 9999

        Host web1 web2 *.web.internal
            HostName 192.168.10.5

        Host db
            HostName db.internal
            User postgres
            Port 5432
            IdentityFile ~/.ssh/id_db

        Host badport-high
            HostName 10.0.0.8
            Port 70000

        Host badport-zero
            HostName 10.0.0.9
            Port 0

        Host badport-alpha
            HostName 10.0.0.10
            Port notanumber

        Host app.example.org
            User appuser

        Host 172.16.0.4
            Port 2200

        Host omitted-host
            User orphan

        Host empty-host
            HostName ""
            User orphan2

        Match host db exec "true"
            User matchuser
            Port 3333
        """

        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.map(\.alias), [
            "web1",
            "web2",
            "db",
            "badport-high",
            "badport-zero",
            "badport-alpha",
            "app.example.org",
            "172.16.0.4",
        ])

        // web1 & web2 inherit Host * defaults
        XCTAssertEqual(entries[0].hostname, "192.168.10.5")
        XCTAssertEqual(entries[0].username, "defaultuser")
        XCTAssertEqual(entries[0].port, 2022)
        XCTAssertEqual(entries[0].identityFile, "~/.ssh/id_default")

        XCTAssertEqual(entries[1].hostname, "192.168.10.5")
        XCTAssertEqual(entries[1].username, "defaultuser")
        XCTAssertEqual(entries[1].port, 2022)

        // db overrides Host * defaults and ignores subsequent Match block
        XCTAssertEqual(entries[2].hostname, "db.internal")
        XCTAssertEqual(entries[2].username, "postgres")
        XCTAssertEqual(entries[2].port, 5432)
        XCTAssertEqual(entries[2].identityFile, "~/.ssh/id_db")

        // Invalid ports are ignored -> fall back to Host * port (2022)
        XCTAssertEqual(entries[3].port, 2022)
        XCTAssertEqual(entries[4].port, 2022)
        XCTAssertEqual(entries[5].port, 2022)

        // Omitted HostName falls back to alias when alias looks like a hostname or IP
        XCTAssertEqual(entries[6].hostname, "app.example.org")
        XCTAssertEqual(entries[6].username, "appuser")
        XCTAssertEqual(entries[7].hostname, "172.16.0.4")
        XCTAssertEqual(entries[7].port, 2200)
    }

    func testSSHConfigParserDefaultsPort22WithoutHostStarAndHandlesTrailingHostStar() {
        let config = """
        Host alpha
            HostName 10.1.1.1
            Port 65535

        Host beta
            HostName 10.1.1.2
            Port 99999

        Host *
            User fallback
        """

        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].port, 65535)
        XCTAssertEqual(entries[0].username, "fallback")
        XCTAssertEqual(entries[1].port, 22)
        XCTAssertEqual(entries[1].username, "fallback")
    }
}
