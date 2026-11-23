import Foundation
import PrepareMeShared
import Testing

/// Audit D4: the reader's database that won't open is moved aside whole (its journal files with it), never one that
/// is only unreadable for now, and never over an earlier one set aside.
struct DatabaseAsideTests {
    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("database-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aDamagedStoreIsMovedAsideWithItsJournal() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("DataModel.sqlite")
        for suffix in ["", "-wal", "-shm"] { try Data("damaged\(suffix)".utf8).write(to: URL(fileURLWithPath: store.path + suffix)) }
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        #expect(DatabaseAside.readable(store))
        #expect(DatabaseAside.move(store, now: when))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 3 && names.allSatisfy { $0.hasPrefix("DataModel-unreadable-") })
        #expect(names.contains { $0.hasSuffix(".sqlite-wal") } && names.contains { $0.hasSuffix(".sqlite-shm") })
        #expect(!FileManager.default.fileExists(atPath: store.path))
        // a second one the same second keeps the first
        try Data("again".utf8).write(to: store)
        #expect(DatabaseAside.move(store, now: when))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 4)
        #expect(DatabaseAside.move(store), "nothing there: already out of the way")
    }

    @Test func aStoreThatCantBeReadNowIsNeverMoved() throws {
        let folder = try Self.scratch()
        let store = folder.appendingPathComponent("DataModel.sqlite")
        try Data("kept".utf8).write(to: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(!DatabaseAside.readable(store))
        #expect(DatabaseAside.readable(folder.appendingPathComponent("none.sqlite")), "none there: a fresh one is made")
    }
}
