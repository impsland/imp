import CommonCrypto
import Foundation

/// A proof-of-work challenge from the Den, in the shape of ALTCHA v2 (PBKDF2). The Den signs it, so
/// it can't be made up, and it expires. Solving one costs an Imp a moment of work, and a flood of
/// fake accounts a lot of it.
///
/// The fields are exactly the ones the server's `altcha` crate reads and writes. The Den checks the
/// signature over them, so they go back unchanged, nothing added and nothing left out.
public struct AltchaChallenge: Codable, Equatable, Sendable {
    public struct Parameters: Codable, Equatable, Sendable {
        public var algorithm: String
        public var cost: Int
        public var data: [String: JSONValue]?
        public var expiresAt: Int?
        public var keyLength: Int
        public var keyPrefix: String
        public var keySignature: String?
        public var memoryCost: Int?
        public var nonce: String
        public var parallelism: Int?
        public var salt: String

        public init(algorithm: String, cost: Int, data: [String: JSONValue]? = nil, expiresAt: Int? = nil, keyLength: Int,
                    keyPrefix: String, keySignature: String? = nil, memoryCost: Int? = nil, nonce: String,
                    parallelism: Int? = nil, salt: String) {
            self.algorithm = algorithm; self.cost = cost; self.data = data; self.expiresAt = expiresAt
            self.keyLength = keyLength; self.keyPrefix = keyPrefix; self.keySignature = keySignature
            self.memoryCost = memoryCost; self.nonce = nonce; self.parallelism = parallelism; self.salt = salt
        }
    }

    public var parameters: Parameters
    public var signature: String?

    public init(parameters: Parameters, signature: String?) {
        self.parameters = parameters
        self.signature = signature
    }
}

/// Solves ALTCHA v2 challenges the way the `altcha` crate does.
///
/// For each counter from 0 up, the key is PBKDF2 (HMAC-SHA-256 unless the algorithm says 384 or 512)
/// of the password (the nonce's bytes followed by the counter as four big-endian bytes) with the
/// salt's bytes, `cost` rounds and `keyLength` bytes. The first key whose hex starts with `keyPrefix`
/// wins. Nonce and salt are hex text, and compared in hex without regard to case.
public enum Altcha {
    public struct Solution: Equatable, Sendable {
        public var counter: UInt32
        /// The key in lowercase hex.
        public var derivedKey: String
    }

    public enum Failure: LocalizedError, Equatable {
        /// The challenge doesn't make sense, or asks for more work than an Imp will do.
        case unusable
        case expired
        /// No answer within the counter or time limit.
        case gaveUp

        public var errorDescription: String? {
            switch self {
            case .unusable: String(localized: "The Den sent a challenge Imp can't solve.")
            case .expired: String(localized: "The Den's challenge ran out before it was solved.")
            case .gaveUp: String(localized: "Solving the Den's challenge took too long.")
            }
        }
    }

    /// The most work asked of an Imp: rounds per key, key bytes, tries and seconds.
    public static let maxCost = 2_000_000
    public static let maxKeyLength = 64
    public static let maxCounter: UInt32 = 5_000_000
    public static let maxSeconds: TimeInterval = 60

    /// Finds the solution on a background thread. Cancelling the task stops the search.
    public static func solve(_ challenge: AltchaChallenge, now: Date = .now) async throws -> Solution {
        let work = Task.detached(priority: .utility) { try search(challenge, now: now) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The payload the Den takes in `altcha`: the challenge and its solution as JSON, in base64.
    public static func payload(_ challenge: AltchaChallenge, _ solution: Solution) throws -> String {
        struct Answer: Encodable { var counter: UInt32; var derivedKey: String }
        struct Payload: Encodable { var challenge: AltchaChallenge; var solution: Answer }
        let json = try JSONEncoder().encode(Payload(challenge: challenge, solution: Answer(counter: solution.counter, derivedKey: solution.derivedKey)))
        return json.base64EncodedString()
    }

    static func search(_ challenge: AltchaChallenge, now: Date) throws -> Solution {
        let p = challenge.parameters
        if let expiresAt = p.expiresAt, expiresAt != 0, Double(expiresAt) < now.timeIntervalSince1970 { throw Failure.expired }
        guard (1...maxCost).contains(p.cost), (1...maxKeyLength).contains(p.keyLength),
              let nonce = bytes(hex: p.nonce), let salt = bytes(hex: p.salt), let prefix = Prefix(p.keyPrefix),
              prefix.nibbles <= p.keyLength * 2 else { throw Failure.unusable }
        let upper = p.algorithm.uppercased()
        let prf = upper == "PBKDF2/SHA-384" ? CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            : upper == "PBKDF2/SHA-512" ? CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            : CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        var password = nonce + [0, 0, 0, 0]
        var key = [UInt8](repeating: 0, count: p.keyLength)
        let started = Date()
        var counter: UInt32 = 0
        while true {
            try Task.checkCancellation()
            if counter > maxCounter || Date().timeIntervalSince(started) > maxSeconds { throw Failure.gaveUp }
            for i in 0..<4 { password[nonce.count + i] = UInt8(truncatingIfNeeded: counter >> UInt32(24 - 8 * i)) }
            let status = password.withUnsafeBufferPointer { pw in
                pw.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) {
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0, pw.count, salt, salt.count, prf, UInt32(p.cost), &key, key.count)
                }
            }
            guard status == kCCSuccess else { throw Failure.unusable }
            if prefix.matches(key) { return Solution(counter: counter, derivedKey: hex(key)) }
            counter += 1
        }
    }

    /// The key prefix: hex digits, so possibly an odd number of them.
    private struct Prefix {
        let values: [UInt8]
        var nibbles: Int { values.count }

        init?(_ text: String) {
            let values = text.utf8.map(Altcha.nibble)
            guard !values.contains(nil) else { return nil }
            self.values = values.compactMap { $0 }
        }

        func matches(_ key: [UInt8]) -> Bool {
            for (i, v) in values.enumerated() where (i.isMultiple(of: 2) ? key[i / 2] >> 4 : key[i / 2] & 15) != v { return false }
            return true
        }
    }

    private static func bytes(hex text: String) -> [UInt8]? {
        let digits = text.utf8.map(nibble)
        guard digits.count.isMultiple(of: 2), !digits.contains(nil) else { return nil }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0]! << 4 | digits[$0 + 1]! }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
