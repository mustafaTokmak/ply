import Foundation

/// A JSON value. Every action takes `Params` and returns a `JSONValue`, so the
/// app, the HTTP API, the CLI and the MCP server all speak the same format.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONCoding.encoder.encode(value)
        self = try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }

    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: JSONCoding.encoder.encode(self))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int? { doubleValue.flatMap { $0.isFinite ? Int($0) : nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    public func pretty() -> String {
        guard let data = try? JSONCoding.prettyEncoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public func compact() -> String {
        guard let data = try? JSONCoding.encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

public typealias Params = [String: JSONValue]

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var prettyEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Errors carry a machine-readable code and, when there is one, the action that fixes them.
public enum PlyError: Error, CustomStringConvertible, Sendable {
    case badRequest(String)
    case needsHelper(String)
    case unavailable(String)
    case failed(String)

    public var code: String {
        switch self {
        case .badRequest: return "bad_request"
        case .needsHelper: return "needs_helper"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }

    public var message: String {
        switch self {
        case .badRequest(let m), .needsHelper(let m), .unavailable(let m), .failed(let m): return m
        }
    }

    public var description: String { message }

    public var fix: ActionID? {
        if case .needsHelper = self { return .installHelper }
        return nil
    }

    public var httpStatus: Int {
        switch self {
        case .badRequest: return 400
        case .needsHelper: return 409
        case .unavailable: return 503
        case .failed: return 500
        }
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["ok": .bool(false), "error": .string(message), "code": .string(code)]
        if let fix { o["fix"] = .string(fix.rawValue) }
        return .object(o)
    }

    public static func wrap(_ error: Error) -> PlyError {
        if let e = error as? PlyError { return e }
        return .failed("\(error)")
    }
}
