import CoreImage
import Foundation
import PrepareMeShared
import SystemConfiguration

/// The Mac's side of pairing: its Bonjour name and private IPv4 address for the code, and the code drawn in the
/// terminal as a QR code the phone's camera reads. The code holds the phone's token, so it is only ever drawn on the
/// Mac's screen, never saved.
public enum MacPairing {
    /// "<LocalHostName>.local", as the Mac answers on the home network.
    public static func bonjourHost() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// The Mac's first private IPv4 address on an interface that is up (en0, en1, … first), or nil.
    public static func privateIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if PrivateAddress.isPrivateIPv4(text), !text.hasPrefix("127."), !text.hasPrefix("169.254.") {
                found.append((String(cString: entry.ifa_name), text))
            }
        }
        return found.sorted { $0.0 < $1.0 }.first?.1
    }

    /// The text as a QR code in terminal characters: two rows of modules per line (▀ ▄ █ and space), dark on light
    /// with a four-module quiet zone, using the terminal's colors forced to black on white.
    public static func terminalQR(_ text: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext()
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        let quiet = 4
        func dark(_ x: Int, _ y: Int) -> Bool {
            let px = x - quiet, py = y - quiet
            guard px >= 0, py >= 0, px < width, py < height else { return false }
            return pixels[(py * width + px) * 4] < 128
        }
        let side = width + 2 * quiet, tall = height + 2 * quiet
        var lines: [String] = []
        for y in stride(from: 0, to: tall, by: 2) {
            var line = "\u{1B}[30;47m"
            for x in 0..<side {
                switch (dark(x, y), y + 1 < tall && dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
