import Foundation

/// The ID check every kept cell goes through (plan phase 7): `python -m readiness check-text --rows`'s input and answer
/// (readiness/checktext.py), so the editor and the lists job hold one set of rules (plan section 1: no Swift copy).
public struct CheckCell: Codable, Equatable, Sendable {
    public let label: String
    public let text: String
    public let longNumbersOK: Bool
    public let amountsOK: Bool  // an insurance photo's text only: a receipt's prices pass (owner, 2026-10-14)
    public let codesOK: Bool  // a maker's manual page only: its tone and code tables pass (owner, 2026-10-18)

    public init(label: String, text: String, longNumbersOK: Bool = false, amountsOK: Bool = false,
                codesOK: Bool = false) {
        self.label = label
        self.text = text
        self.longNumbersOK = longNumbersOK
        self.amountsOK = amountsOK
        self.codesOK = codesOK
    }

    enum CodingKeys: String, CodingKey {
        case label, text, longNumbersOK = "long_numbers_ok", amountsOK = "amounts_ok", codesOK = "codes_ok"
    }
}

public struct CheckRow: Codable, Equatable, Sendable {
    public let place: String
    public let cells: [CheckCell]

    public init(place: String, cells: [CheckCell]) {
        self.place = place
        self.cells = cells
    }
}

/// A refused row: the cell (nil for the row read joined) and readiness.text's fixed message, which never holds the text.
public struct CheckRefusal: Codable, Equatable, Sendable {
    public let row: Int
    public let cell: Int?
    public let message: String
}

/// The check couldn't give an answer: nothing is kept (fails closed).
public struct CheckUnavailable: Error, CustomStringConvertible, Sendable {
    public let why: String
    public var description: String { "The ID check couldn't run (\(why)), so nothing was saved." }
}

/// The check's whole answer: the rows' refusals, and the lists job's refusal of the changed copy of the file (nil when
/// it reads, or when no file was given).
public struct CheckAnswer: Codable, Equatable, Sendable {
    public let refused: [CheckRefusal]
    public let file: String?

    public init(refused: [CheckRefusal], file: String? = nil) {
        self.refused = refused
        self.file = file
    }

    /// The first refusal's words, or nil when everything may be kept.
    public var refusal: String? { refused.first?.message ?? file }
}

public protocol TextChecking: Sendable {
    /// The refusals among `rows`, and, given `file` (a changed copy of the inventory file), the lists job's refusal of
    /// it read whole. Throws CheckUnavailable when there is no answer.
    func check(_ rows: [CheckRow], file: URL?) async throws -> CheckAnswer
}

extension Inventory {
    /// A row's cells as the check reads them, in the table's column order: each text, choice or other cell as stored,
    /// each reference as its shown name and each number as the lists job writes one, so a label in one cell and its
    /// value in the next are read together (sheets.check_joined). Model reads long numbers as the lists job reads it, and
    /// so do Price (slice 7: a price, read beside the row so "Emergency cash" and its price are refused) and Serial
    /// number (step 6: a serial is a long number; an ID number's shape is still refused).
    /// Dates and ticks hold no text. `position` names the row ("Inventory row 3") as the lists job would.
    public func checkRow(_ tableName: String, values: [String: SQLValue], position: Int) -> CheckRow {
        let table = self.table(tableName)
        var cells: [CheckCell] = []
        for column in table.columns {
            let value = values[column.colId] ?? .null
            let text: String
            switch column.kind {
            case .date, .bool: continue
            case .reference: text = InventoryValues.shown(value, in: column, names: names(for: column))
            default: text = InventoryValues.plain(value)
            }
            cells.append(CheckCell(label: column.label, text: text,
                                   longNumbersOK: InventoryFile.same(column.label, Label.model)
                                       || (tableName == "Inventory" && (InventoryFile.same(column.label, Insurance.price)
                                           || InventoryFile.same(column.label, Insurance.serial)))))
        }
        return CheckRow(place: "\(table.tableId) row \(position)", cells: cells)
    }
}

#if os(macOS)
final class TimedOut: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

/// The check as the Mac app runs it: the venv's Python on the copy of the check's code the app carries
/// (kiwix-mac/build.sh copies readiness, guard and packer's two files into it), with nothing else on its path.
public struct PythonTextCheck: TextChecking {
    public let python: URL
    public let code: URL

    public init(python: URL, code: URL) {
        self.python = python
        self.code = code
    }

    /// The venv's Python under the real home (never a sandbox's own home: FileCheck.swift's RealHome).
    public static func venvPython(home: URL? = RealHome.url) -> URL? {
        home?.appendingPathComponent(".venvs/prepareme-app/bin/python")
    }

    static let script = "import sys; sys.path.insert(0, sys.argv[1]); from readiness import checktext; "
        + "sys.exit(checktext.main(sys.argv[2:]))"

    static let timeout: TimeInterval = 30  // a check that takes longer is ended and counts as not run

    public func check(_ rows: [CheckRow], file: URL?) async throws -> CheckAnswer {
        guard !rows.isEmpty || file != nil else { return CheckAnswer(refused: []) }
        let input = try JSONEncoder().encode(["rows": rows])
        let arguments = ["-I", "-B", "-c", Self.script, code.path, "--rows"] + (file.map { ["--file", $0.path] } ?? [])
        let (status, output) = try await Self.run(python, arguments, input)
        guard status == 0 || status == 1 else { throw CheckUnavailable(why: "it ended with \(status)") }
        guard let answer = try? JSONDecoder().decode(CheckAnswer.self, from: output) else {
            throw CheckUnavailable(why: "its answer couldn't be read")
        }
        guard (status == 1) == (answer.refusal != nil) else { throw CheckUnavailable(why: "its answer disagreed") }
        return answer
    }

    /// The program's exit status and standard output; its standard error is thrown away (it names no text, but nothing
    /// here shows it). One that runs longer than `timeout` is ended, and throws.
    static func run(_ program: URL, _ arguments: [String], _ input: Data,
                    timeout: TimeInterval = timeout) async throws -> (Int32, Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = program
                process.arguments = arguments
                // TMPDIR: the reader's snapshot goes in the app's own temporary folder, the one place a sandboxed
                // child may write
                process.environment = ["PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8",
                                       "TMPDIR": FileManager.default.temporaryDirectory.path]
                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CheckUnavailable(why: "Python couldn't start"))
                    return
                }
                let writer = stdin.fileHandleForWriting
                DispatchQueue.global().async {
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
                let ended = TimedOut()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        ended.set()
                        process.terminate()
                    }
                }
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if ended.value {
                    continuation.resume(throwing: CheckUnavailable(why: "it took longer than \(Int(timeout)) seconds"))
                } else {
                    continuation.resume(returning: (process.terminationStatus, output))
                }
            }
        }
    }
}
#endif
