import Foundation
import SQLite3

/// A value as SQLite stores it.
public enum SQLValue: Equatable, Hashable, Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// The value as a number, for an integer or a real; nil otherwise.
    public var number: Double? {
        switch self {
        case .int(let found): Double(found)
        case .real(let found): found
        default: nil
        }
    }

    /// The value as a whole number, for an integer or a whole real; nil otherwise.
    public var whole: Int64? {
        switch self {
        case .int(let found): found
        case .real(let found) where found.rounded() == found && abs(found) < 9e15: Int64(found)
        default: nil
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// One connection to one SQLite file (the inventory file, plan phase 7). Not shared across threads: the Mac app uses it
/// on the main actor. Every write is a transaction with SQLite's full sync, so a power cut leaves the file as it was
/// before the write or after it, never between (CLAUDE.md: a file the project reads back is saved whole).
final class SQLite {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: URL, readOnly: Bool, create: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(path.path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError(code: result, message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 10_000)  // the lists job's snapshot holds a read lock for a moment (readiness/grist.py)
        sqlite3_extended_result_codes(db, 1)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String, _ arguments: [SQLValue] = []) throws {
        _ = try query(sql, arguments)
    }

    func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (n, argument) in arguments.enumerated() {
            let place = Int32(n + 1)
            let bound: Int32 = switch argument {
            case .null: sqlite3_bind_null(statement, place)
            case .int(let found): sqlite3_bind_int64(statement, place, found)
            case .real(let found): sqlite3_bind_double(statement, place, found)
            case .text(let found): sqlite3_bind_text(statement, place, found, -1, Self.transient)
            case .blob(let found): found.withUnsafeBytes {
                sqlite3_bind_blob(statement, place, $0.baseAddress, Int32($0.count), Self.transient)
            }
            }
            guard bound == SQLITE_OK else { throw failure() }
        }
        var rows: [[SQLValue]] = []
        while true {
            let stepped = sqlite3_step(statement)
            if stepped == SQLITE_DONE { break }
            guard stepped == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    .blob(sqlite3_column_blob(statement, column).map {
                        Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column)))
                    } ?? Data())
                default: .null
                }
            })
        }
        return rows
    }

    /// A whole copy of the database at `path` (SQLite's backup API: the last committed state, in one step).
    func backup(to path: URL) throws {
        let target = try SQLite(path: path, readOnly: false, create: true)
        guard let backup = sqlite3_backup_init(target.db, "main", db, "main") else { throw target.failure() }
        let stepped = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard stepped == SQLITE_DONE else { throw SQLiteError(code: stepped, message: "backup") }
        try target.execute("PRAGMA journal_mode = DELETE")
    }

    /// `body` in one transaction, taken for writing at once; rolled back when it throws. Inside another transaction it
    /// is a savepoint of that one, so a write and its record (InventoryEditor, a phone's edit) commit together or not
    /// at all.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if sqlite3_get_autocommit(db) == 0 {
            let name = "inner_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            try execute("SAVEPOINT \(name)")
            do {
                let result = try body()
                try execute("RELEASE \(name)")
                return result
            } catch {
                try? execute("ROLLBACK TO \(name)")
                try? execute("RELEASE \(name)")
                throw error
            }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure() -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    /// An identifier quoted for SQL, as readiness/grist.py quotes one.
    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
