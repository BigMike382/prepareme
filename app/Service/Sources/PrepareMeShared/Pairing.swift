import Foundation

/// What the Mac's pairing code carries (plan section 9: host, port, certificate SHA-256, token, as JSON): the Mac's
/// Bonjour name, its private IPv4 address at pairing time as a fallback, the port, the SHA-256 of its certificate and
/// this phone's token. The token is shown once, on the Mac's screen; the Mac keeps only its SHA-256.
///
/// Version 2 (Unlisted plan, phase 3) is a test service's code (one started with its own `--support` folder); the
/// family's Mac's codes stay exactly version 1. The version, not an extra key, is the mark because the app already on
/// every family device reads only version 1 and ignores keys it doesn't know: it answers a test code "bad version" and
/// keeps its pairing (the lead's review, 2026-11-22). PrepareMe Dev keeps only version 2; this build of the family's
/// app version 1 on a device and either in a simulator (`keptBy`).
public struct PairingCode: Codable, Equatable, Sendable {
    public var v: Int
    public var host: String
    public var ip: String?
    public var port: Int
    public var fp: String
    public var token: String

    public init(host: String, ip: String?, port: Int, fp: String, token: String, test: Bool = false) {
        self.v = test ? 2 : 1
        self.host = host
        self.ip = ip
        self.port = port
        self.fp = fp
        self.token = token
    }

    public var isTest: Bool { v == 2 }

    /// Whether this copy of the app may keep the code (Unlisted plan, phase 3): PrepareMe Dev (`dev`) only a test
    /// service's, so it can never hold the family's Mac's token; the family's PrepareMe only the family's Mac's on a real
    /// device, so a test code scanned by mistake can't replace its pairing and library, but either in a simulator,
    /// where sessions test it against their test services.
    public func keptBy(dev: Bool, simulator: Bool) -> Bool {
        dev ? isTest : !isTest || simulator
    }

    public enum Problem: Error, Equatable, Sendable {
        case notACode, badVersion, badHost, badAddress, badPort, badFingerprint, badToken
    }

    /// The code in `text`, checked: version 1 (or 2, a test service's), a ".local" host name, a private IPv4 address if any, a port, a
    /// SHA-256 and a token of the shape `Token.make` gives. Anything else is refused, so a code from elsewhere can't
    /// point the phone at a public address. Curly quote marks are read as straight ones: a code typed on the phone, or
    /// passed through Notes or Messages, can arrive curled, and no value in a code holds one (remaining-findings plan,
    /// Task 9.3; F46).
    public static func read(_ text: String) throws -> PairingCode {
        let straight = text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        guard let data = straight.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let code = try? JSONDecoder().decode(PairingCode.self, from: data) else { throw Problem.notACode }
        guard code.v == 1 || code.v == 2 else { throw Problem.badVersion }
        guard Self.isLocalName(code.host) else { throw Problem.badHost }
        if let ip = code.ip, !PrivateAddress.isPrivateIPv4(ip) { throw Problem.badAddress }
        guard (1...65535).contains(code.port) else { throw Problem.badPort }
        guard Hex.isSHA256(code.fp) else { throw Problem.badFingerprint }
        guard Token.isWellFormed(code.token) else { throw Problem.badToken }
        return code
    }

    public func text() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// A Bonjour host name: letters, digits and dashes, then ".local".
    static func isLocalName(_ host: String) -> Bool {
        guard host.hasSuffix(".local") else { return false }
        let label = host.dropLast(".local".count)
        return (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && label.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D
        }
    }
}

/// What PrepareMe Dev says on every request to a service (Unlisted plan, phase 3): the family's Mac refuses it, a
/// test service serves it. The family's PrepareMe never sends it.
public enum DevCopy {
    public static let header = "X-PrepareMe-Copy"
    public static let value = "dev"
    /// The family's Mac's answer to it, beside a 403: the app then forgets the pairing.
    public static let refusedHeader = "X-PrepareMe-Refused"
}

/// A phone's token: 32 random bytes as unpadded base64url (43 characters).
public enum Token {
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D
                || $0 == 0x5F
        }
    }
}

/// The addresses the service answers and a pairing code may name (plan: "private addresses only"): IPv4's private
/// ranges (10/8, 172.16/12, 192.168/16), link-local 169.254/16 and loopback 127/8 (the Mac's own tests). The service
/// listens on IPv4 only, so nothing else is ever a question.
public enum PrivateAddress {
    public static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  !(part.count > 1 && part.hasPrefix("0")), let value = UInt8(part) else { return false }
            bytes.append(value)
        }
        return isPrivateIPv4(bytes)
    }

    public static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
