import Foundation

// MARK: - 宽容 Codable 解码(P2-A1)
//
// 上游接口数值字段类型不稳定:同一字段在不同响应里可能是 Int/Double/
// 数字字符串("58")。此前 [String:Any] 手写取数用 NSNumber 统一兜底;
// 迁移 Codable 后由这些属性包装器承担同样的宽容语义:
//   缺失/null → nil;数字 → 数值;数字字符串 → 数值;垃圾 → nil(该字段按缺省处理)

/// Int64 宽容解码:Int/Double/数字字符串 → Int64;非整数 Double 截断为整数。
@propertyWrapper
public struct FlexibleInt64: Codable, Equatable {
    public var wrappedValue: Int64?
    public init(wrappedValue: Int64?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil; return }
        if let v = try? c.decode(Int64.self) { wrappedValue = v; return }
        if let v = try? c.decode(Double.self) {
            wrappedValue = v == v.rounded() ? Int64(v) : Int64(v)   // 非整数截断
            return
        }
        if let s = try? c.decode(String.self) {
            wrappedValue = Int64(s) ?? Double(s).map { Int64($0) }
            return
        }
        wrappedValue = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Double 宽容解码:Int/Double/数字字符串 → Double。
@propertyWrapper
public struct FlexibleDouble: Codable, Equatable {
    public var wrappedValue: Double?
    public init(wrappedValue: Double?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil; return }
        if let v = try? c.decode(Double.self) { wrappedValue = v; return }
        if let v = try? c.decode(Int64.self) { wrappedValue = Double(v); return }
        if let s = try? c.decode(String.self) { wrappedValue = Double(s); return }
        wrappedValue = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Bool 宽容解码:Bool/0/1/"true"/"false"。
@propertyWrapper
public struct FlexibleBool: Codable, Equatable {
    public var wrappedValue: Bool?
    public init(wrappedValue: Bool?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil; return }
        if let v = try? c.decode(Bool.self) { wrappedValue = v; return }
        if let v = try? c.decode(Int64.self) { wrappedValue = v != 0; return }
        if let s = try? c.decode(String.self) {
            switch s.lowercased() {
            case "true", "1", "yes": wrappedValue = true
            case "false", "0", "no": wrappedValue = false
            default: wrappedValue = nil
            }
            return
        }
        wrappedValue = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}
