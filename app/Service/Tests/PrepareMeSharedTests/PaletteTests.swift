import Foundation
import XCTest
@testable import PrepareMeShared

/// The app's screens against the pages (the Today redesign's phase 5, ruling 12): the same colors as BASE's tokens,
/// color only through those tokens, and no text under 15 points on the phone, or under the Mac's 13-point body on the
/// Mac (owner, 2026-10-22: the Mac's own text styles), outside the printed sheets.
final class PaletteTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Tests/PrepareMeSharedTests
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `--name:#hex` pairs from the first `{…}` block after `marker` in front_style.py.
    func tokens(after marker: String, in style: String) throws -> [String: UInt32] {
        let start = try XCTUnwrap(style.range(of: marker))
        let block = style[start.upperBound...].prefix { $0 != "}" }
        let pattern = try NSRegularExpression(pattern: "--([a-z0-9-]+):#([0-9a-fA-F]{3,6})\\b")
        var found: [String: UInt32] = [:]
        let text = String(block)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            var hex = String(text[Range(match.range(at: 2), in: text)!])
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            found[name] = UInt32(hex, radix: 16)
        }
        return found
    }

    func testEveryTokenMatchesTheStylesheet() throws {
        let style = try String(contentsOf: Self.repo.appendingPathComponent("packer/front_style.py"), encoding: .utf8)
        let light = try tokens(after: "body{", in: style)
        let dark = light.merging(try tokens(after: "@media (prefers-color-scheme:dark){body{", in: style)) { $1 }
        XCTAssertEqual(Set(light.keys), Set(Palette.tokens.keys), "a token added to or dropped from BASE")
        for (name, pair) in Palette.tokens {
            XCTAssertEqual(pair.light, light[name], "--\(name), light")
            XCTAssertEqual(pair.dark, dark[name], "--\(name), dark")
        }
    }

    /// Increase Contrast on the app's screens does what the pages' own line does (the Apple guidelines plan, phase 4).
    func testIncreaseContrastMatchesThePages() throws {
        let style = try String(contentsOf: Self.repo.appendingPathComponent("packer/front_style.py"), encoding: .utf8)
        let start = try XCTUnwrap(style.range(of: "@media (prefers-contrast:more){body{"))
        let block = String(style[start.upperBound...].prefix { $0 != "}" })
        let pattern = try NSRegularExpression(pattern: "--([a-z0-9-]+):var\\(--([a-z0-9-]+)\\)")
        var found: [String: String] = [:]
        for match in pattern.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            found[String(block[Range(match.range(at: 1), in: block)!])] = String(block[Range(match.range(at: 2), in: block)!])
        }
        XCTAssertEqual(found, Palette.moreContrast)
        XCTAssertEqual(Palette.moreContrast("text2"), Palette.text)
        XCTAssertNil(Palette.moreContrast("accent"), "a token the pages leave alone")
    }

    /// Red night (phase K, finding 19; CLAUDE.md's dated exception): the app is dark and only the red part of each
    /// color is left, so danger must stay the brightest mark. The danger band's text (event mode's `--ev-text`) and
    /// danger's words (`--red`) keep a red part at least as high as caution's and the accent's (`--caution` ties
    /// `--red` today); the ok and info marks go dim, under half of danger's.
    func testRedNightKeepsDangerTheBrightest() {
        func redPart(_ pair: Palette.Pair) -> UInt32 { pair.dark >> 16 }
        for (name, danger) in [("ev-text", Palette.evText), ("red", Palette.red)] {
            XCTAssertGreaterThanOrEqual(redPart(danger), redPart(Palette.caution), "--\(name) against --caution")
            XCTAssertGreaterThanOrEqual(redPart(danger), redPart(Palette.accent), "--\(name) against --accent")
        }
        for (name, mark) in [("ok-mark", Palette.okMark), ("info-mark", Palette.infoMark)] {
            XCTAssertLessThan(redPart(mark) * 2, redPart(Palette.red), "--\(name) stays dim")
        }
        XCTAssertEqual(Palette.tokens["ev-text"], Palette.evText)
        XCTAssertEqual(Palette.tokens["red"], Palette.red)
    }

    /// Red night on Today's warning band (beta run 2, R9.1 fix round 1): the headline keeps --ev-text, the brightest red
    /// part in the band; the buttons turn dark (the black ground red night gives the page) with danger's words, whose
    /// red part alone is at least 4.5:1 on black; the band's other words are danger's too.
    func testRedNightKeepsTheWarningBandsHeadlineBrightestAndItsButtonsReadable() throws {
        let style = try String(contentsOf: Self.repo.appendingPathComponent("packer/front_style.py"), encoding: .utf8)
        for rule in ["[data-pm-red] [data-mode=event] .band{color:var(--red);background:var(--bg);"
                     + "box-shadow:inset 0 0 0 2px var(--red)}",
                     "[data-pm-red] [data-mode=event] .band>.alert{color:var(--ev-text)}",
                     "[data-pm-red] [data-mode=event] .band>.alert>.do{color:var(--red)}",
                     "[data-pm-red] [data-mode=event] .band>.sos a{background:var(--bg);color:var(--red);"] {
            XCTAssertTrue(style.contains(rule), rule)
        }
        XCTAssertTrue(RedNight.pageScript(on: true).contains("body{--bg:#000}"), "red night's ground is black")
        func redPart(_ pair: Palette.Pair) -> Double { Double(pair.dark >> 16) / 255 }
        XCTAssertGreaterThanOrEqual(redPart(Palette.evText), redPart(Palette.red), "the headline brightest")
        func luminance(_ part: Double) -> Double {
            0.2126 * (part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4))
        }
        XCTAssertGreaterThanOrEqual((luminance(redPart(Palette.red)) + 0.05) / 0.05, 4.5, "the buttons' words on black")
    }

    /// The app's tint (look 3, spec section 11: PrepareMe's teal, which had been the pages' ink, A9) is also an asset,
    /// the target's global accent color, so UIKit's and AppKit's own controls follow it; it must be `--link`.
    func testTheTintIsTheTeal() throws {
        let url = Self.repo.appendingPathComponent("app/Kiwix/PrepareMeApp/PrepareMe.xcassets/PrepareMeTint.colorset/Contents.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        func hex(_ entry: [String: Any]) throws -> UInt32 {
            let parts = try XCTUnwrap((entry["color"] as? [String: Any])?["components"] as? [String: String])
            return try ["red", "green", "blue"].reduce(UInt32(0)) { sum, name in
                let part = try XCTUnwrap(parts[name]).replacingOccurrences(of: "0x", with: "")
                return sum << 8 | (try XCTUnwrap(UInt32(part, radix: 16)))
            }
        }
        let dark = try XCTUnwrap(colors.first { $0["appearances"] != nil })
        let light = try XCTUnwrap(colors.first { $0["appearances"] == nil })
        XCTAssertEqual(Palette.Pair(try hex(light), try hex(dark)), Palette.link)
    }

    /// Red night with look 3 (plan Review Focus 3): the band and the teal tint stay grounds darker than danger's own
    /// box, and the teal text and fill never outshine danger's words, on the dark values' red part, all red night keeps.
    func testRedNightKeepsTheBandAndTheTealBelowDanger() {
        func redPart(_ pair: Palette.Pair) -> UInt32 { pair.dark >> 16 }
        for (name, ground) in [("band", Palette.band), ("id-tint", Palette.idTint)] {
            XCTAssertLessThan(redPart(ground), redPart(Palette.redBg), "--\(name) against --red-bg")
        }
        for (name, teal) in [("link", Palette.link), ("id-fill", Palette.idFill)] {
            XCTAssertLessThanOrEqual(redPart(teal), redPart(Palette.red), "--\(name) against --red")
        }
        XCTAssertLessThanOrEqual(redPart(Palette.bandText), redPart(Palette.red), "--band-text against --red")
    }

    /// The app's own screen files, with the printed sheets left out: whole files, and the lines between
    /// "// print sizes: from here" and "// print sizes: to here". Every file is built for both the phone and the Mac
    /// (project.yml), so a line is drawn on the Mac (`onMac`) unless an `#if os(iOS)` (or the `#else` of an
    /// `#if os(macOS)`) holds it; `mac` is the Mac's own code: a Mac-only file's, or inside an `#if os(macOS)`. Until
    /// phase L (finding 2) a file with both `#if`s went unchecked, and the street map's Mac popover kept 13 points.
    static func screenLines() throws -> [(file: String, line: Int, text: String, mac: Bool, onMac: Bool)] {
        let folder = repo.appendingPathComponent("app/Kiwix/PrepareMeApp")
        let printed: Set = ["PrepareMeGrabSheets.swift", "PrepareMeLabels.swift", "PrepareMeHomeCard.swift"]
        var lines: [(String, Int, String, Bool, Bool)] = []
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        for name in names.sorted() where !printed.contains(name) {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            let macFile = text.range(of: "#if os(macOS)") != nil && text.range(of: "#if os(iOS)") == nil
            var inPrint = false
            var open: [String] = []  // each open #if's platform here: "iOS", "macOS" or "" (DEBUG, a flag)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let directive = line.trimmingCharacters(in: .whitespaces)
                if directive.hasPrefix("#if") {
                    let os = ["iOS", "macOS"].first { directive.hasPrefix("#if os(\($0))") }
                    open.append(os ?? "")
                } else if directive.hasPrefix("#else"), let last = open.last {
                    open[open.count - 1] = last == "iOS" ? "macOS" : last == "macOS" ? "iOS" : ""
                } else if directive.hasPrefix("#endif") {
                    _ = open.popLast()
                }
                let onMac = !open.contains("iOS")
                let mac = open.contains("macOS") || (macFile && onMac)
                if line.contains("// print sizes: from here") { inPrint = true }
                if line.contains("// print sizes: to here") { inPrint = false }
                if !inPrint { lines.append((name, number + 1, line, mac, onMac)) }
            }
            XCTAssertTrue(open.isEmpty, "\(name): an #if left open")
        }
        XCTAssertGreaterThan(lines.count, 1000, "the app's screen files weren't found")
        return lines
    }

    func testNoTextUnderFifteenPointsOnThePhoneOrTheBodySizeOnTheMac() throws {
        // iOS: footnote 13, caption 12, caption2 11. macOS: body and headline 13 (its ordinary text, since the owner's
        // 2026-10-22 choice), callout 12, subheadline 11, and footnote and both captions 10. Fixed sizes under 15
        // anywhere.
        let small = try NSRegularExpression(pattern: "\\.(caption2?|footnote)\\b|\\.system\\(size: *([0-9]|1[0-4])\\b")
        let macSmall = try NSRegularExpression(pattern: "\\.font\\(\\.(callout|subheadline)\\b")
        for (file, line, text, _, onMac) in try Self.screenLines() {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertFalse(small.firstMatch(in: text, range: range) != nil, "\(file):\(line): text under 15 points")
            if onMac {
                XCTAssertFalse(macSmall.firstMatch(in: text, range: range) != nil, "\(file):\(line): under 13 points on the Mac")
                // The Mac draws a section's title at its own small size whatever the window's font
                XCTAssertFalse(text.contains("Section(\""), "\(file):\(line): a Mac section title not through pmTitle")
            }
        }
    }

    /// In dark mode the ink is near-white, so a switch, a checkbox or a filled button the tint fills showed white on
    /// white (owner, 2026-10-15, by click): each switch is `.pmSwitch()` (the pages' green) and each filled button
    /// `.pmProminent()` (its words in the panel's color).
    func testFillsReadInBothModes() throws {
        let lines = try Self.screenLines().filter { $0.file != "PrepareMeColors.swift" }
        for (file, line, text, _, _) in lines where text.contains(".borderedProminent") {
            XCTFail("\(file):\(line): a filled button not through .pmProminent()")
        }
        for file in Set(lines.map(\.file)) {
            let code = lines.filter { $0.file == file }.map(\.text)
            let toggles = code.filter { $0.contains("Toggle(") }.count
            let switches = code.filter { $0.contains(".pmSwitch()") }.count
            XCTAssertEqual(toggles, switches, "\(file): a switch or checkbox not through .pmSwitch()")
        }
    }

    /// One action style (remaining-findings plan, Task 9.1; F41, F64; owner, 2026-10-18, by click: bordered): each
    /// action the beta run found looking like plain text, or too small to hit, is `.pmAction()` within a few lines of
    /// its words; no screen keeps the system's own bordered look; the one filled button left is the child's "I'm
    /// lost", its screen's one call; and the gear says its word.
    func testActionsUseTheActionStyle() throws {
        let lines = try Self.screenLines().filter { $0.file != "PrepareMeColors.swift" }
        for (file, line, text, _, _) in lines where text.contains(".buttonStyle(.bordered)") {
            XCTFail("\(file):\(line): an action not through .pmAction()")
        }
        XCTAssertEqual(lines.filter { $0.text.contains(".pmProminent()") }.map(\.file), ["PrepareMeStreetMap.swift"],
                       "a filled action besides the child's \"I'm lost\"")
        let actions = ["\"Check now\"", "Button(\"Pair again\")", "Button(\"Pair with the Mac\")",
                       "\"Download (\\(StorageWords.size(entry.size)))\")",  // the button, not the menu's item
                       "Button(\"Try again\")", "Button(\"Show the map\"", "Button(\"Open Downloads\")",
                       "Button(\"Pair\")", "Label(\"Share this spot\"", "Button(\"Remove from this",
                       "Button(\"Read the manual\", systemImage", "Button(\"Back up to iCloud now\")", "Button(\"Open Login Items\")",
                       "Button(\"Add from Files\")", "Button(\"Add a travel map\")",
                       "Button(UnitWords.used(", "Button(UnitWords.more(",
                       "Button(\"Bought…\")", "Button(\"Not needed\")", "Button(\"Change\")", "Button(\"Stop\"",
                       "Button(\"Done today\")", "Button(\"Accept\")", "Button(\"Decline\")", "Button(\"Undo\")",
                       "Button(\"Can't scan?\")",
                       "Button(\"Done\", action: done)", "Button(\"Throw these away…\"", "Button(\"Type a code\")",
                       "Button(\"Undo last\")"]
        // An action's own style: `.pmAction(` after its words and before the next control starts, comments left out
        let starts = ["Button(", "Button {", "Menu {", "Menu(", "ShareLink(", "Link(", "NavigationLink"]
        func code(_ index: Int) -> String { lines[index].text.components(separatedBy: "//")[0] }
        for action in actions {
            // The Mac's own Stop (downloads) and Done (pairing) keep the Mac's push button; the phone's words are listed
            let macOwn = action.contains("\"Stop\"") || action.contains("action: done")
            let found = lines.indices.filter { code($0).contains(action) && !(macOwn && lines[$0].mac) }
            XCTAssertFalse(found.isEmpty, "\(action) wasn't found: update this list")
            for index in found {
                // a PMState's or PMWarningRow's `action: (words, run)` is drawn through .pmAction() by the piece itself
                var styled = code(index).contains(".pmAction(") || code(index).contains("action: (")
                var next = index + 1
                while !styled, next < lines.count, next <= index + 12, lines[next].file == lines[index].file {
                    let text = code(next)
                    if starts.contains(where: text.contains) && !text.contains(".pmAction(") { break }
                    styled = text.contains(".pmAction(")
                    next += 1
                }
                XCTAssertTrue(styled, "\(lines[index].file):\(lines[index].line): \(action) not through .pmAction()")
            }
        }
        XCTAssertTrue(lines.contains { $0.text.contains("Image(systemName: \"gear\"); Text(\"Settings\")") },
                      "the gear without its word (a toolbar draws a Label's icon alone)")
    }

    /// Grey text that reads (remaining-findings plan, Task 9.2; F63; owner, 2026-10-18, by click): every grey line
    /// is BASE's darker `text2` (`PrepareMeColors.text2`), never the system's `.secondary`, which failed contrast; a
    /// section's title goes through `Section(pmTitle:)` and a footer says its color, since the system draws both grey.
    func testReadingLinesUseText2() throws {
        let lines = try Self.screenLines().filter { $0.file != "PrepareMeColors.swift" }
        let grey = try NSRegularExpression(pattern: "\\.secondary\\b(?!Action)")
        let untitled = try NSRegularExpression(pattern: "\\bSection\\((?!pmTitle:|content:|header:|footer:)")
        for (file, line, text, _, _) in lines {
            let code = text.components(separatedBy: "//")[0]
            XCTAssertNil(grey.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                         "\(file):\(line): system grey, not PrepareMeColors.text2")
            XCTAssertNil(untitled.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                         "\(file):\(line): a section title not through pmTitle")
        }
        for (index, entry) in lines.enumerated() where entry.text.contains("footer: {") || entry.text.contains("header: {") {
            let after = lines[(index + 1)...].prefix(12).prefix { $0.file == entry.file }
            let closes = after.firstIndex { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("}") } ?? after.endIndex
            XCTAssertTrue(after[..<closes].contains { $0.text.contains("PrepareMeColors.text2") },
                          "\(entry.file):\(entry.line): a section's title or footer in the system's grey")
        }
    }

    /// The Mac's phone name boxes say what they're for and read in dark mode (remaining-findings plan, Task 13.2;
    /// F42: empty dark boxes holding only a dim "phone 3"); a phone not yet visited says so.
    func testNameBoxesReadInDarkMode() throws {
        let lines = try Self.screenLines().filter { $0.file == "PrepareMePairing.swift" }
        let code = lines.map(\.text).joined(separator: "\n")
        XCTAssertFalse(code.contains("TextField(phone.label"), "a box whose only words are the phone's dim label")
        XCTAssertTrue(code.contains("prompt: Text(PairingWords.namePrompt)"), "the box's prompt")
        XCTAssertTrue(code.contains("PairingWords.waiting"), "a phone waiting for its first visit")
        XCTAssertEqual(PairingWords.namePrompt, "Name this device")
        XCTAssertEqual(PairingWords.kind(label: "phone 3", readOnly: false, waiting: true),
                       "Adult's device (phone 3), waiting for its first visit")
        XCTAssertEqual(PairingWords.kind(label: "phone 2", readOnly: true, waiting: false),
                       "Child's device (phone 2)")  // family downloads, phase 2: no "read-only"
        XCTAssertEqual(PairingWords.childDevice,
                       "Reads the library, downloads what you offer and adds its own pins. Never Essential Documents.")
    }

    /// A section's footer is drawn small by the system (13 points on the phone) unless it says otherwise.
    func testFootersSayTheirSize() throws {
        let lines = try Self.screenLines()
        for (index, entry) in lines.enumerated() where entry.text.contains("footer: {") {
            let after = lines[(index + 1)...].prefix(5).prefix { $0.file == entry.file }
            let closes = after.firstIndex { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("}") } ?? after.endIndex
            XCTAssertTrue(after[..<closes].contains { $0.text.contains(".font(") },
                          "\(entry.file):\(entry.line): a footer without .font(.pmNote)")
        }
    }

    /// The app's own screens on the pages' ground (owner, 2026-10-22, by click): every list and form is a PMList or a
    /// PMForm (PrepareMeColors.swift), its rows on the pages' panel; a Mac sidebar, `List(selection:)`, keeps the Mac's.
    func testListsAndFormsSitOnThePagesGround() throws {
        let bare = try NSRegularExpression(pattern: "^\\s*(List|Form)\\s*\\{")
        for (file, line, text, _, _) in try Self.screenLines() where file != "PrepareMeColors.swift" {
            XCTAssertNil(bare.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                         "\(file):\(line): a list or form not on the pages' ground (PMList or PMForm)")
        }
    }

    /// Look 3 (spec section 10; plan Task 1.4): every text style a screen sets goes through the central file's names
    /// (`.pmTitle`, `.pmLargeTitle`, `.pmHeadline`, `.pmBody`, `.pmNote`, `.pmCount`), so the new typefaces reach it;
    /// 81 lines set one directly before.
    func testTextStylesGoThroughTheCentralFile() throws {
        let raw = try NSRegularExpression(pattern: "\\.font\\(\\.(title|title2|title3|largeTitle|headline|callout|subheadline|body)\\b")
        let found = try Self.screenLines().filter { entry in
            let code = entry.text.components(separatedBy: "//")[0]
            return raw.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
        XCTAssertEqual(found.count, 0, "raw text styles: " + found.map { "\($0.file):\($0.line)" }.joined(separator: ", "))
    }

    /// The band never fixes its height or cuts a line short (spec section 8; plan Review Focus 4): at the largest text
    /// size on the smallest iPhone its lines wrap and it grows (phase 0, question 6).
    func testTheBandNeverFixesItsHeight() throws {
        let look = try Self.screenLines().filter { $0.file == "PrepareMeLook.swift" }
        XCTAssertFalse(look.isEmpty, "PrepareMeLook.swift wasn't found")
        for entry in look where entry.text.contains(".frame(height:") || entry.text.contains(".lineLimit(1)") {
            XCTFail("\(entry.file):\(entry.line): a fixed height or a one-line limit in the shared pieces")
        }
    }

    /// Look 3 (spec section 10, rules 1 and 4; plan Task 4.2): the six screens that built their own empty or failed look
    /// take `PMState`, and Today's amber rows are `PMWarningRow`, the one built in PrepareMeLook.swift.
    func testEmptyAndErrorScreensShareOneLook() throws {
        let lines = try Self.screenLines()
        let code = { (entry: (file: String, line: Int, text: String, mac: Bool, onMac: Bool)) in
            entry.text.components(separatedBy: "//")[0]
        }
        for file in ["PrepareMeViews.swift", "PrepareMePhoneInventory.swift", "PrepareMePhoneDocuments.swift",
                     "PrepareMeStreetMap.swift", "PrepareMeTabs.swift"] {
            XCTAssertTrue(lines.contains { $0.file == file && code($0).contains("PMState(") }, "\(file): no PMState")
        }
        let message = try String(contentsOf: Self.repo.appendingPathComponent("app/Kiwix/Views/BuildingBlocks/Message.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(message.contains("PMState("), "Kiwix's Message doesn't take the shared look")
        for entry in lines where ["PrepareMeTabs.swift", "PrepareMePhoneDocuments.swift"].contains(entry.file) {
            XCTAssertFalse(code(entry).contains("exclamationmark.triangle.fill"),
                           "\(entry.file):\(entry.line): an amber row built apart from PMWarningRow")
        }
    }

    /// Look 3 (spec section 4; plan Task 4.1, Review Focus 4): Inventory's four counts are `PMCount`s, and every screen
    /// that lays counts side by side reads the text size, so at the large sizes they go one to a row and never shrink.
    func testCountsAndRowsStackAtAccessibilitySizes() throws {
        let lines = try Self.screenLines().filter { $0.file != "PrepareMeLook.swift" }
        let users = Set(lines.filter { $0.text.components(separatedBy: "//")[0].contains("PMCount(") }.map(\.file))
        XCTAssertTrue(users.contains("PrepareMePhoneInventory.swift"), "Inventory's counts aren't PMCounts")
        for file in users {
            XCTAssertTrue(lines.contains { $0.file == file && $0.text.contains("@Environment(\\.dynamicTypeSize)") },
                          "\(file): counts side by side without reading the text size")
        }
    }

    /// Look 3's accessibility fixes on the phone (spec section 8, fixes 1, 2, 6, 9, 10, 11, 13 and 15; plan Task 4.4),
    /// each held where it was made; fix 5 comes with phase 5's change 16.
    func testTheAccessibilityFixesOnThePhone() throws {
        let app = Self.repo.appendingPathComponent("app/Kiwix")
        func file(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
        }
        func part(_ text: String, from start: String, to end: String) -> String {
            guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex)
            else { XCTFail("\(start) wasn't found"); return "" }
            return String(text[a.lowerBound..<b.lowerBound])
        }
        // 1: the two sheets scroll, and the place number takes a text style
        let strip = try file("PrepareMeApp/PrepareMeStreetMap.swift")
        let lost = part(strip, from: ".sheet(isPresented: $lost)", to: ".presentationDetents")
        XCTAssertTrue(lost.contains("ScrollView"), "I'm lost doesn't scroll")
        XCTAssertTrue(lost.contains(".pmPlaceNumber"), "the place number has no text style")
        XCTAssertFalse(strip.contains(".font(.system(size:"), "a fixed size on the street map's phone screens")
        XCTAssertTrue(try file("PrepareMeApp/PrepareMeColors.swift").contains("static var pmPlaceNumber"))
        let getFile = part(try file("PrepareMeApp/PrepareMeViews.swift"), from: "struct GetFileSheet", to: "\nstruct ")
        XCTAssertTrue(getFile.contains("ScrollView"), "Get this file doesn't scroll")
        XCTAssertTrue(getFile.contains(".large"), "Get this file can't open to the full height")
        // 2: the open strip's names and distances take the folded row's limit, and never shrink
        XCTAssertFalse(strip.contains(".lineLimit(1)"), "a one-line limit on the map strip")
        XCTAssertFalse(strip.contains("minimumScaleFactor"), "the map strip shrinks text to fit")
        // 6, 10, 11 and 13 on the map's screen
        let screen = try file("PrepareMeApp/PrepareMeStreetMapScreen.swift")
        // the map pins plan, Task 2.1: Add a pin where I am is a round button of its own, out of Layers
        XCTAssertFalse(part(screen, from: "var layers: some View", to: "var addPin: some View")
            .contains("PersonalPins.addWhereIAm"), "Add a pin where I am is still in Layers")
        XCTAssertTrue(part(screen, from: "var addPin: some View", to: "var topo: some View")
            .contains("round(\"mappin.and.ellipse\", PersonalPins.addWhereIAm, word: \"Add pin\")"), "no Add pin button")
        for arrangement in ["var buttons: some View", "func fittedButtons("] {
            XCTAssertTrue(part(screen, from: arrangement, to: "\n    }\n").contains("addPin"), arrangement)
        }
        // the phase 2 review: a route's card keeps the 2026-10-14 audit's warning, and Drive and Walk in the strip,
        // though regular size, still take a 44-point finger
        XCTAssertTrue(part(try file("PrepareMeApp/PrepareMeMapPinCard.swift"), from: "case .route:", to: "case .start:")
            .contains("StreetMapWords.ownRoads"), "a route's card lost Organic Maps picks its own roads")
        XCTAssertTrue(part(try file("PrepareMeApp/PrepareMeColors.swift"), from: "private struct PMActionLook",
                           to: "\n}\n").contains("minHeight: compact ? 44 - 12"), "a compact action can be under 44 points tall")
        XCTAssertTrue(part(screen, from: "func circle(", to: "\n    }\n").contains("SpokenName.of("),
                      "the round buttons' spoken names don't hold their words")
        XCTAssertTrue(part(screen, from: "var redNightSwitch", to: "\n    }\n").contains(".isToggle"),
                      "Red night isn't announced as a switch")
        let tick = part(screen, from: "struct MarkTick", to: "\n}\n")
        XCTAssertTrue(tick.contains("let name: String") && tick.contains(".accessibilityLabel(name)"),
                      "a rally list tick doesn't name its point")
        // 9: the picker's long path wraps at the large sizes
        let pick = try file("PrepareMeApp/PrepareMePickList.swift")
        XCTAssertFalse(pick.contains(".lineLimit(1)"), "the picker cuts a long path to one line")
        XCTAssertTrue(pick.contains("@Environment(\\.dynamicTypeSize)"), "the picker doesn't read the text size")
        // 15: a visible Remove on each bookmark
        let marks = try file("Views/Bookmarks.swift")
        let remove = part(marks, from: "ForEach(bookmarks", to: "#else")
        XCTAssertTrue(remove.contains("removing = bookmark"), "no visible Remove on a bookmark")
        XCTAssertFalse(remove.contains("managedObjectContext.delete(bookmark)"),
                       "one tap under a bookmark deletes it, with no second tap (phase 4 review)")
        XCTAssertTrue(marks.contains(".confirmationDialog("), "the visible Remove asks before it deletes")
    }

    /// The Today tab's mark (spec section 9; phase 4 review): read from Today's front page even while Today's own view
    /// has moved on to a guide or never loaded, so a warning still marks the tab from Maps or Inventory.
    func testTheTodayMarkReadsTodaysFrontPageWhereverTodayIs() throws {
        let live = try String(contentsOf: Self.repo.appendingPathComponent("app/Kiwix/PrepareMeApp/LiveConditions.swift"),
                              encoding: .utf8)
        guard let start = live.range(of: "private func showEverywhere()"),
              let end = live.range(of: "\n    }\n", range: start.upperBound..<live.endIndex) else {
            return XCTFail("showEverywhere wasn't found")
        }
        XCTAssertTrue(live[start.lowerBound..<end.lowerBound].contains("showOnTodaysFrontPage("),
                      "the mark is read only from views already on a front page")
        XCTAssertTrue(live.contains("startURL(.today)"), "Today's front page isn't looked up")
    }

    /// The Library is one drawing on every device (Library matches Guides plan, Task 2.1): the page is drawn by hand
    /// in the guide list's shapes, never the system's list or `PMCard`s, and the phones' Library is that page.
    func testTheLibraryIsOneDrawingOnEveryDevice() throws {
        let app = Self.repo.appendingPathComponent("app/Kiwix/PrepareMeApp")
        let page = try String(contentsOf: app.appendingPathComponent("PrepareMeLibraryPage.swift"), encoding: .utf8)
        XCTAssertFalse(page.contains("PMList"), "the Library page still draws the system's list")
        XCTAssertFalse(page.contains("PMCard("), "the Library page still draws PMCards")
        let tabs = try String(contentsOf: app.appendingPathComponent("PrepareMeTabs.swift"), encoding: .utf8)
        guard let start = tabs.range(of: "struct PhoneLibraryList"),
              let end = tabs.range(of: "\n}\n", range: start.upperBound..<tabs.endIndex) else {
            return XCTFail("PhoneLibraryList wasn't found")
        }
        XCTAssertTrue(tabs[start.lowerBound..<end.lowerBound].contains("PrepareMeLibraryPage(rows: .all"),
                      "the phones' Library isn't the shared page")
    }

    func testColorOnlyThroughThePagesTokens() throws {
        // A system color would mean something the pages don't say (orange marked life-safety, refusals and vehicles).
        let named = try NSRegularExpression(pattern: "(Color\\.|\\(|: |\\? )\\.?(red|orange|yellow|green|blue|purple|pink|mint|teal)\\b(?!:)")
        for (file, line, text, _, _) in try Self.screenLines() {
            let code = text.components(separatedBy: "//")[0]
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertFalse(named.firstMatch(in: code, range: range) != nil, "\(file):\(line): a color not from PrepareMeColors")
        }
    }
}
