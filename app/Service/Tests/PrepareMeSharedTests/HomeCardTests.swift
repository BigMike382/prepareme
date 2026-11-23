import CoreImage
import Foundation
import PrepareMeShared
import Testing

/// An Our Home page's paper card (Our Home plan, Task 4.3; board 24), on the shared made-up page (our-home-page.md).
@Suite struct HomeCardTests {
    static let page = try! HouseholdPage(markdown: String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/our-home-page.md"), encoding: .utf8))
    static let printed = Date(timeIntervalSince1970: 1_794_830_400)  // 2026-11-16 12:00 UTC
    let card = HomeCard(page, name: "shutoffs", printed: printed)

    static func text(_ parts: [HomeCard.Part]) -> String { parts.map(\.text).joined() }

    @Test func theTopHasTheHouseTheTitleAndWhatsLeft() {
        #expect(card.home == "🏠 Our Home")
        #expect(card.title == "SAMPLE Utility shut-offs")
        #expect(card.unfinished == "Not finished: 1 blank left to fill in on the Mac.")
        #expect(Self.text(card.when) == "SAMPLE you smell gas or a pipe bursts.", "an answered blank is its answer")
        #expect(Self.text(card.danger) == "SAMPLE if you smell gas, get everyone out first and call from outside.")
        var filled = Self.page
        filled.steps[2].words = "SAMPLE turn it [Fill in: left or right?]{left}."
        #expect(HomeCard(filled, name: "shutoffs", printed: Self.printed).unfinished == "")
        filled.steps[0].words = "SAMPLE [Fill in: a]; [Fill in: b]."
        #expect(HomeCard(filled, name: "shutoffs", printed: Self.printed).unfinished
                == "Not finished: 2 blanks left to fill in on the Mac.")
    }

    @Test func eachStepHasItsNameItsWarningsAndItsWords() {
        #expect(card.steps.map(\.number) == [1, 2, 3, 4])
        #expect(card.steps.map(\.name) == ["SAMPLE smell gas", "SAMPLE get out", "SAMPLE water main", "SAMPLE breaker panel"])
        #expect(Self.text(card.steps[1].danger) == "SAMPLE don't use a light switch inside.")
        #expect(Self.text(card.steps[2].caution) == "SAMPLE don't force a stuck valve.")
        #expect(card.steps[0].answer == "Yes: step 2. No: step 3.")
        #expect(card.steps[1].call == "Call SAMPLE gas emergency line: (555) 555-0142")
        #expect(card.steps[3].ticks == ["SAMPLE switch the main breaker down", "SAMPLE write the time on the panel door"])
        #expect(card.steps[3].photo == "sample-shutoffs-4.jpg")
        #expect(card.steps.allSatisfy { $0.photo.isEmpty || $0.number == 4 })
    }

    @Test func aBlankLeftIsItsQuestionDrawnAsABlank() {
        #expect(card.steps[2].words.map(\.text) == ["SAMPLE turn the handle a quarter turn ", "Fill in: left or right?",
                                                     ", so it lies across the pipe."])
        #expect(card.steps[2].words.map(\.blank) == [false, true, false])
    }

    @Test func thePhotoWantedAndTheLinksNeverPrint() {
        let all = String(describing: card)
        for never in ["SAMPLE the valve with its handle across the pipe", "utility-shutoff", "calc-outage-load",
                      "sample pipe wrench", "SAMPLE call a plumber", "c276b32d"] {
            #expect(!all.contains(never), "\(never)")
        }
    }

    @Test func theFixedLines() {
        #expect(card.scan == "Scan to open this page in PrepareMe.")
        #expect(card.foot == "Or open PrepareMe › Our Home › SAMPLE Utility shut-offs. Printed November 16, 2026; the "
                + "page in PrepareMe is the one kept up to date.")
    }

    @Test func theCodeHoldsThePagesLinkAndNothingElse() throws {
        #expect(card.link == "prepareme://home/shutoffs")
        #expect(HomeLinks.page(URL(string: card.link)!) == "shutoffs.html", "the link Task 2.6 opens")
        #expect(try Self.read(card.qr) == [card.link])
        let other = HomeCard(Self.page, name: "house-k3x9", printed: Self.printed)
        #expect(try Self.read(other.qr) == ["prepareme://home/house-k3x9"])
    }

    /// The modules drawn black on white, 10 points each, a 4-module quiet zone, read back by CoreImage's detector.
    static func read(_ modules: [[Bool]]) throws -> [String] {
        let size = (modules.count + 8) * 10
        var pixels = [UInt8](repeating: 255, count: size * size)
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<10 { for dx in 0..<10 { pixels[((y + 4) * 10 + dy) * size + (x + 4) * 10 + dx] = 0 } }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: size, size: CGSize(width: size, height: size),
                            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
