import Foundation
import Network
@testable import PrepareMeServer
import PrepareMeShared
import XCTest

/// The request reader, the range reader and the peer check: what the service accepts before any token is looked at.
final class HTTPTests: XCTestCase {
    func parse(_ text: String) -> HeadParse { HTTP.parseHead(Data(text.utf8)) }

    func testAPartialHeadNeedsMore() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x\r\n"), .needMore)
        XCTAssertEqual(HTTP.parseHead(Data(repeating: 65, count: 8192)), .needMore)
    }

    func testAnOversizeHeadIsRefusedWhetherOrNotItEnds() {
        XCTAssertEqual(HTTP.parseHead(Data(repeating: 65, count: 8193)), .refused(431))
        XCTAssertEqual(HTTP.parseHead(Data(repeating: 65, count: 8200) + Data("\r\n\r\n".utf8)), .refused(431))
    }

    func testAGoodGetHasItsHeadersInLowerCase() {
        let text = "GET /manifest.json HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\n\r\n"
        guard case let .request(request, bodyLength, headLength) = parse(text) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/manifest.json")
        XCTAssertEqual(request.headers, ["host": "x", "authorization": "Bearer abc"])
        XCTAssertEqual(bodyLength, 0)
        XCTAssertEqual(headLength, text.utf8.count)
    }

    func testAPostGivesItsBodyLengthAndWhereTheBodyStarts() {
        let head = "POST /counts HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        guard case let .request(request, bodyLength, headLength) = parse(head + "0123456789") else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(bodyLength, 10)
        XCTAssertEqual(headLength, head.utf8.count)
    }

    func testBadRequestsAreRefusedWithTheirStatus() {
        let cases: [(String, Int)] = [
            ("POST /c HTTP/1.1\r\nContent-Length: 1025\r\n\r\n", 413),
            ("POST /c HTTP/1.1\r\nContent-Length: abc\r\n\r\n", 400),
            ("POST /c HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n", 400),
            ("POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 501),
            ("GET / HTTP/1.0\r\n\r\n", 400),
            ("GET x HTTP/1.1\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nA: b\r\n folded\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nA: caf\u{E9}\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nno colon here\r\n\r\n", 400),
        ]
        for (text, status) in cases {
            XCTAssertEqual(parse(text), .refused(status), text)
        }
    }

    func testTheResponseHeadHasTheStatusLineHeadersInOrderAndClose() {
        let head = HTTP.head(206, [("A", "1"), ("B", "2")])
        XCTAssertEqual(String(decoding: head, as: UTF8.self),
                       "HTTP/1.1 206 Partial Content\r\nA: 1\r\nB: 2\r\nConnection: close\r\n\r\n")
    }

    func testByteRangesAgainstAHundredByteFile() {
        func range(_ header: String?, size: Int64 = 100) -> ByteRange { ByteRange.parse(header, size: size) }
        XCTAssertEqual(range(nil), .whole)
        XCTAssertEqual(range("bytes=0-9"), .part(start: 0, end: 9))
        XCTAssertEqual(range("bytes=90-"), .part(start: 90, end: 99))
        XCTAssertEqual(range("bytes=-10"), .part(start: 90, end: 99))
        XCTAssertEqual(range("bytes=-200"), .part(start: 0, end: 99))
        XCTAssertEqual(range("bytes=95-200"), .part(start: 95, end: 99))
        XCTAssertEqual(range("bytes=100-"), .unsatisfiable)
        XCTAssertEqual(range("bytes=-0"), .unsatisfiable)
        XCTAssertEqual(range("bytes=5-1"), .whole)
        XCTAssertEqual(range("bytes=0-1,5-6"), .whole)
        XCTAssertEqual(range("items=0-1"), .whole)
        XCTAssertEqual(range("bytes=0-", size: 0), .unsatisfiable)
    }

    func testOnlyAPrivateIPv4PeerIsServed() {
        func host(_ ip: String) -> NWEndpoint { .hostPort(host: .ipv4(IPv4Address(ip)!), port: 1) }
        XCTAssertTrue(FileServer.isPrivatePeer(host("192.168.1.5")))
        XCTAssertFalse(FileServer.isPrivatePeer(host("8.8.8.8")))
        XCTAssertFalse(FileServer.isPrivatePeer(.hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: 1)))
        XCTAssertFalse(FileServer.isPrivatePeer(.service(name: "x", type: "_t._tcp", domain: "local", interface: nil)))
    }
}
