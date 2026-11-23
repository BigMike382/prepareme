import Foundation

/// The Family Emergency Card in Printable References (docs/plans/2026-10-21-printable-references-screen.md): the answers
/// of `paper/cardtext.py`, which the Mac app runs from the copy of the card's code it carries, so its boxes, limits,
/// refusals and page are the print command's own (no Swift copy of the card's rules). Only the characters-left count is
/// worked out here, as the card counts (`count`), so it moves as you type; Fixtures/paper/card-cases.json holds it to
/// the card's own count.
public enum PaperCard {
    /// One box: a line of the card, or one item of a list line (`entry` 1, 2, 3).
    public struct Field: Codable, Equatable, Identifiable, Sendable {
        public let id: String  // "rally.r1", "school.pickup.2"
        public let section: String
        public let sectionName: String
        public let name: String
        public let entry: Int?
        public let limit: Int
        public let hint: String  // the starter's comment for the line, "" for none
        public let value: String

        enum CodingKeys: String, CodingKey {
            case id, section, sectionName = "section_name", name, entry, limit, hint, value
        }
    }

    public struct Number: Codable, Equatable, Sendable {
        public var label: String
        public var phone: String

        public init(label: String, phone: String) {
            self.label = label
            self.phone = phone
        }
    }

    /// A problem, by the box it belongs to (nil: the file as a whole); its words are the print command's own and never
    /// hold the box's text.
    public struct Problem: Codable, Equatable, Sendable {
        public let field: String?
        public let message: String
    }

    /// `read`'s answer: every box with its value, every phone number row, and the problems.
    public struct Form: Codable, Equatable, Sendable {
        public let readable: Bool  // false: the file isn't TOML (or UTF-8); the boxes open blank
        public let inForm: Bool  // the file is what PrepareMe writes for it: saving loses nothing typed in TextEdit
        public let fields: [Field]
        public let numbers: [Number]  // every [[number]] block, empty ones too, at least maxNumbers
        public let numberLimits: [String: Int]
        public let numberHints: [String: String]
        public let maxNumbers: Int
        public let problems: [Problem]

        enum CodingKeys: String, CodingKey {
            case readable, inForm = "in_form", fields, numbers, numberLimits = "number_limits",
                 numberHints = "number_hints", maxNumbers = "max_numbers", problems
        }
    }

    /// `check`'s input: the boxes as typed, the phone rows in order, the dates the page shows, and the box being typed in.
    public struct CheckInput: Codable, Equatable, Sendable {
        public let fields: [String: String]
        public let numbers: [Number]
        public let printed: String  // YYYY-MM-DD
        public let changed: String?
        public let focus: String?

        public init(fields: [String: String], numbers: [Number], printed: String, changed: String?, focus: String?) {
            self.fields = fields
            self.numbers = numbers
            self.printed = printed
            self.changed = changed
            self.focus = focus
        }
    }

    /// `check`'s answer: the problems, the card file to save (nil when there is any problem: nothing is saved), the
    /// live picture's page and how many places the focused box prints.
    public struct Checked: Codable, Equatable, Sendable {
        public let problems: [Problem]
        public let toml: String?
        public let page: String?  // left out of the shared cases
        public let printsIn: Int

        enum CodingKeys: String, CodingKey {
            case problems, toml, page, printsIn = "prints_in"
        }
    }

    /// The characters a value counts as on the card: its spaces collapsed (Python's `" ".join(text.split())`), then
    /// counted as Python counts (code points, so an emoji family is several).
    public static func count(_ text: String) -> Int {
        var count = 0, words = 0, inWord = false
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                inWord = false
            } else {
                if !inWord { words += 1 }
                inWord = true
                count += 1
            }
        }
        return count + max(0, words - 1)
    }

    /// Python's whitespace: Unicode's, and the four separators (U+001C to U+001F) str.split() splits at too.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// The words under a box's count: "12 left", "6 over".
    public static func left(_ text: String, limit: Int) -> (words: String, over: Bool, near: Bool) {
        let left = limit - count(text)
        return left < 0 ? ("\(-left) over", true, false) : ("\(left) left", false, left <= 4)
    }
}

#if os(macOS)
/// The card's own code as the Mac app runs it: the venv's Python on the copy inside the app (kiwix-mac/build.sh copies
/// paper/card.py, paper/cardtext.py, the starter and paper/print_style.py beside the inventory check's code), with
/// nothing else on its path. The card's text goes in on stdin and comes back on stdout only; standard error is thrown
/// away, as the inventory check's is.
public struct PaperCardText: Sendable {
    public let python: URL
    public let code: URL

    public init(python: URL, code: URL) {
        self.python = python
        self.code = code
    }

    static let script = "import sys; sys.path.insert(0, sys.argv[1]); from paper import cardtext; "
        + "sys.exit(cardtext.main(sys.argv[2:]))"

    /// The form for card.toml's bytes (empty: no card file yet). Throws CheckUnavailable when there's no answer.
    public func read(_ card: Data) async throws -> PaperCard.Form {
        let (status, output) = try await PythonTextCheck.run(python, ["-I", "-B", "-c", Self.script, code.path, "read"],
                                                            card)
        guard status == 0, let form = try? JSONDecoder().decode(PaperCard.Form.self, from: output) else {
            throw CheckUnavailable(why: status == 0 ? "its answer couldn't be read" : "it ended with \(status)")
        }
        return form
    }

    /// The boxes checked: problems, the file to save and the live picture. Throws CheckUnavailable when there's no
    /// answer, so nothing is saved.
    public func check(_ input: PaperCard.CheckInput) async throws -> PaperCard.Checked {
        let (status, output) = try await PythonTextCheck.run(python, ["-I", "-B", "-c", Self.script, code.path, "check"],
                                                            try JSONEncoder().encode(input))
        guard status == 0 || status == 1 else { throw CheckUnavailable(why: "it ended with \(status)") }
        guard let checked = try? JSONDecoder().decode(PaperCard.Checked.self, from: output) else {
            throw CheckUnavailable(why: "its answer couldn't be read")
        }
        guard (status == 0) == (checked.problems.isEmpty && checked.toml != nil) else {
            throw CheckUnavailable(why: "its answer disagreed")
        }
        return checked
    }
}
#endif

/// The print job's status file, Application Support › PrepareMe › requests › paper-status.json (paper/requests.py):
/// what each Print button's request did, the one running, and the Essential Guides Binder's status. Its lines are
/// the print commands' own: file names, counts and line or guide names, never the card's text.
public struct PaperStatus: Codable, Equatable, Sendable {
    public static let fileName = "paper-status.json"
    public static let card = "print-card", binder = "print-binder", binderChanged = "print-binder-changed",
                      binderStatus = "binder-status"  // scheduler.jobs.PAPER_REQUESTS

    public struct Result: Codable, Equatable, Sendable {
        public let request: String
        public let started: String
        public let finished: String
        public let exit: Int  // 0 done, 1 refused, 3 skipped for the code, 4 an old press not run
        public let lines: [String]
        public let pdf: String?  // its name in Household Private › Print
        public let pressed: Int64?  // the request file's time (nanoseconds) this answers: never an older press's answer

        /// When it finished, nil for a time it can't read.
        public var finishedAt: Date? { PaperStatus.time(finished) }
    }

    public struct Running: Codable, Equatable, Sendable {
        public let request: String
        public let started: String
    }

    public struct Binder: Codable, Equatable, Sendable {
        public struct Guide: Codable, Equatable, Sendable {
            public let title: String
            public let state: String  // "changed", "new" or ""
            public let sheets: Int  // as last printed, 0 for none yet
        }

        public struct Section: Codable, Equatable, Sendable {
            public let name: String
            public let guides: [Guide]
        }

        public let guides: Int?
        public let printed: String?  // YYYY-MM-DD, nil before the first print
        public let new: [String]?
        public let changed: [String]?
        public let removed: [String]?
        public let sections: [Section]?
        public let problems: [String]

        /// The sheets the last print made, counted from the list.
        public var sheets: Int { (sections ?? []).flatMap(\.guides).map(\.sheets).reduce(0, +) }
    }

    public let results: [String: Result]?
    public let running: Running?
    public let binder: Binder?

    /// The status file in `requests`, or nil when it's missing or can't be read.
    public static func read(in requests: URL) -> PaperStatus? {
        guard let data = try? Data(contentsOf: requests.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(PaperStatus.self, from: data)
    }

    static func time(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}
