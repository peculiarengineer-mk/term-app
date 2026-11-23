import Foundation

/// SSH wire encoding for `ecdsa-sha2-nistp256` public keys and signatures.
public enum SSHECDSA {
    public static let algorithm = "ecdsa-sha2-nistp256"
    public static let curve = "nistp256"

    /// `string "ecdsa-sha2-nistp256" || string "nistp256" || string point` (65-byte uncompressed point).
    public static func publicKeyBlob(x963 point: Data) -> Data {
        var w = OpenSSHKeyFormat.Writer()
        w.string(Data(algorithm.utf8)); w.string(Data(curve.utf8)); w.string(point)
        return w.data
    }

    public static func publicLine(x963 point: Data, comment: String) -> String {
        OpenSSHKeyFormat.publicLine(blob: publicKeyBlob(x963: point), type: algorithm, comment: comment)
    }

    /// Converts CryptoKit's 64-byte `r || s` into `mpint(r) || mpint(s)`.
    public static func signatureBlob(rawRS: Data) -> Data {
        let b = Array(rawRS)
        precondition(b.count == 64, "expected 64-byte r||s")
        var w = OpenSSHKeyFormat.Writer()
        w.string(mpint(Array(b[0..<32])))
        w.string(mpint(Array(b[32..<64])))
        return w.data
    }

    /// Inverse of `signatureBlob`: returns the 64-byte `r || s`.
    public static func rawRS(fromSignatureBlob blob: Data) throws -> Data {
        var r = OpenSSHKeyFormat.Reader(data: blob, pos: 0)
        let rr = try r.string()
        let ss = try r.string()
        guard r.pos == blob.count else { throw KeyFormatError.malformed("trailing signature bytes") }
        return try fixed32(rr) + fixed32(ss)
    }

    static func mpint(_ be: [UInt8]) -> Data {
        let stripped = Array(be.drop { $0 == 0 })
        guard let first = stripped.first else { return Data() }
        return Data(first & 0x80 != 0 ? [0] + stripped : stripped)
    }

    private static func fixed32(_ d: Data) throws -> Data {
        var b = Array(d)
        if let first = b.first {
            guard first & 0x80 == 0 else {
                throw KeyFormatError.malformed("negative mpint")
            }
            if first == 0 {
                guard b.count >= 2, b[1] & 0x80 != 0 else {
                    throw KeyFormatError.malformed("non-canonical mpint")
                }
                b.removeFirst()
            }
        }
        guard b.count <= 32 else { throw KeyFormatError.malformed("mpint too large") }
        return Data([UInt8](repeating: 0, count: 32 - b.count) + b)
    }
}
