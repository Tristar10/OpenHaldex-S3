import Foundation

/// Loose JSON accessor, so views can read the firmware's API responses the
/// same way the web UI's JavaScript does (`status["can"]["ready"].bool`).
struct JSON {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) {
        raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    subscript(key: String) -> JSON { JSON((raw as? [String: Any])?[key]) }
    subscript(index: Int) -> JSON {
        guard let a = raw as? [Any], index >= 0, index < a.count else { return JSON(nil) }
        return JSON(a[index])
    }

    var isNull: Bool { raw == nil || raw is NSNull }
    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
    var stringValue: String { string ?? "" }
    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    var int: Int? { double.map { Int($0.rounded()) } }
    var intValue: Int { int ?? 0 }
    var doubleValue: Double { double ?? 0 }
    var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s == "true" || s == "1" }
        return nil
    }
    var boolValue: Bool { bool ?? false }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var dict: [String: JSON] { ((raw as? [String: Any]) ?? [:]).mapValues(JSON.init) }
    var keys: [String] { ((raw as? [String: Any]) ?? [:]).keys.sorted() }

    /// Short human display of a scalar value.
    var display: String {
        switch raw {
        case nil, is NSNull: return "—"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "yes" : "no" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(format: "%.2f", d)
        case let s as String: return s.isEmpty ? "—" : s
        case let a as [Any]: return "[\(a.count)]"
        case is [String: Any]: return "{…}"
        default: return "\(raw!)"
        }
    }
}
