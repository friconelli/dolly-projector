import Foundation

func log(_ a: Any...) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write((f.string(from: Date()) + " " + a.map { "\($0)" }.joined(separator: " ") + "\n").data(using: .utf8)!)
}

struct DollyError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// JSON generico (per le preferenze e per leggere lo stato che arriva dal motore).
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), num(Double), str(String), arr([JSONValue]), obj([String: JSONValue])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .num(n) }
        else if let s = try? c.decode(String.self) { self = .str(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .arr(a) }
        else { self = .obj(try c.decode([String: JSONValue].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let b): try c.encode(b); case .num(let n): try c.encode(n)
        case .str(let s): try c.encode(s); case .arr(let a): try c.encode(a); case .obj(let o): try c.encode(o) }
    }
    var d: Double? { if case .num(let n) = self { return n }; if case .bool(let b) = self { return b ? 1 : 0 }; return nil }
    var b: Bool? { if case .bool(let b) = self { return b }; if case .num(let n) = self { return n != 0 }; return nil }
    var s: String? { if case .str(let s) = self { return s }; if case .num(let n) = self { return String(n) }; return nil }
    var any: Any {
        switch self { case .null: return NSNull(); case .bool(let b): return b; case .num(let n): return n; case .str(let s): return s
        case .arr(let a): return a.map { $0.any }; case .obj(let o): return o.mapValues { $0.any } }
    }
    static func from(_ x: Any?) -> JSONValue {
        guard let x = x, !(x is NSNull) else { return .null }
        if let n = x as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .num(n.doubleValue) }
        if let s = x as? String { return .str(s) }
        if let a = x as? [Any] { return .arr(a.map { from($0) }) }
        if let o = x as? [String: Any] { return .obj(o.mapValues { from($0) }) }
        return .null
    }
}

// Lettura "tollerante" dei valori che arrivano da mpv / dal telecomando (NSNumber, stringhe…)
func asBool(_ x: Any?) -> Bool? {
    guard let n = x as? NSNumber else { return x as? Bool }
    return n.boolValue
}
func asDouble(_ x: Any?) -> Double? {
    if let n = x as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue }
    if let s = x as? String { return Double(s) }
    return nil
}
func asInt(_ x: Any?) -> Int? { asDouble(x).map { Int($0) } }
func asString(_ x: Any?) -> String? { if let s = x as? String { return s }; if let n = x as? NSNumber { return n.stringValue }; return nil }
