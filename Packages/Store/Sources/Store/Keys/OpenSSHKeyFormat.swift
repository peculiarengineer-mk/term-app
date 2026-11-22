import Foundation

public enum KeyFormatError: Error, Equatable, Sendable {
    case malformed(String)
    case unsupported(String)
}

/// Result of inspecting key text. `publicKeyLine` is nil when it cannot be derived without decrypting.
public struct ParsedKey: Equatable, Sendable {
    public var type: KeyType
    public var isEncrypted: Bool
    public var publicKeyLine: String?
    public var comment: String
}

public enum OpenSSHKeyFormat {
    private static let magic = Data("openssh-key-v1\0".utf8)
    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"

    // MARK: writing

    public static func publicBlob(ed25519 publicKey: Data) -> Data {
        var w = Writer()
        w.string(Data("ssh-ed25519".utf8)); w.string(publicKey)
        return w.data
    }

    public static func publicLine(blob: Data, type: String, comment: String) -> String {
        let base = "\(type) \(blob.base64EncodedString())"
        return comment.isEmpty ? base : base + " " + comment
    }

    public static func ed25519PublicLine(publicKey: Data, comment: String) -> String {
        publicLine(blob: publicBlob(ed25519: publicKey), type: "ssh-ed25519", comment: comment)
    }

    /// Unencrypted `openssh-key-v1` Ed25519 private key (PEM-armoured).
    public static func ed25519PrivateKey(seed: Data, publicKey: Data, comment: String, checkInt: UInt32) -> String {
        var priv = Writer()
        priv.uint32(checkInt); priv.uint32(checkInt)
        priv.string(Data("ssh-ed25519".utf8))
        priv.string(publicKey)
        priv.string(seed + publicKey)
        priv.string(Data(comment.utf8))
        var pad: UInt8 = 1
        while priv.data.count % 8 != 0 { priv.data.append(pad); pad += 1 }

        var w = Writer()
        w.data = magic
        w.string(Data("none".utf8)); w.string(Data("none".utf8)); w.string(Data())
        w.uint32(1)
        w.string(publicBlob(ed25519: publicKey))
        w.string(priv.data)

        let b64 = w.data.base64EncodedString()
        var lines = [begin]
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j])); i = j
        }
        lines.append(end)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: parsing

    /// Inspects OpenSSH or PEM (RSA / EC) private key text. Never decrypts.
    public static func parse(_ text: String) throws -> ParsedKey {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix(begin) { return try parseOpenSSH(t) }
        if t.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") { return try parsePEM(t, rsa: true) }
        if t.hasPrefix("-----BEGIN EC PRIVATE KEY-----") { return try parsePEM(t, rsa: false) }
        if t.hasPrefix("-----BEGIN") { throw KeyFormatError.unsupported("unsupported key format; convert with ssh-keygen -p -m PEM or use OpenSSH format") }
        throw KeyFormatError.malformed("not a private key")
    }

    private static func body(_ t: String) -> (headers: [String], data: Data?) {
        var headers: [String] = []; var b64 = ""
        for line in t.split(whereSeparator: \.isNewline).dropFirst() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("-----END") { break }
            if l.contains(":") { headers.append(l) } else { b64 += l }
        }
        return (headers, Data(base64Encoded: b64))
    }

    private static func parseOpenSSH(_ t: String) throws -> ParsedKey {
        guard let raw = body(t).data, raw.starts(with: magic) else { throw KeyFormatError.malformed("bad openssh-key-v1 body") }
        var r = Reader(data: raw, pos: magic.count)
        do {
            let cipher = String(decoding: try r.string(), as: UTF8.self)
            _ = try r.string(); _ = try r.string()
            guard try r.uint32() == 1 else { throw KeyFormatError.unsupported("multiple keys in one file") }
            let blob = try r.string()
            var br = Reader(data: blob, pos: 0)
            let typeName = String(decoding: try br.string(), as: UTF8.self)
            let type: KeyType
            switch typeName {
            case "ssh-ed25519": type = .ed25519
            case "ssh-rsa": type = .rsa
            case let n where n.hasPrefix("ecdsa-sha2-"): type = .ecdsa
            default: throw KeyFormatError.unsupported("key type \(typeName)")
            }
            let encrypted = cipher != "none"
            var comment = ""
            if !encrypted {
                var pr = Reader(data: try r.string(), pos: 0)
                let a = try pr.uint32(), b = try pr.uint32()
                guard a == b else { throw KeyFormatError.malformed("check integers differ") }
                _ = try pr.string()
                switch type {
                case .ed25519: _ = try pr.string(); _ = try pr.string()
                case .ecdsa: _ = try pr.string(); _ = try pr.string(); _ = try pr.string()
                case .rsa: for _ in 0..<6 { _ = try pr.string() }
                }
                comment = String(decoding: try pr.string(), as: UTF8.self)
            }
            return ParsedKey(type: type, isEncrypted: encrypted,
                             publicKeyLine: publicLine(blob: blob, type: typeName, comment: comment),
                             comment: comment)
        } catch let e as KeyFormatError { throw e }
    }

    private static func parsePEM(_ t: String, rsa: Bool) throws -> ParsedKey {
        let (headers, data) = body(t)
        let type: KeyType = rsa ? .rsa : .ecdsa
        if headers.contains(where: { $0.hasPrefix("Proc-Type") && $0.contains("ENCRYPTED") }) {
            return ParsedKey(type: type, isEncrypted: true, publicKeyLine: nil, comment: "")
        }
        guard let der = data else { throw KeyFormatError.malformed("bad base64") }
        var seq = try DER.read(der, expect: 0x30)
        let version = try DER.next(&seq, expect: 0x02)
        _ = version
        if rsa {
            let n = try DER.next(&seq, expect: 0x02), e = try DER.next(&seq, expect: 0x02)
            var w = Writer()
            w.string(Data("ssh-rsa".utf8)); w.string(e); w.string(n)
            return ParsedKey(type: .rsa, isEncrypted: false, publicKeyLine: publicLine(blob: w.data, type: "ssh-rsa", comment: ""), comment: "")
        }
        _ = try DER.next(&seq, expect: 0x04)
        let params = try DER.next(&seq, expect: 0xA0)
        // Named curve: identified by OID. Explicit parameters (SEQUENCE): identified by point size.
        let oidCurves: [[UInt8]: String] = [
            [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: "nistp256",  // 1.2.840.10045.3.1.7
            [0x2B, 0x81, 0x04, 0x00, 0x22]: "nistp384",                      // 1.3.132.0.34
            [0x2B, 0x81, 0x04, 0x00, 0x23]: "nistp521",                      // 1.3.132.0.35
        ]
        var namedCurve: String?
        if params.first == 0x06 {
            let oid = try DER.read(params, expect: 0x06)
            guard let c = oidCurves[Array(oid)] else { throw KeyFormatError.unsupported("EC curve") }
            namedCurve = c
        }
        var pubWrap = try DER.next(&seq, expect: 0xA1)
        let bits = try DER.next(&pubWrap, expect: 0x03)
        let point = bits.dropFirst()  // unused-bits byte
        let curves: [Int: String] = [65: "nistp256", 97: "nistp384", 133: "nistp521"]
        guard let curve = namedCurve ?? curves[point.count] else { throw KeyFormatError.unsupported("EC curve") }
        guard curves[point.count] == curve else { throw KeyFormatError.malformed("EC point size does not match curve") }
        var w = Writer()
        w.string(Data("ecdsa-sha2-\(curve)".utf8)); w.string(Data(curve.utf8)); w.string(Data(point))
        return ParsedKey(type: .ecdsa, isEncrypted: false,
                         publicKeyLine: publicLine(blob: w.data, type: "ecdsa-sha2-\(curve)", comment: ""), comment: "")
    }

    // MARK: byte helpers

    struct Writer {
        var data = Data()
        mutating func uint32(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        mutating func string(_ d: Data) { uint32(UInt32(d.count)); data.append(d) }
    }

    struct Reader {
        let data: Data
        var pos: Int
        mutating func uint32() throws -> UInt32 {
            guard pos + 4 <= data.count else { throw KeyFormatError.malformed("truncated") }
            let s = data.startIndex + pos
            pos += 4
            return data[s..<s + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func string() throws -> Data {
            let n = Int(try uint32())
            guard n <= data.count - pos else { throw KeyFormatError.malformed("truncated") }
            let s = data.startIndex + pos
            pos += n
            return Data(data[s..<s + n])
        }
    }

    enum DER {
        /// Reads one TLV from the start of `d`, returning its content.
        static func read(_ d: Data, expect tag: UInt8) throws -> Data {
            var d = d
            return try next(&d, expect: tag)
        }
        /// Consumes one TLV from the front of `d`.
        static func next(_ d: inout Data, expect tag: UInt8) throws -> Data {
            let b = Array(d)
            guard b.count >= 2, b[0] == tag else { throw KeyFormatError.malformed("unexpected DER tag") }
            var len = Int(b[1]); var off = 2
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n >= 1, n <= 3, b.count >= 2 + n else { throw KeyFormatError.malformed("bad DER length") }
                len = b[2..<2 + n].reduce(0) { $0 << 8 | Int($1) }; off = 2 + n
            }
            guard b.count >= off + len else { throw KeyFormatError.malformed("truncated DER") }
            d = Data(b[(off + len)...])
            return Data(b[off..<off + len])
        }
    }
}
