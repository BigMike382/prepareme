import CryptoKit
import Foundation
import PrepareMeShared
import XCTest

/// What a phone may take from a picked PrepareMe Backup folder (concept-doc plan, phase B; owner, 2026-10-18): each file
/// the folder's list names, against what the phone holds, with the list's signature checked against the key the phone
/// learned from its Mac. Made-up lists and records only.
final class FolderOfferTests: XCTestCase {
    let mac = P256.Signing.PrivateKey()
    static let ids = ["0f1e2d3c-4b5a-4968-8776-6554433221a1", "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                      "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"]

    func entry(_ name: String = "prepareme-daily.zim", id: String = ids[0], kind: String = "library",
               sha: Character = "a", at: String = "2026-10-18T12:00:00-04:00", size: Int64 = 100,
               family: Bool? = nil) -> Manifest.Entry {
        Manifest.Entry(name: name, id: id, kind: kind, size: size, sha256: String(repeating: sha, count: 64),
                       deliveredAt: at, family: family)
    }

    func record(holding entries: [Manifest.Entry], key: String? = nil) -> LibraryRecord {
        var record = LibraryRecord()
        for entry in entries { record.held[entry.name] = HeldFile(entry: entry, file: "copy-\(entry.name)") }
        record.manifest = Manifest(writtenAt: "x", files: entries, backupKey: key)
        return record
    }

    func list(_ entries: [Manifest.Entry], signedBy key: P256.Signing.PrivateKey? = nil) throws -> BackupSignature.Read {
        let manifest = Manifest(writtenAt: "2026-10-18T13:00:00-04:00", files: entries)
        return try BackupSignature.read(key.map { try BackupSignature.sign(manifest, with: $0) } ?? manifest.encoded())
    }

    func present(_ entries: [Manifest.Entry]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.size) })
    }

    var macKey: String { BackupSignature.publicKey(of: mac) }

    /// Beta run 2, B2-17: Add from Files opens with one short line, the folder named once.
    func testAddFromFilesSaysItInOneShortLine() {
        XCTAssertEqual(FolderOffer.addIntro, "When the Mac can't be reached: pick the PrepareMe Backup folder (iCloud Drive "
                       + "or a USB-C drive). Each file is checked first.")
        XCTAssertTrue(FolderOffer.addIntro.contains(Backup.folderName))
    }

    func testEachFileIsMissingNewerTheSameOrOlder() throws {
        let held = [entry(), entry("roads.zim", id: Self.ids[1], kind: "map-core"),
                    entry("topo.zim", id: Self.ids[2], kind: "map-optional", at: "2026-10-18T12:00:00-04:00")]
        let folder = [entry(sha: "b", at: "2026-10-18T18:00:00-04:00"),  // newer
                      entry("roads.zim", id: Self.ids[1], kind: "map-core"),  // the same
                      entry("topo.zim", id: Self.ids[2], kind: "map-optional", sha: "c", at: "2026-10-01T09:00:00-04:00"),
                      entry("streets.pmtiles", id: "0f1e2d3c-4b5a-4968-8776-6554433221b3", kind: "map")]  // missing
        let offer = FolderOffer.make(try list(folder, signedBy: mac), present: present(folder),
                                     record: record(holding: held, key: macKey), child: false)
        XCTAssertEqual(offer.trust, .signedByThisMac)
        XCTAssertEqual(offer.items.map(\.state), [.newer, .same, .older, .missing])
        XCTAssertEqual(offer.items[2].heldDeliveredAt, "2026-10-18T12:00:00-04:00")
        XCTAssertFalse(offer.items[0].needsAdult)
        XCTAssertTrue(offer.items[2].needsAdult)  // older: shown with both dates, an adult confirms
        XCTAssertEqual(FolderOffer.takeAll(offer).map(\.state), [.newer, .missing])  // never older, never the same
    }

    func testAFamilyFalseOrUnlistedOrMissingFileIsNeverOffered() throws {
        let mine = entry("wikipedia.zim", id: Self.ids[1], kind: "download", family: false)
        let gone = entry("gone.zim", id: Self.ids[2])
        let offer = FolderOffer.make(try list([entry(), mine, gone], signedBy: mac),
                                     present: present([entry(), mine]).merging(["planted.zim": 5]) { a, _ in a },
                                     record: record(holding: [], key: macKey), child: false)
        XCTAssertEqual(offer.items.map(\.entry.name), ["prepareme-daily.zim"])
        XCTAssertEqual(offer.absent, ["gone.zim"])  // listed, but not in the folder: said, never offered
    }

    /// Family downloads plan, phase 2 (decision 6): a child's device takes only from its own Mac's signed list, only
    /// missing or newer files the Mac sends it; an older copy is shown without its Add, the rest left out
    func testAChildsDeviceTakesOnlyMissingOrNewerFilesItsMacSends() throws {
        let held = [entry(), entry("roads.zim", id: Self.ids[1], kind: "map-core"),
                    entry("topo.zim", id: Self.ids[2], kind: "map-optional"),
                    entry("other.zim", id: "0f1e2d3c-4b5a-4968-8776-6554433221c4", kind: "map-optional")]
        let streets = entry("streets.pmtiles", id: "0f1e2d3c-4b5a-4968-8776-6554433221b3", kind: "map")
        let kept = entry("wikipedia.zim", id: "0f1e2d3c-4b5a-4968-8776-6554433221d5", kind: "download", family: true)
        let folder = [entry(sha: "b", at: "2026-10-18T18:00:00-04:00"),  // newer
                      entry("roads.zim", id: Self.ids[1], kind: "map-core"),  // the same
                      entry("topo.zim", id: Self.ids[2], kind: "map-optional", sha: "c", at: "2026-10-01T09:00:00-04:00"),
                      entry("other.zim", id: "0f1e2d3c-4b5a-4968-8776-6554433221c4", kind: "map-optional", sha: "d"),
                      streets,  // missing, and the Mac sends it
                      kept]  // missing, but the Mac doesn't send it to this device
        var record = record(holding: held, key: macKey)
        record.manifest?.files.append(streets)
        let offer = FolderOffer.make(try list(folder, signedBy: mac), present: present(folder), record: record,
                                     child: true)
        XCTAssertNil(offer.childRefusal)
        XCTAssertEqual(offer.items.map(\.entry.name), ["prepareme-daily.zim", "roads.zim", "topo.zim", "streets.pmtiles"])
        XCTAssertEqual(offer.items.map(\.state), [.newer, .same, .older, .missing])  // never "different", never unsent
        XCTAssertEqual(offer.items.map(\.addable), [true, true, false, true])
        XCTAssertEqual(FolderOffer.takeAll(offer).map(\.entry.name), ["prepareme-daily.zim", "streets.pmtiles"])
        XCTAssertFalse(FolderOffer.takeAll(offer).contains(where: \.needsAdult))
    }

    /// Decision 6: a folder a child's device can't vouch for is refused with one line, its inventory copy too
    func testAChildsDeviceRefusesAFolderItsMacDidntSign() throws {
        let inventory = inventory()
        let present = present([entry()]).merging([PhoneInventory.fileName: 40]) { a, _ in a }
        let none = FolderOffer.HeldInventory(paired: true, writtenAt: nil)
        func make(_ read: BackupSignature.Read, key: String? = macKey) -> FolderOffer.Offer {
            var sends = record(holding: [], key: key)
            sends.manifest?.files = [entry()]  // the Mac sends this device the daily file
            return FolderOffer.make(read, present: present, record: sends, child: true, inventory: none)
        }
        var bad = String(decoding: try BackupSignature.sign(Manifest(writtenAt: "x", files: [entry()],
                                                                     inventory: inventory), with: mac), as: UTF8.self)
        bad = bad.replacingOccurrences(of: "\"size\" : 100", with: "\"size\" : 101")
        let refused = [make(try list([entry()], inventory: inventory)),
                       make(try list([entry()], inventory: inventory, signedBy: P256.Signing.PrivateKey())),
                       make(try BackupSignature.read(Data(bad.utf8)))]
        XCTAssertEqual(refused.map(\.trust), [.unsigned, .otherKey, .badSignature])
        for offer in refused {
            XCTAssertEqual(offer.childRefusal, .notFromYourMac)
            XCTAssertEqual(offer.items, [])
            XCTAssertNil(offer.inventory)
        }
        let noKey = make(try list([entry()], inventory: inventory, signedBy: mac), key: nil)
        XCTAssertEqual(noKey.childRefusal, .noKeyYet)
        XCTAssertEqual(noKey.items, [])
        XCTAssertNil(noKey.inventory)
        // its own Mac's signed list: the file and the inventory copy, as an adult's device would get them
        let signed = make(try list([entry()], inventory: inventory, signedBy: mac))
        XCTAssertNil(signed.childRefusal)
        XCTAssertEqual(signed.items.map(\.state), [.missing])
        XCTAssertEqual(signed.inventory?.state, .missing)
        XCTAssertEqual(signed.inventory?.needsAdult, false)
    }

    func testAListThisPhoneCantVouchForNeedsAnAdult() throws {
        let unsigned = FolderOffer.make(try list([entry()]), present: present([entry()]),
                                        record: record(holding: [], key: macKey), child: false)
        XCTAssertEqual(unsigned.trust, .unsigned)
        let other = FolderOffer.make(try list([entry()], signedBy: P256.Signing.PrivateKey()),
                                     present: present([entry()]), record: record(holding: [], key: macKey),
                                     child: false)
        XCTAssertEqual(other.trust, .otherKey)
        let noKey = FolderOffer.make(try list([entry()], signedBy: mac), present: present([entry()]),
                                     record: record(holding: []), child: false)
        XCTAssertEqual(noKey.trust, .phoneKnowsNoKey)
        for offer in [unsigned, other, noKey] {
            XCTAssertTrue(offer.needsAdult)
            XCTAssertTrue(offer.items.allSatisfy(\.needsAdult))
        }
    }

    /// Review of tasks 1 to 3: a signature that doesn't hold is said plainly and needs an adult, never refused outright
    /// (stripping it would get the same prompt, and a real restore must still be possible)
    func testABadSignatureIsSaidAndNeedsAnAdult() throws {
        var text = String(decoding: try BackupSignature.sign(Manifest(writtenAt: "x", files: [entry()]), with: mac),
                          as: UTF8.self)
        text = text.replacingOccurrences(of: "\"size\" : 100", with: "\"size\" : 101")
        let offer = FolderOffer.make(try BackupSignature.read(Data(text.utf8)), present: ["prepareme-daily.zim": 101],
                                     record: record(holding: [], key: macKey), child: false)
        XCTAssertEqual(offer.trust, .badSignature)
        XCTAssertTrue(offer.needsAdult)
        XCTAssertEqual(offer.items.map(\.needsAdult), [true])
    }

    func testTheSameDateWithAnotherCopyOrNoDateIsDifferentAndNeedsAnAdult() throws {
        let held = [entry()]
        for folder in [entry(sha: "b"), entry(sha: "b", at: "not a date")] {
            let offer = FolderOffer.make(try list([folder], signedBy: mac), present: present([folder]),
                                         record: record(holding: held, key: macKey), child: false)
            XCTAssertEqual(offer.items.map(\.state), [.different])
            XCTAssertTrue(offer.items[0].needsAdult)
        }
    }

    func testAFileThisPhonesMacNoLongerSendsNeedsAnAdult() throws {
        let kept = entry("wikipedia.zim", id: Self.ids[1], kind: "download", family: true)  // since kept for the Mac
        var record = record(holding: [entry()], key: macKey)  // the Mac's list names the daily file only
        let offer = FolderOffer.make(try list([entry(), kept], signedBy: mac), present: present([entry(), kept]),
                                     record: record, child: false)
        XCTAssertEqual(offer.items.map(\.state), [.same, .missing])
        XCTAssertEqual(offer.items.map(\.needsAdult), [false, true])
        record.manifest = nil  // a phone with no Mac list at all (set up after the Mac was lost): by the signature alone
        record.backupKey = macKey
        let fresh = FolderOffer.make(try list([kept], signedBy: mac), present: present([kept]), record: record,
                                     child: false)
        XCTAssertEqual(fresh.items.map(\.needsAdult), [false])
    }

    /// Family downloads plan, phase 3: a name in the device's last `drop` (the Mac's Never for it, or un-ticked For the
    /// family) is never offered from a folder, on an adult's device too
    func testANameTheMacDropsIsNeverOfferedToAnyDevice() throws {
        let kept = entry("wikipedia.zim", id: Self.ids[1], kind: "download", family: true)
        var record = record(holding: [entry()], key: macKey)
        record.manifest?.drop = ["wikipedia.zim"]
        for child in [false, true] {
            let offer = FolderOffer.make(try list([entry(), kept], signedBy: mac), present: present([entry(), kept]),
                                         record: record, child: child)
            XCTAssertEqual(offer.items.map(\.entry.name), ["prepareme-daily.zim"], child ? "a child's" : "an adult's")
        }
    }

    func testTheKeyThePhoneLearnedIsKeptWhenALaterListHasNone() throws {
        var record = record(holding: [])
        record.backupKey = macKey
        let offer = FolderOffer.make(try list([entry()], signedBy: mac), present: present([entry()]),
                                     record: record, child: false)
        XCTAssertEqual(offer.trust, .signedByThisMac)
    }

    func testAnIDHeldUnderAnotherNameIsNotOffered() throws {
        let held = entry("prepareme-daily.zim")
        let renamed = entry("renamed.zim")  // the same library ID under another name: two copies would confuse Kiwix
        let offer = FolderOffer.make(try list([renamed], signedBy: mac), present: present([renamed]),
                                     record: record(holding: [held], key: macKey), child: false)
        XCTAssertEqual(offer.items, [])
    }

    func testRoomIsTheSizePlusAGigabyteAndTwiceForAFileStillInICloud() throws {
        let folder = [entry(size: 100), entry("roads.zim", id: Self.ids[1], kind: "map-core", size: 1000)]
        let offer = FolderOffer.make(try list(folder, signedBy: mac), present: present(folder),
                                     record: record(holding: [], key: macKey), child: false)
        XCTAssertEqual(FolderOffer.need(offer.items, notLocal: []), 1100 + LibraryPlan.spareBytes)
        XCTAssertEqual(FolderOffer.need(offer.items, notLocal: ["roads.zim"]), 2100 + LibraryPlan.spareBytes)
    }

    /// Cloud review: a file removed on purpose is offered one by one, never in Add all
    func testAFileRemovedOnPurposeIsNeverInAddAll() throws {
        let map = entry("topo.zim", id: Self.ids[1], kind: "map-optional")
        var record = record(holding: [], key: macKey)
        record.manifest = Manifest(writtenAt: "x", files: [entry(), map], backupKey: macKey)
        record.declined = ["topo.zim"]
        let offer = FolderOffer.make(try list([entry(), map], signedBy: mac), present: present([entry(), map]),
                                     record: record, child: false)
        XCTAssertEqual(offer.items.map(\.declined), [false, true])
        XCTAssertEqual(FolderOffer.takeAll(offer).map(\.entry.name), ["prepareme-daily.zim"])
    }

    /// Cloud review: a file of another size than listed (a drive copied part-way) is never offered; an iCloud
    /// placeholder, whose size isn't known on the phone, is
    func testAFileOfTheWrongSizeIsAbsentAndAPlaceholderIsOffered() throws {
        let folder = [entry(size: 100), entry("roads.zim", id: Self.ids[1], kind: "map-core", size: 1000)]
        let offer = FolderOffer.make(try list(folder, signedBy: mac),
                                     present: ["prepareme-daily.zim": 40, "roads.zim": FolderOffer.inICloud],
                                     record: record(holding: [], key: macKey), child: false)
        XCTAssertEqual(offer.absent, ["prepareme-daily.zim"])
        XCTAssertEqual(offer.items.map(\.entry.name), ["roads.zim"])
    }

    func testICloudPlaceholdersCountAsPresent() {
        XCTAssertEqual(FolderOffer.placeholderName(".roads.zim.icloud"), "roads.zim")
        XCTAssertNil(FolderOffer.placeholderName(".../x.icloud"))
        XCTAssertNil(FolderOffer.placeholderName("roads.zim"))
        XCTAssertEqual(FolderOffer.present(names: [".roads.zim.icloud", "daily.zim", ".DS_Store"],
                                           sizes: ["daily.zim": 5]),
                       ["roads.zim": FolderOffer.inICloud, "daily.zim": 5])
    }

    // MARK: The phones' inventory copy (beta run 2, B2-04, choice a)

    func inventory(at: String = "2026-10-20T16:00:00Z", size: Int64 = 40, sha: Character = "e") -> Manifest.Inventory {
        Manifest.Inventory(name: PhoneInventory.fileName, size: size, sha256: String(repeating: sha, count: 64),
                           writtenAt: at)
    }

    func list(_ entries: [Manifest.Entry], inventory: Manifest.Inventory?,
              signedBy key: P256.Signing.PrivateKey? = nil) throws -> BackupSignature.Read {
        let manifest = Manifest(writtenAt: "2026-10-20T13:00:00-04:00", files: entries, inventory: inventory)
        return try BackupSignature.read(key.map { try BackupSignature.sign(manifest, with: $0) } ?? manifest.encoded())
    }

    func offer(held: FolderOffer.HeldInventory, child: Bool = false, present extra: [String: Int64]? = nil,
               key: String? = nil) throws -> FolderOffer.Offer {
        let folder = [entry()]
        let present = extra ?? present(folder).merging([PhoneInventory.fileName: 40]) { a, _ in a }
        return FolderOffer.make(try list(folder, inventory: inventory(), signedBy: mac), present: present,
                                record: record(holding: [], key: key), child: child, inventory: held)
    }

    /// One Add's count and size, the button's and the progress's: the inventory copy counts as one more file
    func testABatchCountsTheInventoryCopyAsOneMore() throws {
        let offer = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: nil))
        let held = try XCTUnwrap(offer.inventory)
        XCTAssertEqual(FolderOffer.Batch(items: offer.items).count, 1)
        XCTAssertEqual(FolderOffer.Batch(items: offer.items).size, 100)
        XCTAssertEqual(FolderOffer.Batch(items: offer.items, inventory: held).count, 2)
        XCTAssertEqual(FolderOffer.Batch(items: offer.items, inventory: held).size, 140)
        XCTAssertEqual(FolderOffer.Batch(items: [], inventory: held).count, 1)
        XCTAssertEqual(FolderOffer.Batch(items: []).count, 0)
    }

    /// A new or reset device, never paired, the Mac lost: it takes the backup's copy, after the adult's OK every
    /// unvouched list needs
    func testADeviceNeverPairedIsOfferedTheInventory() throws {
        let offer = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: nil))
        let item = try XCTUnwrap(offer.inventory)
        XCTAssertEqual(item.state, .missing)
        XCTAssertEqual(item.entry, inventory())
        XCTAssertTrue(item.needsAdult)  // the phone learned no key
        XCTAssertFalse(offer.inventoryKept)
    }

    /// A paired device keeps its own copy: the Mac's is newer than any backup, and the Mac's copy wins
    func testAPairedDeviceKeepsItsOwnCopy() throws {
        let offer = try offer(held: FolderOffer.HeldInventory(paired: true, writtenAt: "2026-10-01T09:00:00Z"),
                              key: macKey)
        XCTAssertNil(offer.inventory)
        XCTAssertTrue(offer.inventoryKept)
        XCTAssertEqual(offer.items.map(\.state), [.missing])  // the library files as before
        // a paired device that never got a copy has nothing to keep: it may take the backup's
        let none = try self.offer(held: FolderOffer.HeldInventory(paired: true, writtenAt: nil), key: macKey)
        XCTAssertEqual(none.inventory?.state, .missing)
        XCTAssertEqual(none.inventory?.needsAdult, false)  // signed by its own Mac
    }

    /// The whole-plan review: a paired device whose copy came from a backup (a replacement Mac that has no copy for it
    /// yet) is offered a newer backup copy like an unpaired one, and is never told its copy is the Mac's.
    func testAPairedDeviceHoldingABackupsCopyIsOfferedANewerOne() throws {
        XCTAssertEqual(FolderOffer.inventoryState(paired: true, held: "2026-10-19T16:00:00Z",
                                                  backup: "2026-10-20T16:00:00Z", fromBackup: true), .newer)
        XCTAssertNil(FolderOffer.inventoryState(paired: true, held: "2026-10-21T16:00:00Z",
                                                backup: "2026-10-20T16:00:00Z", fromBackup: true),
                     "an older backup never replaces it")
        XCTAssertNil(FolderOffer.inventoryState(paired: true, held: "2026-10-19T16:00:00Z",
                                                backup: "2026-10-20T16:00:00Z", fromBackup: false), "the Mac's copy wins")
        let newer = try offer(held: FolderOffer.HeldInventory(paired: true, writtenAt: "2026-10-19T16:00:00Z",
                                                              fromBackup: true), key: macKey)
        XCTAssertEqual(newer.inventory?.state, .newer)
        XCTAssertEqual(newer.inventory?.needsAdult, false)
        XCTAssertFalse(newer.inventoryKept)
        let older = try offer(held: FolderOffer.HeldInventory(paired: true, writtenAt: "2026-10-21T16:00:00Z",
                                                              fromBackup: true), key: macKey)
        XCTAssertNil(older.inventory)
        XCTAssertFalse(older.inventoryKept, "never 'its own copy from the Mac': it came from a backup")
        XCTAssertEqual(FolderOffer.inventoryHeldLine(device: "iPad", fromBackup: true),
                       "The inventory and meeting places: this iPad already has a copy as new as this one.")
        XCTAssertEqual(FolderOffer.inventoryHeldLine(device: "phone", fromBackup: false),
                       FolderOffer.inventoryKeptLine(device: "phone"))
    }

    func testAnUnpairedDeviceTakesOnlyANewerCopy() throws {
        XCTAssertEqual(FolderOffer.inventoryState(paired: false, held: nil, backup: "2026-10-20T16:00:00Z"), .missing)
        XCTAssertEqual(FolderOffer.inventoryState(paired: false, held: "2026-10-19T16:00:00Z",
                                                  backup: "2026-10-20T16:00:00Z"), .newer)
        XCTAssertNil(FolderOffer.inventoryState(paired: false, held: "2026-10-20T16:00:00Z",
                                                backup: "2026-10-20T16:00:00Z"))
        XCTAssertNil(FolderOffer.inventoryState(paired: false, held: "2026-10-21T16:00:00Z",
                                                backup: "2026-10-20T16:00:00Z"), "a drive filled before never wins")
        XCTAssertNil(FolderOffer.inventoryState(paired: false, held: "2026-10-19T16:00:00Z", backup: "not a date"))
        XCTAssertNil(FolderOffer.inventoryState(paired: true, held: "2026-10-01T16:00:00Z",
                                                backup: "2026-10-20T16:00:00Z"))
        XCTAssertEqual(FolderOffer.inventoryState(paired: true, held: nil, backup: "2026-10-20T16:00:00Z"), .missing)
        let newer = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: "2026-10-19T16:00:00Z"))
        XCTAssertEqual(newer.inventory?.state, .newer)
        XCTAssertEqual(newer.inventory?.heldWrittenAt, "2026-10-19T16:00:00Z")
        let older = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: "2026-10-21T16:00:00Z"))
        XCTAssertNil(older.inventory)
    }

    func testAChildsPhoneWithAnUnvouchedListOrAMissingCopyIsOfferedNoInventory() throws {
        let child = try offer(held: FolderOffer.HeldInventory(paired: true, writtenAt: nil), child: true)
        XCTAssertNil(child.inventory)  // no key learned yet (decision 6)
        XCTAssertEqual(child.childRefusal, .noKeyYet)
        let gone = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: nil),
                             present: present([entry()]))
        XCTAssertNil(gone.inventory)
        XCTAssertEqual(gone.absent, [PhoneInventory.fileName])
        let wrongSize = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: nil),
                                  present: present([entry()]).merging([PhoneInventory.fileName: 39]) { a, _ in a })
        XCTAssertNil(wrongSize.inventory)
        let inICloud = try offer(held: FolderOffer.HeldInventory(paired: false, writtenAt: nil),
                                 present: present([entry()]).merging([PhoneInventory.fileName: FolderOffer.inICloud])
                                    { a, _ in a })
        XCTAssertEqual(inICloud.inventory?.state, .missing)
    }

    /// Review focus 4: a phone holding a backup list from before this change reads it as before
    func testAListFromBeforeTheInventoryOffersTheLibraryAsBefore() throws {
        let offer = FolderOffer.make(try list([entry()], signedBy: mac), present: present([entry()]),
                                     record: record(holding: [], key: macKey), child: false,
                                     inventory: FolderOffer.HeldInventory(paired: false, writtenAt: nil))
        XCTAssertNil(offer.inventory)
        XCTAssertFalse(offer.inventoryKept)
        XCTAssertEqual(offer.items.map(\.state), [.missing])
        XCTAssertEqual(offer.absent, [])
    }

    /// The copy's three checks on the phone: its listed size, its SHA-256, and that it reads whole as the phones' copy
    /// the list names (its time); a copy failing any is refused
    func testTheCopyIsCheckedThreeWaysBeforeItIsTaken() throws {
        let copy = PhoneInventory(writtenAt: "2026-10-20T16:00:00Z", columns: [], items: [], places: [],
                                  categories: [], headsUpDays: 30, toBuy: [], results: [:],
                                  marks: [MapMark(id: 1, kind: .rally, name: "Corner of the park",
                                                  points: [[-77.03, 38.89]])])
        let data = try JSONEncoder().encode(copy)
        let good = Manifest.Inventory(name: PhoneInventory.fileName, size: Int64(data.count),
                                      sha256: Hex.string(SHA256.hash(data: data)), writtenAt: copy.writtenAt)
        XCTAssertEqual(FolderOffer.readInventory(data, entry: good), copy)
        XCTAssertEqual(FolderOffer.readInventory(data, entry: good)?.marks?.first?.name, "Corner of the park")
        var size = good
        size.size += 1
        XCTAssertNil(FolderOffer.readInventory(data, entry: size))
        var hash = good
        hash.sha256 = String(repeating: "0", count: 64)
        XCTAssertNil(FolderOffer.readInventory(data, entry: hash))
        let notACopy = Data("{\"hello\": 1}".utf8)
        XCTAssertNil(FolderOffer.readInventory(notACopy, entry: Manifest.Inventory(
            name: PhoneInventory.fileName, size: Int64(notACopy.count), sha256: Hex.string(SHA256.hash(data: notACopy)),
            writtenAt: copy.writtenAt)))
        var time = good
        time.writtenAt = "2026-10-21T16:00:00Z"
        XCTAssertNil(FolderOffer.readInventory(data, entry: time))
    }

    func testTheInventorysWords() {
        XCTAssertEqual(FolderOffer.inventoryTitle, "Inventory and meeting places")
        XCTAssertEqual(FolderOffer.inventoryNote(device: "iPad"),
                       "Read only on this iPad until it is paired with the Mac.")
        XCTAssertEqual(FolderOffer.inventoryNote(device: "iPad", paired: true),
                       "Read only on this iPad until it reaches the Mac at home.")
        XCTAssertEqual(FolderOffer.inventoryKeptLine(device: "phone"),
                       "The inventory and meeting places: this phone keeps its own copy from the Mac.")
    }

    func testTheWords() throws {
        XCTAssertEqual(FolderOffer.trustLine(.unsigned),
                       "This folder's list isn't signed by your Mac. Add from it only if it came from your own backup.")
        XCTAssertEqual(FolderOffer.trustLine(.otherKey),
                       "This folder's list was signed by a Mac this phone doesn't know. Add from it only if it came "
                       + "from your own backup.")
        XCTAssertEqual(FolderOffer.trustLine(.phoneKnowsNoKey),
                       "This phone hasn't learned your Mac's signature yet (it does at home). Add from this folder "
                       + "only if it came from your own backup.")
        XCTAssertEqual(FolderOffer.trustLine(.badSignature),
                       "This folder's list was changed after your Mac signed it. Add from it only if you know why, and "
                       + "only from your own backup.")
        XCTAssertNil(FolderOffer.trustLine(.signedByThisMac))
        XCTAssertEqual(FolderOffer.noList,
                       "This folder has no PrepareMe list (manifest.json). Pick the PrepareMe Backup folder itself.")
        XCTAssertEqual(FolderOffer.damagedList, "This folder's list can't be read, so nothing is added from it.")
        // a child's device (family downloads plan, phase 2, decision 6); an iPad says "iPad" (ThisDevice, 2026-10-18)
        XCTAssertEqual(FolderOffer.childLine(.notFromYourMac),
                       "This folder isn't from your Mac, so nothing is added from it.")
        XCTAssertEqual(FolderOffer.childLine(.noKeyYet, device: "iPad"),
                       "This iPad hasn't learned your Mac's signature yet. It does at home.")
        XCTAssertEqual(FolderOffer.childNewerHere(), "This phone's copy is newer.")
        XCTAssertEqual(FolderOffer.trustLine(.phoneKnowsNoKey, device: "iPad"),
                       "This iPad hasn't learned your Mac's signature yet (it does at home). Add from this folder "
                       + "only if it came from your own backup.")
    }

    func testAFileIsListedByWhenItsLibraryWasMadeNotWhenTheCopyWas() throws {  // beta run 2, B2-20
        let zone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T19:00:00-04:00")!
        func made(_ asOf: String?, at: String = "2026-10-20T18:44:00-04:00", sha: Character = "b") -> Manifest.Entry {
            Manifest.Entry(name: "prepareme-guides.zim", id: Self.ids[0], kind: "library", size: 100,
                           sha256: String(repeating: sha, count: 64), deliveredAt: at, libraryAsOf: asOf)
        }
        func line(_ folder: Manifest.Entry, holding held: [Manifest.Entry]) throws -> String {
            let offer = FolderOffer.make(try list([folder], signedBy: mac), present: present([folder]),
                                         record: record(holding: held, key: macKey), child: false)
            return FolderOffer.fromLine(offer.items[0], device: "phone", now: now, timeZone: zone)
        }
        let folder = made("2026-10-12T08:41-04:00")
        XCTAssertEqual(try line(folder, holding: []), "Made Oct 12.")
        let held = made("2026-10-06T08:41-04:00", at: "2026-10-18T12:00:00-04:00", sha: "a")
        XCTAssertEqual(try line(folder, holding: [held]), "Made Oct 12; this phone's was made Oct 6.")
        // a list from before the library date existed falls back to the copy's date, as Home Mac does
        XCTAssertEqual(try line(made(nil), holding: []), "Made Oct 20.")
    }

    func testNewerAndOlderFollowTheLibraryDateAndTheStreetMapReadsNaturally() throws {  // R2.2 fix round 1
        let zone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T19:00:00-04:00")!
        func made(_ asOf: String?, at: String, sha: Character, name: String = "prepareme-guides.zim",
                  kind: String = "library") -> Manifest.Entry {
            Manifest.Entry(name: name, id: Self.ids[0], kind: kind, size: 100,
                           sha256: String(repeating: sha, count: 64), deliveredAt: at, libraryAsOf: asOf)
        }
        func offered(_ folder: Manifest.Entry, _ held: Manifest.Entry) throws -> FolderOffer.Item {
            FolderOffer.make(try list([folder], signedBy: mac), present: present([folder]),
                             record: record(holding: [held], key: macKey), child: false).items[0]
        }
        func line(_ item: FolderOffer.Item) -> String {
            FolderOffer.fromLine(item, device: "phone", now: now, timeZone: zone)
        }
        // the same library day: by the instant, not the day (checkpoint 1). The backup's library made that morning,
        // the phone's that evening: the phone's is newer, though the backup's copy was written later
        let sameDayEarlier = try offered(made("2026-10-12T08:41-04:00", at: "2026-10-20T18:00:00-04:00", sha: "b"),
                                         made("2026-10-12T20:00-04:00", at: "2026-10-18T12:00:00-04:00", sha: "a"))
        XCTAssertEqual(sameDayEarlier.state, .older)
        XCTAssertTrue(sameDayEarlier.needsAdult)
        XCTAssertEqual(line(sameDayEarlier), "Made Oct 12; this phone's is newer.")
        XCTAssertEqual(FolderOffer.olderLine(sameDayEarlier, title: "Guides", device: "phone", now: now,
                                             timeZone: zone),
                       "This copy of Guides is older than the one on this phone: both made Oct 12. "
                       + "Add it only if the phone's copy is wrong.")
        let sameDayLater = try offered(made("2026-10-12T20:00-04:00", at: "2026-10-20T18:00:00-04:00", sha: "b"),
                                       made("2026-10-12T08:41-04:00", at: "2026-10-18T12:00:00-04:00", sha: "a"))
        XCTAssertEqual(sameDayLater.state, .newer)
        XCTAssertFalse(sameDayLater.needsAdult)
        XCTAssertEqual(line(sameDayLater), "Made Oct 12, later than this phone's.")
        // the day is the one in the passed time zone: 23:30 in New York is the next day in UTC
        let lateEvening = try offered(made("2026-10-12T23:30-04:00", at: "2026-10-20T18:00:00-04:00", sha: "b"),
                                      made("2026-10-12T08:41-04:00", at: "2026-10-18T12:00:00-04:00", sha: "a"))
        XCTAssertEqual(line(lateEvening), "Made Oct 12, later than this phone's.")
        XCTAssertEqual(FolderOffer.fromLine(lateEvening, device: "phone", now: now, timeZone: TimeZone(identifier: "UTC")!),
                       "Made Oct 13; this phone's was made Oct 12.")
        // the backup's copy was written later but its library is older: it is older
        let inverted = try offered(made("2026-10-06T08:41-04:00", at: "2026-10-20T18:00:00-04:00", sha: "b"),
                                   made("2026-10-12T08:41-04:00", at: "2026-10-18T12:00:00-04:00", sha: "a"))
        XCTAssertEqual(inverted.state, .older)
        XCTAssertEqual(line(inverted), "Made Oct 6; this phone's is newer, made Oct 12.")
        XCTAssertTrue(inverted.needsAdult)
        XCTAssertEqual(FolderOffer.olderLine(inverted, title: "Guides", device: "phone", now: now, timeZone: zone),
                       "This copy of Guides is older than the one on this phone: made Oct 6 against Oct 12. "
                       + "Add it only if the phone's copy is wrong.")
        // the street map
        let street = try offered(made("2026-10-12", at: "2026-10-20T18:00:00-04:00", sha: "b", name: StreetMap.fileName, kind: "map"),
                                 made("2026-10-06", at: "2026-10-18T12:00:00-04:00", sha: "a", name: StreetMap.fileName, kind: "map"))
        XCTAssertEqual(street.state, .newer)
        XCTAssertEqual(line(street), "OpenStreetMap as of Oct 12; this phone's is as of Oct 6.")
        let streetOld = try offered(made("2026-10-06", at: "2026-10-20T18:00:00-04:00", sha: "b", name: StreetMap.fileName, kind: "map"),
                                    made("2026-10-12", at: "2026-10-18T12:00:00-04:00", sha: "a", name: StreetMap.fileName, kind: "map"))
        XCTAssertEqual(line(streetOld), "OpenStreetMap as of Oct 6; this phone's is newer, as of Oct 12.")
        XCTAssertEqual(FolderOffer.olderLine(streetOld, title: "Street map", device: "phone", now: now, timeZone: zone),
                       "This copy of Street map is older than the one on this phone: OpenStreetMap as of Oct 6 "
                       + "against Oct 12. Add it only if the phone's copy is wrong.")
        // one side without a library date: compared by the copies' dates as before
        let mixed = try offered(made(nil, at: "2026-10-20T18:00:00-04:00", sha: "b"),
                                made("2026-10-12T08:41-04:00", at: "2026-10-18T12:00:00-04:00", sha: "a"))
        XCTAssertEqual(mixed.state, .newer)
    }

    /// The hourly front-only builds keep the recorded library date (packer/__main__.py), so a daily file delivered
    /// later usually carries the same libraryAsOf: equal library dates fall back to the delivered dates (checkpoint 1)
    func testEqualLibraryDatesFallBackToTheDeliveredDates() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T19:00:00-04:00")!
        func made(_ asOf: String, at: String, sha: Character, name: String = "prepareme-daily.zim",
                  kind: String = "library") -> Manifest.Entry {
            Manifest.Entry(name: name, id: Self.ids[0], kind: kind, size: 100,
                           sha256: String(repeating: sha, count: 64), deliveredAt: at, libraryAsOf: asOf)
        }
        func offer(_ folder: Manifest.Entry, _ held: Manifest.Entry) throws -> FolderOffer.Offer {
            FolderOffer.make(try list([folder], signedBy: mac), present: present([folder]),
                             record: record(holding: [held], key: macKey), child: false)
        }
        func line(_ item: FolderOffer.Item) -> String {
            FolderOffer.fromLine(item, device: "phone", now: now, timeZone: zone)
        }
        let asOf = "2026-10-10T08:41-04:00"
        // the Mac lost: the backup holds the daily delivered Oct 18, the phone the one delivered Oct 12
        let newer = try offer(made(asOf, at: "2026-10-18T07:15:00-04:00", sha: "b"),
                              made(asOf, at: "2026-10-12T07:15:00-04:00", sha: "a"))
        XCTAssertEqual(newer.items[0].state, .newer)
        XCTAssertFalse(newer.items[0].needsAdult)
        XCTAssertEqual(FolderOffer.takeAll(newer).map(\.entry.name), ["prepareme-daily.zim"])  // Add all takes it
        XCTAssertEqual(line(newer.items[0]), "Made Oct 10, later than this phone's.")
        // a drive filled weeks ago, against a later copy on the phone: older, with its warning
        let older = try offer(made(asOf, at: "2026-10-12T07:15:00-04:00", sha: "b"),
                              made(asOf, at: "2026-10-18T07:15:00-04:00", sha: "a"))
        XCTAssertEqual(older.items[0].state, .older)
        XCTAssertTrue(older.items[0].needsAdult)
        XCTAssertEqual(FolderOffer.takeAll(older), [])
        XCTAssertEqual(line(older.items[0]), "Made Oct 10; this phone's is newer.")
        XCTAssertEqual(FolderOffer.olderLine(older.items[0], title: "Today", device: "phone", now: now, timeZone: zone),
                       "This copy of Today is older than the one on this phone: both made Oct 10. "
                       + "Add it only if the phone's copy is wrong.")
        // equal library and delivered dates, other bytes: an adult decides, as before
        let different = try offer(made(asOf, at: "2026-10-12T07:15:00-04:00", sha: "b"),
                                  made(asOf, at: "2026-10-12T07:15:00-04:00", sha: "a"))
        XCTAssertEqual(different.items[0].state, .different)
        XCTAssertTrue(different.items[0].needsAdult)
        XCTAssertEqual(line(different.items[0]), "Made Oct 10, the same day as this phone's, but not the same copy.")
        // the street map, same OpenStreetMap date, a later copy
        let street = try offer(made("2026-10-06", at: "2026-10-18T07:15:00-04:00", sha: "b", name: StreetMap.fileName,
                                    kind: "map"),
                               made("2026-10-06", at: "2026-10-12T07:15:00-04:00", sha: "a", name: StreetMap.fileName,
                                    kind: "map"))
        XCTAssertEqual(street.items[0].state, .newer)
        XCTAssertEqual(line(street.items[0]), "OpenStreetMap as of Oct 6, later than this phone's.")
        let streetOld = try offer(made("2026-10-06", at: "2026-10-12T07:15:00-04:00", sha: "b", name: StreetMap.fileName,
                                       kind: "map"),
                                  made("2026-10-06", at: "2026-10-18T07:15:00-04:00", sha: "a", name: StreetMap.fileName,
                                       kind: "map"))
        XCTAssertEqual(FolderOffer.olderLine(streetOld.items[0], title: "Street map", device: "phone", now: now,
                                             timeZone: zone),
                       "This copy of Street map is older than the one on this phone: both OpenStreetMap as of Oct 6. "
                       + "Add it only if the phone's copy is wrong.")
    }
}
