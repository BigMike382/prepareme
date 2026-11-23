import CryptoKit
import Foundation
import Testing
@testable import PrepareMeShared

/// Audit P2h: the format number in the list of files the Mac serves, the backup's list and the phones' inventory copy,
/// held to the plan's section 6 table: an older phone with a newer Mac, a newer phone with an older Mac, and a phone
/// stepped back a build; and a phone meeting a newer number keeps what it holds. Made-up lists and the rehearsal copy.
@MainActor
struct FileFormatTests {
    static let list = #"{"written_at":"2026-11-22T00:00:00Z","files":[]}"#

    static func listed(_ format: Int?) throws -> Data {
        var manifest = try Manifest.read(Data(list.utf8))
        manifest.format = format
        return try manifest.encoded()
    }

    static func copy() throws -> PhoneInventory {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("format-\(UUID()).grist")
        try FileManager.default.copyItem(at: InventoryTests.fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let editor = try InventoryEditor(file: try InventoryFile(url: url), checker: FakeCheck())
        return PhoneInventory.make(editor.inventory, toBuy: nil, waiting: [], results: [:])
    }

    @Test func aListInThisFormatOrNoneReadsAndANewerOneIsRefused() throws {
        #expect(try Manifest.read(Data(Self.list.utf8)).format == nil, "an older Mac's list: format 1")
        #expect(try Manifest.read(Self.listed(1)).format == 1)
        #expect(throws: Manifest.Problem.newer) { try Manifest.read(Self.listed(FileFormat.current + 1)) }
        #expect(!FileFormat.isNewer(nil) && !FileFormat.isNewer(1) && FileFormat.isNewer(2))
    }

    /// An older phone, a newer Mac (and a phone stepped back a build, reading what the newer one saved): its decoders
    /// know no `format` and skip it, so it reads the list and the copy as before.
    @Test func anOlderPhoneSkipsTheNumber() throws {
        struct BeforeList: Decodable { let files: [Manifest.Entry] }
        struct BeforeCopy: Decodable { let items: [PhoneInventory.Row] }
        let copy = try Self.copy()
        #expect(copy.format == FileFormat.current, "the Mac writes the number")
        let data = try JSONEncoder().encode(copy)
        #expect(try JSONDecoder().decode(BeforeList.self, from: Self.listed(1)).files.isEmpty)
        #expect(try JSONDecoder().decode(BeforeCopy.self, from: data).items.count == copy.items.count)
        let cache = PhoneInventoryCache(copy: copy, canEdit: true, at: Date(), fromBackup: false)
        struct BeforeCache: Decodable { let copy: BeforeCopy }
        #expect(try JSONDecoder().decode(BeforeCache.self, from: JSONEncoder().encode(cache)).copy.items.count
                == copy.items.count)
    }

    /// A newer phone, an older Mac: no number reads as format 1.
    @Test func aNewerPhoneReadsAnOlderMacsCopy() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.copy())) as? [String: Any])
        object["format"] = nil
        let older = try JSONDecoder().decode(PhoneInventory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.format == nil && !FileFormat.isNewer(older.format))
    }

    /// A backup folder whose list is newer than this build: refused as newer, in its own words, nothing offered; and
    /// a newer copy is never read from a backup, whatever its list says.
    @Test func aNewerBackupIsRefusedInItsOwnWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("format-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var newer = try Manifest.read(Data(Self.list.utf8))
        newer.format = FileFormat.current + 1
        try BackupSignature.sign(newer, with: P256.Signing.PrivateKey()).write(to: folder.appendingPathComponent("manifest.json"))
        let found = FolderRead.list(in: folder, named: "manifest.json", parse: BackupSignature.read)
        guard case .failure(let refusal) = found else { Issue.record("taken: \(found)"); return }
        #expect(refusal == .newer)
        #expect(refusal.words(noList: "", damaged: "", unreadable: "", device: "phone")
                == "The Mac has a newer PrepareMe. Update PrepareMe on this phone to get the newest files.")

        var copy = try Self.copy()
        copy.format = FileFormat.current + 1
        let data = try JSONEncoder().encode(copy)
        let entry = Manifest.Inventory(name: PhoneInventory.fileName, size: Int64(data.count),
                                       sha256: Hex.string(SHA256.hash(data: data)), writtenAt: copy.writtenAt)
        #expect(FolderOffer.readInventory(data, entry: entry) == nil)
        copy.format = FileFormat.current
        let same = try JSONEncoder().encode(copy)
        let sameEntry = Manifest.Inventory(name: PhoneInventory.fileName, size: Int64(same.count),
                                           sha256: Hex.string(SHA256.hash(data: same)), writtenAt: copy.writtenAt)
        #expect(FolderOffer.readInventory(same, entry: sameEntry) == copy)
    }

    @Test func theLinesSayWhichDevice() {
        #expect(FileFormat.newerInventory(device: "iPad")
                == "The Mac has a newer PrepareMe. Update PrepareMe on this iPad to see the newest inventory.")
    }
}
