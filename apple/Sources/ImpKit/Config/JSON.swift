import Foundation

/// A JSON value. The shared configuration has open-ended parts (`imp.json` keeps what a version does
/// not know), so the app reads the parts it knows out of this and writes merge patches of the parts it owns.
public enum JSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public init?(text: String) { guard let v = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) else { return nil }; self = v }

    /// The value as JSON text (keys sorted, so equal values give equal text).
    public var text: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// A value of any Codable type, or `.null` when it does not encode.
    public init(encoding value: some Encodable) {
        self = (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) } ?? .null
    }

    /// This value read as `T`, or nil when it does not fit.
    public func decoded<T: Decodable>(_ type: T.Type = T.self) -> T? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var double: Double? { if case .number(let v) = self { v } else { nil } }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var array: [JSON]? { if case .array(let v) = self { v } else { nil } }
    public var object: [String: JSON]? { if case .object(let v) = self { v } else { nil } }

    public static func optional(_ v: String?) -> JSON { v.map(JSON.string) ?? .null }
    public static func optional(_ v: Double?) -> JSON { v.map(JSON.number) ?? .null }
    public static func optional(_ v: Int?) -> JSON { v.map { .number(Double($0)) } ?? .null }
    public static func optional(_ v: Bool?) -> JSON { v.map(JSON.bool) ?? .null }

    /// RFC 7396, as the core applies it: objects merge, `null` removes a key, anything else replaces.
    public func merged(with patch: JSON) -> JSON {
        guard case .object(let p) = patch else { return patch }
        var out: [String: JSON] = object ?? [:]
        for (k, v) in p {
            if case .null = v { out[k] = nil } else { out[k] = (out[k] ?? .null).merged(with: v) }
        }
        return .object(out)
    }

    /// The part of this merge patch that would change `base`: what is already there is left out, so a
    /// field the person did not touch is never written (and what someone else changed in it stays). Nil when
    /// nothing is left.
    public func pruned(against base: JSON?) -> JSON? {
        switch self {
        case .object(let patch):
            guard let baseObject = base?.object else { return patch.isEmpty ? nil : self }
            var out: [String: JSON] = [:]
            for (key, value) in patch {
                if let kept = value.pruned(against: baseObject[key]) { out[key] = kept }
            }
            return out.isEmpty ? nil : .object(out)
        case .null:
            return base == nil ? nil : self
        default:
            return self == base ? nil : self
        }
    }
}
