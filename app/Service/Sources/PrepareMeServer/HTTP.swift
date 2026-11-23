import Foundation
import PrepareMeShared

/// The little HTTP/1.1 the service speaks: one request per connection, then it closes. Only what a phone's
/// URLSession sends is read; anything else is refused with a status and no body.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]  // names in lower case
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum HeadParse: Equatable, Sendable {
    case needMore
    case request(HTTPRequest, bodyLength: Int, headLength: Int)
    case refused(Int)
}

public enum HTTP {
    public static let maxHead = 8192
    public static let maxBody = 1024
    /// A phone's inventory edits (plan phase 7, slice 5) are the one larger body, on their one path.
    public static let editsPath = "/inventory/edits"
    public static let maxEditsBody = 256 * 1024
    /// A phone's room report (phase M) names every file it holds and waits for: its own limit, on its one path
    public static let storagePath = "/storage"
    public static let maxStorageBody = PhoneStorage.maxBytes
    /// Essential Documents (phase 3): a phone's encrypted outbox, and each piece of an added file, have their own limits
    public static let documentsPrefix = "/documents/"
    public static let documentsChangesPath = "/documents/changes"
    public static let documentsUploadPrefix = "/documents/upload/"
    public static let haveHeader = "X-PrepareMe-Have"

    static func bodyLimit(_ path: Substring) -> Int {
        if path == editsPath { return maxEditsBody }
        if path == storagePath { return maxStorageBody }
        if path == documentsChangesPath { return DocumentOutbox.maxBytes }
        if path.hasPrefix(documentsUploadPrefix) { return DocumentInbox.maxPiece }
        return maxBody
    }

    /// The request in `buffer` once its head is whole. A head over 8 KB, a request line or header that isn't plain
    /// HTTP/1.1, a repeated or bad Content-Length, a body over 1 KB (256 KB to editsPath and documentsChangesPath, 64 KB
    /// to storagePath, 512 KB to an upload's piece), or any
    /// Transfer-Encoding is refused.
    public static func parseHead(_ buffer: Data) -> HeadParse {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .refused(431) : .needMore
        }
        guard end.lowerBound <= maxHead else { return .refused(431) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8),
              head.allSatisfy({ $0.isASCII }) else { return .refused(400) }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1", start[1].hasPrefix("/") else { return .refused(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .refused(400)
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .refused(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil {
                guard name != "content-length", name != "authorization", name != "range" else { return .refused(400) }
                headers[name]! += ", " + value
            } else {
                headers[name] = value
            }
        }
        if headers["transfer-encoding"] != nil { return .refused(501) }
        var length = 0
        if let declared = headers["content-length"] {
            guard declared.allSatisfy({ $0.isASCII && $0.isNumber }), declared.count <= 6, let value = Int(declared)
            else { return .refused(400) }
            guard value <= bodyLimit(start[1]) else { return .refused(413) }
            length = value
        }
        let request = HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers)
        return .request(request, bodyLength: length, headLength: end.upperBound - buffer.startIndex)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    /// The response head: the status line, these headers in order, Connection: close, and the blank line.
    public static func head(_ status: Int, _ headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }
}

/// A Range header against a file of `size` bytes (RFC 9110 section 14): one range, "bytes=a-b", "bytes=a-" or
/// "bytes=-n". Several ranges, or one that can't be read, are answered with the whole file, as the RFC allows.
public enum ByteRange: Equatable, Sendable {
    case whole
    case part(start: Int64, end: Int64)  // end inclusive
    case unsatisfiable

    public static func parse(_ header: String?, size: Int64) -> ByteRange {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        let sides = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard sides.count == 2 else { return .whole }
        let first = sides[0], last = sides[1]
        func number(_ part: Substring) -> Int64? {
            part.count <= 18 && !part.isEmpty && part.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int64(part) : nil
        }
        if first.isEmpty {
            guard let suffix = number(last) else { return .whole }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .part(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = number(first) else { return .whole }
        guard start < size else { return .unsatisfiable }
        if last.isEmpty { return .part(start: start, end: size - 1) }
        guard let end = number(last), end >= start else { return .whole }
        return .part(start: start, end: min(end, size - 1))
    }
}
