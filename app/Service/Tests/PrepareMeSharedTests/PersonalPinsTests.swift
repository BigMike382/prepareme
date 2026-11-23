import Foundation
import PrepareMeShared
import XCTest

/// A phone's own pins (plan phase 9, item 8): fixed labels only, kept on the phone, in its own backup. Made-up spots.
final class PersonalPinsTests: XCTestCase {
    func testPinsAreAddedRelabeledRemovedAndKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var pins = PersonalPins()
        let tree = try XCTUnwrap(pins.add(.treeDown, longitude: -40.1234567, latitude: 10.7654321))
        XCTAssertEqual([tree.longitude, tree.latitude], [-40.123457, 10.765432])
        let car = try XCTUnwrap(pins.add(.car, longitude: -40.2, latitude: 10.8))
        pins.relabel(car.id, .meet)
        pins.remove(tree.id)
        try pins.save(folder)
        let back = PersonalPins.load(folder)
        XCTAssertEqual(back.pins.map(\.label), [.meet])
        XCTAssertEqual(back, pins)
        // in the device's backup (audit D1; owner, 2026-11-22), and an earlier build's mark is taken off when read
        let url = folder.appendingPathComponent(PersonalPins.fileName)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
        try EarlierBuild.leaveBackupMark(on: url)
        _ = PersonalPins.load(folder)
        XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup, false)
    }

    /// Audit D3: a damaged file is renamed aside with the date and never written over; the map says so once.
    func testADamagedFileIsSetAsideNeverWrittenOver() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(PersonalPins.fileName)
        try Data("not json".utf8).write(to: url)
        var pins = PersonalPins.load(folder, now: Date(timeIntervalSince1970: 1_795_000_000))
        let aside = try XCTUnwrap(pins.setAside)
        XCTAssertTrue(aside.hasPrefix("personal-pins-unreadable-") && aside.hasSuffix(".json"))
        XCTAssertEqual(pins.problem, PersonalPins.setAsideWords)
        XCTAssertTrue(pins.pins.isEmpty && !pins.blocked)
        pins.add(.water, longitude: -40, latitude: 10)
        try pins.save(folder)  // a fresh list beside the one set aside
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8), "not json")
        let back = PersonalPins.load(folder)
        XCTAssertEqual(back.pins.count, 1)
        XCTAssertNil(back.problem, "said once: the next opening finds the fresh list")
    }

    /// A file there but unreadable now (still locked after a restart, say) is left alone, and nothing saves over it,
    /// whether by adding, merging another phone's pins or deleting them all.
    func testAFileThatCantBeReadNowIsNeverWrittenOver() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(PersonalPins.fileName)
        var kept = PersonalPins()
        kept.add(.car, longitude: -40, latitude: 10)
        try kept.save(folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: folder)
        }
        var pins = PersonalPins.load(folder)
        XCTAssertTrue(pins.blocked)
        XCTAssertNil(pins.setAside)
        XCTAssertEqual(pins.problem, PersonalPins.blockedWords)
        pins.add(.water, longitude: -40, latitude: 10)
        XCTAssertThrowsError(try pins.save(folder))
        XCTAssertThrowsError(try pins.merged(with: kept.pins).pins.save(folder))
        pins.removeAll()
        XCTAssertThrowsError(try pins.save(folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(PersonalPins.load(folder).pins, kept.pins, "the file as it was")
    }

    func testOffTheMapOrPastTheLimitIsRefused() {
        var pins = PersonalPins()
        XCTAssertNil(pins.add(.water, longitude: -200, latitude: 10))
        XCTAssertNil(pins.add(.water, longitude: .nan, latitude: 10))
        for _ in 0..<PersonalPins.limit { pins.add(.water, longitude: -40, latitude: 10) }
        XCTAssertNil(pins.add(.water, longitude: -40, latitude: 10))
        XCTAssertEqual(PersonalPins.load(URL(fileURLWithPath: "/nonexistent")).pins, [])
    }

    func testTheLabelsAreAFixedSet() {
        XCTAssertEqual(PersonalPins.Label.allCases.count, 10)
        let json = try? JSONSerialization.jsonObject(with: PersonalPins(pins: []).geoJSON) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "FeatureCollection")
    }

    /// A tapped pin comes back with its id only as a property: MapLibre parses a string feature id as a number.
    func testEachPinCarriesItsIdAsAProperty() throws {
        var pins = PersonalPins()
        let pin = try XCTUnwrap(pins.add(.car, longitude: -40.2, latitude: 10.8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: pins.geoJSON) as? [String: Any])
        let feature = try XCTUnwrap((json["features"] as? [[String: Any]])?.first)
        XCTAssertNil(feature["id"])
        XCTAssertEqual((feature["properties"] as? [String: Any])?["pin"] as? String, pin.id.uuidString)
    }

    /// Remove this pin asks first (the street map fixes plan, task 3.1), naming the kind as the map shows it.
    func testTheRemoveQuestionNamesTheKind() {
        XCTAssertEqual(PersonalPins.removeQuestion(.water), "Remove the Water pin?")
        XCTAssertEqual(PersonalPins.removeQuestion(.powerLine), "Remove the Power line down pin?")
    }

    /// Each kind has its own symbol and one of BASE's color roles (task 3.2): blue a key fact, green fine, red danger,
    /// amber caution; the symbol is a shape too, so red night keeps the kinds apart. The map gets each pin's color as
    /// the token's light value, which reads under the white symbol on both map themes.
    func testEveryKindHasAColorRoleAndASymbol() throws {
        let labels = PersonalPins.Label.allCases
        XCTAssertEqual(Set(labels.map(\.symbol)).count, labels.count, "every kind its own symbol")
        XCTAssertTrue(labels.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertTrue(Set(labels.map(\.color)).isSubset(of: ["info-mark", "ok-mark", "red-mark", "accent"]))
        XCTAssertTrue(labels.allSatisfy { Palette.tokens[$0.color] != nil }, "BASE's tokens only")
        XCTAssertEqual(PersonalPins.Label.water.color, "info-mark")
        XCTAssertEqual(PersonalPins.Label.shelter.color, "ok-mark")
        XCTAssertEqual(PersonalPins.Label.danger.color, "red-mark")
        XCTAssertEqual(PersonalPins.Label.powerLine.color, "red-mark")
        for label in [PersonalPins.Label.treeDown, .flooded, .blocked, .car, .meet, .other] {
            XCTAssertEqual(label.color, "accent", label.rawValue)
        }
        var pins = PersonalPins()
        pins.add(.danger, longitude: -40, latitude: 10)
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: pins.geoJSON) as? [String: Any])
        let properties = try XCTUnwrap((all["features"] as? [[String: Any]])?.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["color"] as? String, "#b91c1c")
        XCTAssertEqual(properties["nightColor"] as? String, "#ffffff")
        XCTAssertEqual(properties["nightIcon"] as? String, "pm-pin-dark-Danger")
    }

    /// Red night (the W9 review; owner, 2026-10-25): the red and amber kinds' symbols are drawn dark, as their dots
    /// come out mid red; blue and green dots come out near black and keep the white symbol; danger's dot is white, the
    /// brightest on the screen.
    func testRedNightDrawsTheRedAndAmberKindsDark() {
        for label in PersonalPins.Label.allCases {
            XCTAssertEqual(label.nightDark, ["red-mark", "accent"].contains(label.color), label.rawValue)
            XCTAssertEqual(label.nightIcon, (label.nightDark ? "pm-pin-dark-" : "pm-pin-") + label.rawValue)
            XCTAssertEqual(label.nightColor == "#ffffff", label.color == "red-mark", label.rawValue)
        }
        XCTAssertFalse(PersonalPins.Label.water.nightDark)
        XCTAssertFalse(PersonalPins.Label.shelter.nightDark)
    }

    /// A phone at the 200 limit says so in place of the kinds (task 3.3; review focus 5), and nothing is lost.
    func testAFullPhoneSaysSo() {
        var pins = PersonalPins()
        for n in 0..<PersonalPins.limit { pins.add(.water, longitude: -40, latitude: 10 + Double(n) / 1000) }
        XCTAssertTrue(pins.full)
        XCTAssertNil(pins.add(.car, longitude: -40, latitude: 11))
        XCTAssertEqual(pins.pins.count, 200)
        XCTAssertEqual(PersonalPins.fullWords(device: "phone"),
                       "This phone holds 200 pins, the most it keeps. Remove one to add another.")
        pins.remove(pins.pins[0].id)
        XCTAssertFalse(pins.full)
    }

    // Sharing pins between phones (the street map fixes plan, task 4.1): made-up spots.

    /// Two pins of one kind within 5 m are one pin: the newer is kept. Another kind at the same spot stays its own.
    func testMergeKeepsTheNewestOfTwoAtOneSpot() throws {
        let old = Date(timeIntervalSince1970: 1_800_000_000), new = old.addingTimeInterval(3600)
        var mine = PersonalPins()
        mine.add(.water, longitude: -40, latitude: 10, at: old)
        mine.add(.car, longitude: -40.5, latitude: 10.5, at: new)
        var theirs = PersonalPins()
        let water = try XCTUnwrap(theirs.add(.water, longitude: -40.00003, latitude: 10, at: new))  // about 3 m east
        theirs.add(.danger, longitude: -40, latitude: 10, at: old)
        let car = try XCTUnwrap(theirs.add(.car, longitude: -40.5, latitude: 10.5, at: old))  // older: mine stays
        let result = mine.merged(with: theirs.pins)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.already, 2)
        XCTAssertEqual(result.leftOut, 0)
        XCTAssertEqual(result.pins.pins.count, 3)
        XCTAssertEqual(result.pins.pins.first { $0.label == .water }, water, "the newer water pin replaces mine")
        XCTAssertNotEqual(result.pins.pins.first { $0.label == .car }?.id, car.id, "my newer car pin stays")
        XCTAssertEqual(result.pins.pins.filter { $0.label == .danger }.count, 1)
        XCTAssertEqual(mine.merged(with: theirs.pins).pins, result.pins, "the same file twice adds nothing more")
        XCTAssertEqual(result.pins.merged(with: theirs.pins).added, 0)
    }

    func testMergeNeverPassesTheLimit() {
        var mine = PersonalPins()
        for n in 0..<(PersonalPins.limit - 1) { mine.add(.water, longitude: -40, latitude: 10 + Double(n) / 1000) }
        var theirs = PersonalPins()
        for n in 0..<3 { theirs.add(.shelter, longitude: -30, latitude: 10 + Double(n) / 1000) }
        let result = mine.merged(with: theirs.pins)
        XCTAssertEqual(result.pins.pins.count, PersonalPins.limit)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.leftOut, 2)
        XCTAssertEqual(PersonalPins.mergeWords(added: 1, already: 0, leftOut: 2, device: "phone"),
                       "Added 1 pin. 2 left out: this phone holds 200 pins, the most it keeps.")
        XCTAssertEqual(PersonalPins.mergeWords(added: 3, already: 1, leftOut: 0, device: "phone"),
                       "Added 3 pins. 1 was already here.")
        XCTAssertEqual(PersonalPins.mergeWords(added: 0, already: 2, leftOut: 0, device: "phone"),
                       "Added 0 pins. 2 were already here.")
    }

    /// The shared file says what it is, carries only kinds, places and times, and reads back; anything else, or a pin
    /// off the map, is refused whole.
    func testTheSharedFileReadsBackAndRefusesOthers() throws {
        var pins = PersonalPins()
        pins.add(.treeDown, longitude: -40.1, latitude: 10.2, at: Date(timeIntervalSince1970: 1_800_000_000))
        pins.add(.meet, longitude: -40.3, latitude: 10.4, at: Date(timeIntervalSince1970: 1_800_000_100))
        let data = try pins.shared()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(#"{"pins":["#) && text.contains(#""prepareme":"pins""#), text)
        XCTAssertEqual(PersonalPins.read(shared: data), pins.pins)
        XCTAssertEqual(PersonalPins.sharedFileName, "PrepareMe pins.json")
        XCTAssertEqual(PersonalPins.sharedType, "com.bigmike382.prepareme.pins")
        XCTAssertNil(PersonalPins.read(shared: Data(#"{"pins":[]}"#.utf8)), "no mark: not a PrepareMe pins file")
        XCTAssertNil(PersonalPins.read(shared: Data("not json".utf8)))
        let offMap = text.replacingOccurrences(of: "-40.1", with: "-400.1")
        XCTAssertNil(PersonalPins.read(shared: Data(offMap.utf8)))
        let unknown = text.replacingOccurrences(of: "Tree down", with: "Typed words")
        XCTAssertNil(PersonalPins.read(shared: Data(unknown.utf8)), "only the fixed kinds, never typed words")
        XCTAssertEqual(PersonalPins.readWrong, "That file isn't PrepareMe pins.")
    }
}
