import CryptoKit
import Foundation

public enum PropertyListValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([PropertyListValue])
    case dictionary([String: PropertyListValue])

    public static func decode(_ data: Data) throws -> PropertyListValue {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return try fromFoundation(object)
    }

    public static func fromFoundation(_ object: Any) throws -> PropertyListValue {
        switch object {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            // CFBoolean is an NSNumber subclass, so inspect its type first.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            }
            return .integer(value.intValue)
        case let value as [Any]:
            return .array(try value.map(fromFoundation))
        case let value as [String: Any]:
            return .dictionary(try value.mapValues(fromFoundation))
        default:
            throw PropertyListError.unsupportedType(String(describing: type(of: object)))
        }
    }

    public func xmlData() -> Data {
        let header = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        let body = xml(indentation: 0)
        return Data((header + body + "\n</plist>\n").utf8)
    }

    public var fingerprint: String {
        SHA256.hash(data: xmlData()).map { String(format: "%02x", $0) }.joined()
    }

    private func xml(indentation: Int) -> String {
        let pad = String(repeating: "  ", count: indentation)
        switch self {
        case .string(let value):
            return "\(pad)<string>\(value.xmlEscaped)</string>"
        case .integer(let value):
            return "\(pad)<integer>\(value)</integer>"
        case .boolean(let value):
            return "\(pad)<\(value ? "true" : "false")/>"
        case .array(let values):
            guard !values.isEmpty else { return "\(pad)<array/>" }
            let content = values.map { $0.xml(indentation: indentation + 1) }.joined(separator: "\n")
            return "\(pad)<array>\n\(content)\n\(pad)</array>"
        case .dictionary(let values):
            guard !values.isEmpty else { return "\(pad)<dict/>" }
            let content = values.keys.sorted().map { key in
                "\(String(repeating: "  ", count: indentation + 1))<key>\(key.xmlEscaped)</key>\n\(values[key]!.xml(indentation: indentation + 1))"
            }.joined(separator: "\n")
            return "\(pad)<dict>\n\(content)\n\(pad)</dict>"
        }
    }
}

public enum PropertyListError: LocalizedError, Equatable {
    case unsupportedType(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type): return "Unsupported property-list type: \(type)"
        }
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
