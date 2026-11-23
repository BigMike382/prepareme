import Foundation

/// The barcode lookup's two keys as the Mac hands them to an adult's paired device (Unlisted plan, phase 4, decision
/// 4): the Mac app keeps getting them at its own install (kiwix-mac/build.sh), its service reads them from that app's
/// Info.plist and answers `path` with them; the device keeps them in its Keychain, this device only, and prefers them
/// to any built in. Either may be absent; USDA's public DEMO_KEY counts as none. Never logged or listed: the service
/// logs a request's address and status only.
public struct LookupKeys: Codable, Equatable, Sendable {
    public static let path = "/lookup-keys.json"
    public var usda: String?
    public var upcdb: String?

    public init(usda: String? = nil, upcdb: String? = nil) {
        self.usda = Self.key(usda)
        self.upcdb = Self.key(upcdb)
    }

    /// Letters and digits only, up to 200; anything else (an unfilled `$(…)` setting, the demo key) is no key.
    static func key(_ text: String?) -> String? {
        let key = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 200, key != ProductLookup.demoKey,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return key
    }

    /// The keys in an Info.plist's entries (the Mac app's own, read by its service).
    public init(info: [String: Any]) {
        self.init(usda: info[ProductLookup.keyEntry] as? String, upcdb: info[ProductLookup.upcdbKeyEntry] as? String)
    }

    /// The Mac's answer (or a test service's made-up file): a key of another shape is dropped, never kept.
    public static func read(_ data: Data) throws -> LookupKeys {
        guard data.count <= 4096, let found = try? JSONDecoder().decode(LookupKeys.self, from: data) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return LookupKeys(usda: found.usda, upcdb: found.upcdb)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
