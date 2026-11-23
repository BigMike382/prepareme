import Foundation

/// The Mac's Files… sheet for one device (family downloads plan, phase 6): the four words a row offers, the value each
/// is stored as in `phone-files.json`, and the device's room once the choices settle. Nothing here reads a file, so the
/// rules are tested on the Mac; the sheet holds its picks and saves them once, on Done.
public enum PhoneCuration {
    public enum Word: String, CaseIterable, Sendable {
        case byRoom = "By room", offered = "Offered", always = "Always", never = "Never"
    }

    /// The intro's four short lines, one per word
    public static let intro = [
        "By room: comes by itself while maps that come by themselves leave "
            + "\(StorageWords.size(LibraryPlan.reserve(capacity: 0))) free.",
        "Offered: doesn't come by itself; Download on the device gets it.",
        "Always: comes by itself, but never into the room the library needs to update.",
        "Never: the device doesn't see it, and lets go of its copy.",
    ]

    /// A by-room map offers all four words; any other file (a family download) Offered, Always and Never
    public static func words(_ entry: Manifest.Entry) -> [Word] {
        entry.fetch == LibraryPlan.room ? Word.allCases : [.offered, .always, .never]
    }

    /// The word a stored value shows as; nil is the file's default (`PhoneChoices.preset`). A "never" from before the
    /// plan is Offered, as the phone reads it; only "hide" is Never.
    public static func word(_ stored: String?, _ entry: Manifest.Entry, child: Bool, in manifest: Manifest) -> Word {
        switch stored ?? PhoneChoices.preset(entry, child: child, in: manifest) {
        case PhoneChoices.always: .always
        case PhoneChoices.never: .offered
        case PhoneChoices.hide: .never
        default: entry.fetch == LibraryPlan.room ? .byRoom : .offered
        }
    }

    /// The value a picked word is stored as: nil where it is the file's default anyway, so a default keeps following
    /// the list; "room" only to undo a map's default skip or Always.
    public static func stored(_ word: Word, _ entry: Manifest.Entry, child: Bool, in manifest: Manifest) -> String? {
        if self.word(nil, entry, child: child, in: manifest) == word { return nil }
        switch word {
        case .byRoom: return PhoneChoices.room
        case .offered: return PhoneChoices.never
        case .always: return PhoneChoices.always
        case .never: return PhoneChoices.hide
        }
    }

    /// The device's free space once these choices settle ("after these choices: about X"): its last report's free
    /// space, less what would come by itself as the phone weighs it (`LibraryPlan.split`: the Always files, then the
    /// by-room maps in order while 10 GB stays free), plus what it holds and would let go of (Never). What a person
    /// asked for on the device isn't known on the Mac, so it is about.
    public static func after(_ files: [String: String], room: PhoneStorage, child: Bool, in manifest: Manifest) -> Int64 {
        let settled = settle(files, room: room, child: child, in: manifest)
        let coming = (settled.sure + settled.take).filter { settled.record.held[$0.name] == nil }
        return room.free - coming.reduce(0) { $0 + $1.size } + settled.letGo
    }

    /// An Always this device can't take without going under the floor (phase 4, decision 1): the floor, to say in the
    /// refusal, or nil when it fits or the device already holds the file.
    public static func refusesAlways(_ name: String, _ files: [String: String], room: PhoneStorage, child: Bool,
                                     in manifest: Manifest) -> Int64? {
        guard !room.held.contains(name), room.sharesRoom else { return nil }  // unknown room: the device decides
        var picked = files
        picked[name] = PhoneChoices.always
        return settle(picked, room: room, child: child, in: manifest).wait.contains { $0.name == name }
            ? LibraryPlan.floor(manifest.files) : nil
    }

    /// The bytes a row turned to Never frees on this device: the file's size when it holds it
    public static func removes(_ entry: Manifest.Entry, room: PhoneStorage?) -> Int64? {
        room?.held.contains(entry.name) == true ? entry.size : nil
    }

    /// The list as the service would serve it with these choices (one device's), and a record of what the device
    /// holds, weighed as the phone weighs them. The Mac knows only the names held, so each counts as current.
    static func settle(_ files: [String: String], room: PhoneStorage, child: Bool, in manifest: Manifest)
        -> (sure: [Manifest.Entry], take: [Manifest.Entry], wait: [Manifest.Entry], record: LibraryRecord,
            letGo: Int64) {
        let all = ["device": PhoneChoices.Entry(paired: "now", files: files)]
        let hidden = PhoneChoices.hidden(all, for: "device", paired: "now", in: manifest)
        var served = Manifest(writtenAt: manifest.writtenAt,
                              files: manifest.files.filter { $0.forPhones && !hidden.contains($0.name) })
        served.choices = PhoneChoices.choices(all, for: "device", paired: "now", child: child, in: served)
        var record = LibraryRecord(manifest: served)
        for entry in served.files where room.held.contains(entry.name) {
            record.held[entry.name] = HeldFile(entry: entry, file: entry.name)
        }
        let letGo = manifest.files.filter { hidden.contains($0.name) && room.held.contains($0.name) }
            .reduce(0) { $0 + $1.size }
        let split = LibraryPlan.split(LibraryPlan.eligible(served, record), record,
                                      room: LibraryPlan.Room(free: room.free + letGo, capacity: room.capacity),
                                      floor: LibraryPlan.floor(served.files))
        return (split.sure, split.take, split.wait, record, letGo)
    }

    /// The For the family tick's question before un-ticking a file devices hold (decision 3)
    public static func untickAsk(devices: Int, size: Int64) -> String {
        "\(devices) \(devices == 1 ? "device holds" : "devices hold") it (\(StorageWords.size(size))). "
            + "Remove it from \(devices == 1 ? "that device" : "them")?"
    }

    /// Beside the For the family tick: which children's devices will see the file (all but those set to Never)
    public static func childrenLine(seeing: [String], neverOn: Int) -> String? {
        if !seeing.isEmpty { return "Children's devices that will see it: \(seeing.joined(separator: ", "))." }
        return neverOn > 0 ? "No child's device will see it: each is set to Never in Files…." : nil
    }

    // MARK: A device paired again (decision 7; owner, 2026-11-15, by click: the owner picks it on the Mac)

    /// Add a device's "paired before" pick, step by step: `pending` maps the new pairing's key to the one it takes the
    /// place of (keys as `PhonePairing.key`, "label|added"). Once the new pairing is listed it takes the old one's name
    /// and choices (restamped with its own pairing time), unless it has its own; once it has visited, the old pairing is
    /// named in `remove`. A pick ends when the old pairing is gone. Only the owner's pick carries anything, so a device
    /// that merely takes a freed label never inherits.
    public struct Carry: Equatable, Sendable {
        public var choices: [String: PhoneChoices.Entry]
        public var names: [String: String]
        public var pending: [String: String]
        public var remove: [PairingDesk.Phone]
    }

    public static func carry(_ pending: [String: String], listed: [PairingDesk.Phone],
                             choices: [String: PhoneChoices.Entry], names: [String: String]) -> Carry {
        func key(_ phone: PairingDesk.Phone) -> String { "\(phone.label)|\(phone.added)" }
        var out = Carry(choices: choices, names: names, pending: [:], remove: [])
        for (newKey, oldKey) in pending {
            guard let old = listed.first(where: { key($0) == oldKey }) else { continue }  // gone: nothing left to carry
            out.pending[newKey] = oldKey
            // shortcut: a new pairing removed before it visits leaves its pick here, harmless, until the old one goes
            guard let new = listed.first(where: { key($0) == newKey }) else { continue }  // not listed yet
            if out.names[newKey] == nil, let name = names[oldKey] { out.names[newKey] = name }
            if out.choices[new.label]?.paired != new.added, let from = choices[old.label], from.paired == old.added {
                out.choices[new.label] = PhoneChoices.Entry(paired: new.added, files: from.files)
            }
            if !new.waiting { out.remove.append(old) }
        }
        return out
    }
}
