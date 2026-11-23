import Foundation
import PrepareMeShared
import Testing

/// Family downloads plan, phase 6: the Mac's Files… sheet's words, what each is stored as, and the device's room once
/// the choices settle. Made-up lists.
struct PhoneCurationTests {
    static let gb: Int64 = 1_000_000_000

    static func entry(_ name: String, kind: String = "map-optional", size: Int64 = 2 * gb, fetch: String? = "room",
                      order: Int? = nil, family: Bool? = nil) -> Manifest.Entry {
        Manifest.Entry(name: name, id: name, kind: kind, size: size, sha256: String(repeating: "a", count: 64),
                       deliveredAt: "2026-11-15T12:00:00-05:00", family: family, fetch: fetch, order: order)
    }

    static let library = entry("prepareme-daily.zim", kind: "library", size: 3 * gb, fetch: "base")
    static let overview = entry("prepareme-maps-topo-overview.zim", order: 4)
    static let border = entry("prepareme-maps-border-north.zim", order: 5)
    static let nearest = entry("prepareme-maps-topo-today-1.zim", order: 6)
    static let family = entry("wikivet_en_all_2026-01.zim", kind: "download", size: 5 * gb, fetch: nil, family: true)
    static let manifest = Manifest(writtenAt: "x", files: [library, overview, border, nearest, family])

    func room(free: Int64, held: [String] = []) -> PhoneStorage {
        PhoneStorage(free: free, capacity: 128 * Self.gb, held: held, waiting: [], cantUpdate: [])
    }

    @Test func eachRowOffersOnlyTheWordsThatApply() {
        #expect(PhoneCuration.words(Self.border) == [.byRoom, .offered, .always, .never])
        #expect(PhoneCuration.words(Self.family) == [.offered, .always, .never])
        #expect(PhoneCuration.intro.count == 4)
        #expect(PhoneCuration.intro[0] == "By room: comes by itself while maps that come by themselves leave 10.0 GB free.")
    }

    @Test func theStartingChoices() {
        let m = Self.manifest
        // a child's map after the overview starts at Offered (its default skip); a family file at Offered
        #expect(PhoneCuration.word(nil, Self.border, child: true, in: m) == .offered)
        #expect(PhoneCuration.word(nil, Self.family, child: true, in: m) == .offered)
        #expect(PhoneCuration.word(nil, Self.family, child: false, in: m) == .offered)
        // an adult's nearest today's topo starts at Always; an adult's other map by room
        #expect(PhoneCuration.word(nil, Self.nearest, child: false, in: m) == .always)
        #expect(PhoneCuration.word(nil, Self.border, child: false, in: m) == .byRoom)
        // a "never" from before the plan is Offered; only "hide" is Never
        #expect(PhoneCuration.word("never", Self.border, child: false, in: m) == .offered)
        #expect(PhoneCuration.word("hide", Self.family, child: false, in: m) == .never)
    }

    @Test func aWordIsStoredOnlyWhenItIsNotTheDefault() {
        let m = Self.manifest
        #expect(PhoneCuration.stored(.offered, Self.family, child: false, in: m) == nil)
        #expect(PhoneCuration.stored(.never, Self.family, child: false, in: m) == "hide")
        #expect(PhoneCuration.stored(.always, Self.family, child: false, in: m) == "always")
        #expect(PhoneCuration.stored(.offered, Self.border, child: true, in: m) == nil)
        #expect(PhoneCuration.stored(.byRoom, Self.border, child: true, in: m) == "room")
        #expect(PhoneCuration.stored(.byRoom, Self.nearest, child: false, in: m) == "room")
        #expect(PhoneCuration.stored(.offered, Self.border, child: false, in: m) == "never")
        for word in PhoneCuration.Word.allCases {  // every word shows again as itself
            let value = PhoneCuration.stored(word, Self.border, child: true, in: m)
            #expect(PhoneCuration.word(value, Self.border, child: true, in: m) == word)
        }
    }

    @Test func byRoomOverADefaultIsServedAsNoChoice() {
        let all = ["phone 2": PhoneChoices.Entry(paired: "p", files: [Self.border.name: "room"])]
        let served = PhoneChoices.choices(all, for: "phone 2", paired: "p", child: true, in: Self.manifest)
        #expect(served?[Self.border.name] == nil)  // by room, so the phone takes it in its turn
        #expect(served?[Self.nearest.name] == "never")  // the child's other defaults stand
    }

    @Test func roomAfterTheChoices() {
        let m = Self.manifest
        let child = room(free: 40 * Self.gb, held: [Self.library.name, Self.overview.name])
        #expect(PhoneCuration.after([:], room: child, child: true, in: m) == 40 * Self.gb)  // nothing more comes
        // the family file set to Always comes by itself: 5 GB less
        #expect(PhoneCuration.after([Self.family.name: "always"], room: child, child: true, in: m) == 35 * Self.gb)
        // Never on a held map frees its size
        #expect(PhoneCuration.after([Self.overview.name: "hide"], room: child, child: true, in: m) == 42 * Self.gb)
        #expect(PhoneCuration.removes(Self.overview, room: child) == 2 * Self.gb)
        #expect(PhoneCuration.removes(Self.border, room: child) == nil)
        // by room, maps come in order while 10 GB stays free: 40 less two 2 GB maps
        let adult = room(free: 40 * Self.gb, held: [Self.library.name])
        #expect(PhoneCuration.after([:], room: adult, child: false, in: m) == 34 * Self.gb)
    }

    @Test func anAlwaysPastTheFloorIsRefused() {
        let m = Self.manifest  // the floor: the 3 GB library and the 1 GiB spare
        let tight = room(free: 8 * Self.gb, held: [Self.library.name])
        #expect(PhoneCuration.refusesAlways(Self.family.name, [:], room: tight, child: true, in: m)
                    == LibraryPlan.floor(m.files))
        let roomy = room(free: 20 * Self.gb, held: [Self.library.name])
        #expect(PhoneCuration.refusesAlways(Self.family.name, [:], room: roomy, child: true, in: m) == nil)
        let held = room(free: 1 * Self.gb, held: [Self.library.name, Self.family.name])
        #expect(PhoneCuration.refusesAlways(Self.family.name, [:], room: held, child: true, in: m) == nil)
        var notShared = room(free: 0, held: [Self.library.name])  // its person said no: 0 and 0 (Unlisted phase 4)
        notShared.capacity = 0
        #expect(PhoneCuration.refusesAlways(Self.family.name, [:], room: notShared, child: true, in: m) == nil,
                "a room the Mac doesn't know never refuses: the device decides")
    }

    @Test func theForTheFamilyWords() {
        #expect(PhoneCuration.untickAsk(devices: 2, size: 5 * Self.gb) == "2 devices hold it (5.0 GB). Remove it from them?")
        #expect(PhoneCuration.untickAsk(devices: 1, size: 5 * Self.gb) == "1 device holds it (5.0 GB). Remove it from that device?")
        #expect(PhoneCuration.childrenLine(seeing: ["Sam (phone 2)", "phone 3"], neverOn: 0)
                    == "Children's devices that will see it: Sam (phone 2), phone 3.")
        #expect(PhoneCuration.childrenLine(seeing: [], neverOn: 1)
                    == "No child's device will see it: each is set to Never in Files….")
        #expect(PhoneCuration.childrenLine(seeing: [], neverOn: 0) == nil)
    }

    @Test func aDevicePairedAgainKeepsItsChoicesOnlyByTheOwnersPick() {
        let old = PairingDesk.Phone(label: "phone 2", added: "2026-11-02T10:00:00-05:00", readOnly: true)
        var new = PairingDesk.Phone(label: "phone 4", added: "2026-11-15T15:00:00-05:00", readOnly: true, waiting: true)
        let stranger = PairingDesk.Phone(label: "phone 3", added: "2026-11-15T15:05:00-05:00", readOnly: true)
        let choices = ["phone 2": PhoneChoices.Entry(paired: old.added, files: [Self.family.name: "hide"])]
        let names = ["phone 2|\(old.added)": "Sam"]
        let pick = ["phone 4|\(new.added)": "phone 2|\(old.added)"]
        // not listed yet: the pick waits, nothing carried
        var step = PhoneCuration.carry(pick, listed: [old], choices: choices, names: names)
        #expect(step.pending == pick && step.choices == choices && step.remove.isEmpty)
        // listed, waiting for its first visit: it takes the name and the choices, restamped; the old one stays
        step = PhoneCuration.carry(pick, listed: [old, new, stranger], choices: choices, names: names)
        #expect(step.choices["phone 4"] == PhoneChoices.Entry(paired: new.added, files: [Self.family.name: "hide"]))
        #expect(step.names["phone 4|\(new.added)"] == "Sam")
        #expect(step.choices["phone 3"] == nil && step.names["phone 3|\(stranger.added)"] == nil)  // never inherits
        #expect(step.remove.isEmpty)
        // visited: the old pairing goes
        new.waiting = false
        step = PhoneCuration.carry(pick, listed: [old, new], choices: step.choices, names: step.names)
        #expect(step.remove == [old])
        // choices the owner set on the new one since are never overwritten
        var own = step.choices
        own["phone 4"] = PhoneChoices.Entry(paired: new.added, files: [:])
        #expect(PhoneCuration.carry(pick, listed: [old, new], choices: own, names: names).choices["phone 4"]?.files == [:])
        // the old one removed: the pick ends
        #expect(PhoneCuration.carry(pick, listed: [new], choices: own, names: names).pending.isEmpty)
    }

    @Test func thePairedBeforeWords() {
        #expect(PairingWords.takesThePlace(of: "Sam (phone 2)")
                    == "It takes the name and Files… choices of Sam (phone 2), which is removed once this one visits.")
    }
}
