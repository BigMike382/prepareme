import CryptoKit
import Foundation

/// A household page, one step per screen (concept-doc plan, phase C): written by the Mac's Household pages into
/// Household Private › Library › daily as one Markdown file in the strict form packer/steps.py reads, and read back the
/// same way. The shared fixture household-page.md pins the bytes both sides agree on. Every value is one line; the
/// writer makes it so (a line break becomes a space), and the reader refuses anything outside the form, so a page
/// edited by hand into another shape is "written by hand" rather than half-read.
public struct HouseholdPage: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var words: String
        public var name = ""
        public var photo = ""  // a file beside the page
        public var video = ""  // a file in the video library (PrepareMe: video)
        public var caution = ""
        // Our Home's lines (docs/plans/2026-11-16-our-home.md, Task 2.2), written after the old four
        public var danger = ""
        public var wanted = ""  // the photo the owner should take: the editor's, never built
        public var guide = ""  // a guide's id
        public var map = false
        public var meet = false
        public var items: [String] = []  // list words, as a guide's "In the house"
        public var calculator = ""  // a calculator's page id, calc-…
        public var call: Call?
        public var yes: Int?
        public var no: Int?
        public var ticks: [String] = []
        public var checked = ""  // checkedHash of the words as checked against the sources
        // the editor's fresh look (docs/plans/2026-11-20-our-home-editor.md, Task 1)
        public var place: Picked?  // an inventory place, or words typed
        public var manual: Picked?  // always an inventory item with a manual
        public init(words: String, name: String = "", photo: String = "", video: String = "", caution: String = "",
                    danger: String = "", wanted: String = "", guide: String = "", map: Bool = false, meet: Bool = false,
                    items: [String] = [], calculator: String = "", call: Call? = nil, yes: Int? = nil, no: Int? = nil,
                    ticks: [String] = [], checked: String = "", place: Picked? = nil, manual: Picked? = nil) {
            self.words = words
            self.name = name
            self.photo = photo
            self.video = video
            self.caution = caution
            self.danger = danger
            self.wanted = wanted
            self.guide = guide
            self.map = map
            self.meet = meet
            self.items = items
            self.calculator = calculator
            self.call = call
            self.yes = yes
            self.no = no
            self.ticks = ticks
            self.checked = checked
            self.place = place
            self.manual = manual
        }
    }

    /// A place, manual or thing: picked from the phones' copy of the inventory (its row's id and the words it had when
    /// picked, written `#<id> <words>`), or typed (the words alone). The words stand alone wherever nothing is filled
    /// in; the id is trusted only while its row still has that name (HomeSlots).
    public struct Picked: Equatable, Sendable, Hashable {
        public var id: Int64?
        public var words: String
        public init(id: Int64? = nil, words: String) {
            self.id = id
            self.words = words
        }

        /// A line as the form writes it; nil only for an empty one. A line starting with # that isn't `#<id> <words>`
        /// is kept as typed words, for the Save check to name.
        public init?(line text: String) {
            let text = HouseholdPage.line(text)
            guard !text.isEmpty else { return nil }
            let ns = text as NSString
            if let m = Self.pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               let id = Int64(ns.substring(with: m.range(at: 1))) {
                self.init(id: id, words: ns.substring(with: m.range(at: 2)))
            } else {
                self.init(words: text)
            }
        }

        /// packer/steps.py's PICKED
        static let pattern = try! NSRegularExpression(pattern: #"^#([1-9][0-9]{0,17}) (\S.*)$"#)
        public var line: String { id.map { "#\($0) \(HouseholdPage.line(words))" } ?? HouseholdPage.line(words) }
        /// A place's own name: its path's last part.
        public var name: String { words.components(separatedBy: " › ").last ?? words }
    }

    /// A step's number to call: 3 to 15 digits, and the words it's shown with.
    public struct Call: Equatable, Sendable {
        public var number: String
        public var label: String
        public init(number: String, label: String) {
            self.number = number
            self.label = label
        }
    }

    public var title: String
    public var when = ""
    public var guides: [String] = []  // guide ids
    public var keywords: [String] = []  // search words
    public var sources = ""
    public var checked = ""  // YYYY-MM-DD, only with sources
    public var walked = ""  // YYYY-MM-DD
    public var danger = ""
    public var need: [String] = []  // list words
    public var next = ""
    public var things: [Picked] = []  // What you need, picked or typed, after need's words
    public var steps: [Step]

    public init(title: String, when: String = "", guides: [String] = [], keywords: [String] = [],
                sources: String = "", checked: String = "", walked: String = "", danger: String = "",
                need: [String] = [], next: String = "", things: [Picked] = [], steps: [Step]) {
        self.title = title
        self.when = when
        self.guides = guides
        self.keywords = keywords
        self.sources = sources
        self.checked = checked
        self.walked = walked
        self.danger = danger
        self.need = need
        self.next = next
        self.things = things
        self.steps = steps
    }

    public static let kind = "steps"
    public static let maxKeywords = 12, maxKeywordCharacters = 60  // packer.config's rules for search words
    /// A step's photo and video names, as packer/steps.py's _PHOTO and _VIDEO (packer/tests/test_steps.py compares
    /// them): a plain file name, never a path.
    public static let photoPattern = "[a-z0-9-]+\\.(jpg|jpeg|png)"
    public static let videoPattern = "[a-z0-9-]+\\.mp4"
    /// packer/steps.py's limits for Our Home's lines (MAX_DANGER and the rest)
    public static let maxDanger = 200, maxNext = 300, maxWanted = 120, maxTick = 80, maxNeed = 8, maxItems = 6
    public static let maxPlace = 80, maxThing = 60, maxThings = 8
    /// A blank, as packer/steps.py's BLANK: [Fill in: QUESTION], filled [Fill in: QUESTION]{ANSWER}.
    static let blank = try! NSRegularExpression(pattern: #"\[Fill in: ([^\[\]{}]+)\](?:\{([^\[\]{}]+)\})?"#)

    public enum Problem: Error, Equatable, Sendable {
        case notThisForm(String)  // why, in fixed words naming the line, never the line's text
    }

    // MARK: Writing

    /// The page's file, as packer/steps.py reads it.
    public var markdown: String {
        var lines = ["---", "title: \(Self.line(title))", "kind: \(Self.kind)"]
        if !Self.line(when).isEmpty { lines.append("when: \(Self.line(when))") }
        if !guides.isEmpty { lines.append("guides: \(guides.joined(separator: ", "))") }
        let words = keywords.map(Self.line).filter { !$0.isEmpty }
        if !words.isEmpty { lines.append("keywords: \(words.joined(separator: "; "))") }
        for (key, value) in [("sources", sources), ("checked", checked), ("walked", walked), ("danger", danger),
                             ("need", Self.list(need)), ("next", next), ("things", Self.list(things.map(\.line)))] where !Self.line(value).isEmpty {
            lines.append("\(key): \(Self.line(value))")
        }
        lines.append("---")
        for step in steps {
            lines.append("- step: \(Self.line(step.words))")
            let call = step.call.map { "\(Self.line($0.number)); \(Self.line($0.label))" } ?? ""
            for (key, value) in [("name", step.name), ("photo", step.photo), ("video", step.video),
                                 ("caution", step.caution), ("danger", step.danger), ("wanted", step.wanted),
                                 ("guide", step.guide), ("map", step.map ? "yes" : ""), ("meet", step.meet ? "yes" : ""),
                                 ("items", Self.list(step.items)), ("calculator", step.calculator), ("call", call),
                                 ("yes", step.yes.map(String.init) ?? ""), ("no", step.no.map(String.init) ?? ""),
                                 ("ticks", Self.list(step.ticks)), ("checked", step.checked),
                                 ("place", step.place?.line ?? ""), ("manual", step.manual?.line ?? "")]
            where !Self.line(value).isEmpty {
                lines.append("  \(key): \(Self.line(value))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A "; "-separated line, each part one line, the empty ones left out.
    static func list(_ parts: [String]) -> String {
        parts.map(line).filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// One line: line breaks, runs of spaces and every character Python's splitlines breaks a line at (the file
    /// separators U+001C to U+001E among them, which Swift doesn't count as space) become one space, the ends trimmed.
    static func line(_ text: String) -> String {
        let breaks: Set<Character> = ["\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"]
        return text.split(whereSeparator: { $0.isWhitespace || breaks.contains($0) }).joined(separator: " ")
    }

    /// Why the packer would refuse or hide this page, in fixed words, or nil: the Mac checks it before Save, so a page
    /// it writes never stops the daily build (the review, 2026-10-19). The packer's own rules (packer/steps.py,
    /// packer.config's for search words), and noindex, which would quietly take the page out of search.
    /// The page as Save writes it, in the forms the packer reads (the owner's test page, 2026-11-18, wouldn't save): a
    /// number to call loses its spaces, dashes, dots, brackets and plus, so "(202) 555-0123" is 2025550123, and list
    /// words are lowercased, since matching folds case anyway, and a blank's answer is made one tidy line (its box keeps
    /// spaces while typing). Anything else stays as typed, for `problem` to name.
    public var tidied: HouseholdPage {
        var page = self
        page.need = need.map { $0.lowercased() }
        for n in page.steps.indices {
            page.steps[n].items = page.steps[n].items.map { $0.lowercased() }
            page.steps[n].call?.number.removeAll { " -.()+\u{A0}".contains($0) }
        }
        for blank in page.blanks { if let answer = blank.answer { page.fill(blank, with: answer, trim: true) } }
        return page
    }

    public var problem: String? {
        if Self.line(title).isEmpty { return "The page needs a title." }
        if steps.isEmpty { return "The page needs at least one step." }
        if let n = steps.firstIndex(where: { Self.line($0.words).isEmpty }) { return "Step \(n + 1) needs its words." }
        let words = keywords.map(Self.line).filter { !$0.isEmpty }
        if words.count > Self.maxKeywords { return "At most \(Self.maxKeywords) search words." }
        if words.contains(where: { $0.count > Self.maxKeywordCharacters }) {
            return "A search word can be at most \(Self.maxKeywordCharacters) characters."
        }
        if words.contains(where: { $0.contains(where: { "<>\"".contains($0) }) }) {
            return "A search word can't hold <, > or a double quote."
        }
        let text = [title, when] + words + things.map(\.words)
            + steps.flatMap { [$0.words, $0.name, $0.caution, $0.place?.words ?? ""] }
        if text.contains(where: { $0.range(of: "noindex", options: .caseInsensitive) != nil }) {
            return "The word noindex would hide the page from search; reword it."
        }
        return formProblem
    }

    /// Our Home's lines, as packer/steps.py refuses them (Task 2.1), in fixed words: the editor's before Save, and the
    /// reader's (a page edited by hand into a shape the packer refuses is "written by hand").
    var formProblem: String? {
        if !Self.line(checked).isEmpty && Self.line(sources).isEmpty { return "Checked needs its sources." }
        if !Self.line(checked).isEmpty && !Self.isDate(Self.line(checked)) { return "Checked isn't a date." }
        if !Self.line(walked).isEmpty && !Self.isDate(Self.line(walked)) { return "Last walked through isn't a date." }
        if Self.line(danger).unicodeScalars.count > Self.maxDanger { return "Danger: at most \(Self.maxDanger) characters." }
        if Self.line(next).unicodeScalars.count > Self.maxNext { return "What comes next: at most \(Self.maxNext) characters." }
        if let bad = Self.wordsProblem(need, most: Self.maxNeed) { return "What you need: \(bad)" }
        if !Self.blanksWhole(when) { return "Use this when: a blank can't hold [, ], { or }." }
        let things = things.filter { !Self.line($0.words).isEmpty }
        if things.count > Self.maxThings { return "What you need: at most \(Self.maxThings) things." }
        for thing in things {
            if thing.id == nil && thing.words.hasPrefix("#") { return "What you need: a thing you type can't start with #." }
            // the limits are for typed words: a picked one is the inventory's name, filled by its id (the review)
            if thing.id == nil && Self.line(thing.words).unicodeScalars.count > Self.maxThing {
                return "What you need: a thing can be at most \(Self.maxThing) characters."
            }
            if thing.words.contains(";") { return "What you need: a thing can't hold ;." }
            if thing.words.contains("[Fill in:") { return "What you need: a blank can't hold [, ], { or }." }
        }
        for (i, step) in steps.enumerated() {
            let n = i + 1, at = "Step \(n):"
            if !Self.blanksWhole(step.words) || !Self.blanksWhole(step.caution) {
                return "\(at) a blank can't hold [, ], { or }."
            }
            if Self.line(step.danger).unicodeScalars.count > Self.maxDanger { return "\(at) danger at most \(Self.maxDanger) characters." }
            if Self.line(step.wanted).unicodeScalars.count > Self.maxWanted {
                return "\(at) photo wanted at most \(Self.maxWanted) characters."
            }
            if !step.guide.isEmpty && !GuideTopics.matches(step.guide, "[a-z0-9-]+") {
                return "\(at) the guide isn't a guide's id."
            }
            if !step.calculator.isEmpty && !GuideTopics.matches(step.calculator, "calc-[a-z0-9-]+") {
                return "\(at) the calculator isn't a calculator's page."
            }
            if let bad = Self.wordsProblem(step.items, most: Self.maxItems) { return "\(at) \(bad)" }
            if let place = step.place {
                if place.id == nil && place.words.hasPrefix("#") { return "\(at) a place you type can't start with #." }
                if place.id == nil && Self.line(place.words).unicodeScalars.count > Self.maxPlace {
                    return "\(at) a place can be at most \(Self.maxPlace) characters."
                }
                if place.words.contains("[Fill in:") { return "\(at) a blank can't hold [, ], { or }." }
            }
            if let manual = step.manual, manual.id == nil || Self.line(manual.words).isEmpty {
                return "\(at) manual isn't a picked item."
            }
            if let call = step.call {
                // the boards' sentences, in lower case after the step's lead (the design session, 2026-11-20)
                if let bad = Self.digitsProblem(Self.line(call.number)) { return "\(at) a" + bad.dropFirst() }
                if Self.line(call.label).isEmpty { return "\(at) a number to call needs its label." }
            }
            if (step.yes == nil) != (step.no == nil) { return "\(at) Yes goes to and No goes to go together." }
            for (key, to) in [("Yes", step.yes), ("No", step.no)] {
                guard let to else { continue }
                if to == 0 { return "\(at) choose the step \(key) goes to." }  // removed, or not chosen yet
                if to == n { return "\(at) \(key) can't go to its own step." }
                if !(1...steps.count).contains(to) { return "\(at) \(key) goes to a step that isn't there." }
            }
            let ticks = step.ticks.map(Self.line).filter { !$0.isEmpty }
            if !ticks.isEmpty && !(2...12).contains(ticks.count) { return "\(at) a checklist needs 2 to 12 ticks." }
            if ticks.contains(where: { $0.unicodeScalars.count > Self.maxTick }) {
                return "\(at) a tick can be at most \(Self.maxTick) characters."
            }
            if !step.checked.isEmpty && !GuideTopics.matches(step.checked, "[0-9a-f]{8}") {
                return "\(at) its checked mark isn't 8 lowercase hex."
            }
        }
        return nil
    }

    /// What's wrong with a number to call as typed, in the boards' words, shown under its box while typing (board 4);
    /// spaces, dashes, dots, brackets and plus are fine, as Save takes them out (`tidied`).
    public static func callProblem(_ typed: String) -> String? {
        var digits = typed
        digits.removeAll { " -.()+\u{A0}".contains($0) }
        return digitsProblem(digits)
    }

    static func digitsProblem(_ digits: String) -> String? {
        if !digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return "A number to call can only hold digits." }
        if digits.count < 3 { return "A number to call needs at least 3 digits." }
        if digits.count > 15 { return "A number to call can't be longer than 15 digits." }
        return nil
    }

    static func isDate(_ text: String) -> Bool {
        guard GuideTopics.matches(text, "[0-9]{4}-[0-9]{2}-[0-9]{2}") else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text).map(formatter.string) == text
    }

    /// Why a list of list words isn't one (guide_links.word_ok, 1 to `most`), or nil; an empty list is none.
    static func wordsProblem(_ words: [String], most: Int) -> String? {
        let words = words.map(line).filter { !$0.isEmpty }
        if words.count > most { return "at most \(most) list words." }
        if let bad = words.first(where: { $0.count < 3 || !GuideTopics.matches($0, "[a-z0-9]+( [a-z0-9]+)*") }) {
            return "\"\(bad)\" isn't a list word (3 or more letters or digits)."
        }
        return nil
    }

    /// Whether every [, ], { and } in `text` belongs to a whole blank (or the text holds none of a blank).
    static func blanksWhole(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        let rest = blank.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        if rest.contains("[Fill in:") { return false }
        return blank.firstMatch(in: text, range: range) == nil || !rest.contains(where: { "[]{}".contains($0) })
    }

    /// Each blank in `text`, in order: its question and its answer, nil while unfilled.
    public static func blanks(_ text: String) -> [(question: String, answer: String?)] {
        blank.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let part = { (i: Int) in Range(match.range(at: i), in: text).map { String(text[$0]) } }
            return (part(1) ?? "", part(2))
        }
    }

    /// The blanks not filled yet, in the page's when and its steps' words and cautions (packer.steps.blanks_left).
    public var blanksLeft: Int {
        ([when] + steps.flatMap { [$0.words, $0.caution] }).reduce(0) { $0 + Self.blanks($1).filter { $0.answer == nil }.count }
    }

    /// A step's words as checked (packer.steps.checked_hash): the first 8 hex of SHA-256 of them with every blank and
    /// its answer removed and runs of whitespace made one space.
    public static func checkedHash(_ words: String) -> String {
        let bare = blank.stringByReplacingMatches(in: words, range: NSRange(words.startIndex..., in: words),
                                                  withTemplate: "")
        let one = bare.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(one.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: Reading

    /// Whether a page's header says `kind: steps` (only then is it read here, as packer.steps.is_steps).
    public static func isSteps(_ text: String) -> Bool {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex,
                                                                                           offsetBy: 4)..<text.endIndex)
        else { return false }
        return text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            .split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "kind: \(kind)" }
    }

    public init(markdown text: String) throws {
        guard text.hasPrefix("---\n"), let close = text.range(of: "\n---\n", range: text.index(text.startIndex,
                                                                                               offsetBy: 4)..<text.endIndex)
        else { throw Problem.notThisForm("It doesn't start with a header block.") }
        var header: [String: String] = [:]
        for (n, line) in text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let (key, value) = Self.pair(line), Self.headerKeys.contains(key)
            else { throw Problem.notThisForm("Line \(n + 2) isn't one of the header's lines.") }
            guard header[key] == nil else { throw Problem.notThisForm("Line \(n + 2) gives \(key) twice.") }
            guard !value.isEmpty else { throw Problem.notThisForm("Line \(n + 2): \(key) is blank.") }
            header[key] = value
        }
        guard header["kind"] == Self.kind, let title = header["title"] else {
            throw Problem.notThisForm("It needs a title and kind: \(Self.kind).")
        }
        var steps: [Step] = [], current: Step?, seen: Set<String> = []
        let bodyStart = text[..<close.upperBound].filter { $0 == "\n" }.count + 1
        for (n, raw) in text[close.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if line.hasPrefix("- step: ") {
                if let current { steps.append(current) }
                let words = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                guard !words.isEmpty else { throw Problem.notThisForm("Line \(n + bodyStart): a step has no words.") }
                current = Step(words: words)
                seen = []
                continue
            }
            guard current != nil, line.hasPrefix("  "), !line.hasPrefix("   "),
                  let (key, value) = Self.pair(line.dropFirst(2)), Self.stepKeys.contains(key)
            else { throw Problem.notThisForm("Line \(n + bodyStart) isn't a step or one of its parts.") }
            guard seen.insert(key).inserted else {
                throw Problem.notThisForm("Line \(n + bodyStart) gives a step's \(key) twice.")
            }
            guard !value.isEmpty else { throw Problem.notThisForm("Line \(n + bodyStart): \(key) is blank.") }
            switch key {
            case "name": current?.name = value
            case "photo":
                guard GuideTopics.matches(value, Self.photoPattern) else {
                    throw Problem.notThisForm("Line \(n + bodyStart): photo isn't a photo's file name.")
                }
                current?.photo = value
            case "video":
                guard GuideTopics.matches(value, Self.videoPattern) else {
                    throw Problem.notThisForm("Line \(n + bodyStart): video isn't a video's file name.")
                }
                current?.video = value
            case "caution": current?.caution = value
            case "danger": current?.danger = value
            case "wanted": current?.wanted = value
            case "guide": current?.guide = value
            case "calculator": current?.calculator = value
            case "checked": current?.checked = value
            case "items": current?.items = Self.split(value)
            case "ticks": current?.ticks = Self.split(value)
            case "place": current?.place = Picked(line: value)
            case "manual":
                guard let picked = Picked(line: value), picked.id != nil else {
                    throw Problem.notThisForm("Line \(n + bodyStart): manual isn't a picked item.")
                }
                current?.manual = picked
            case "map", "meet":
                guard value == "yes" else { throw Problem.notThisForm("Line \(n + bodyStart): \(key) can only be yes.") }
                if key == "map" { current?.map = true } else { current?.meet = true }
            case "yes", "no":
                guard GuideTopics.matches(value, "[0-9]+"), let to = Int(value) else {
                    throw Problem.notThisForm("Line \(n + bodyStart): \(key) isn't a step number.")
                }
                if key == "yes" { current?.yes = to } else { current?.no = to }
            default:  // call
                guard let split = value.range(of: "; ") else {
                    throw Problem.notThisForm("Line \(n + bodyStart): call needs a number, \"; \" and its label.")
                }
                current?.call = Call(number: String(value[..<split.lowerBound]).trimmingCharacters(in: .whitespaces),
                                     label: String(value[split.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        if let current { steps.append(current) }
        guard !steps.isEmpty else { throw Problem.notThisForm("It has no steps.") }
        self.init(title: title, when: header["when"] ?? "",
                  guides: (header["guides"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                      .filter { !$0.isEmpty },
                  keywords: (header["keywords"] ?? "").split(separator: ";").map {
                      $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                  sources: header["sources"] ?? "", checked: header["checked"] ?? "", walked: header["walked"] ?? "",
                  danger: header["danger"] ?? "", need: Self.split(header["need"] ?? ""), next: header["next"] ?? "",
                  things: try Self.split(header["things"] ?? "").map {
                      guard let thing = Picked(line: $0) else { throw Problem.notThisForm("What you need: a thing is blank.") }
                      return thing
                  },
                  steps: steps)
        if let why = formProblem { throw Problem.notThisForm(why) }
    }

    static let headerKeys = ["title", "kind", "when", "guides", "keywords", "sources", "checked", "walked", "danger",
                             "need", "next", "things"]
    static let stepKeys = ["name", "photo", "video", "caution", "danger", "wanted", "guide", "map", "meet", "items",
                           "calculator", "call", "yes", "no", "ticks", "checked", "place", "manual"]

    /// A "; "-separated line's parts, trimmed.
    static func split(_ value: String) -> [String] {
        value.isEmpty ? [] : value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func pair(_ line: Substring) -> (String, String)? {
        guard let colon = line.range(of: ": ") else { return nil }
        return (String(line[..<colon.lowerBound]), String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Names

    /// The pages the Mac starts, by the names event mode looks for (dashboard/event.py, readiness.model.EVENT_PLAN_PAGES):
    /// the first three (owner, 2026-10-17), then the four plan pages New page could never name (owner, 2026-10-26).
    public static let starterNames = ["shutoffs", "generator", "battery-backup", "evacuation", "rally-points",
                                      "how-we-reach-each-other", "school-pickup"]

    /// A new page's name: "house-" and a random part, never its title's words: a name is the page's path on every
    /// phone, and a title can hold what the checks would refuse before it is ever saved (the review, 2026-10-19). It
    /// can never take a guide's name. `taken`: names already in use.
    public static func newName(taken: Set<String>) -> String {
        var name: String
        repeat {
            name = "house-\(UUID().uuidString.prefix(8).lowercased())"
        } while taken.contains(name)
        return name
    }

    /// A photo's or video's file name for page `name`: the page's name and a short random part, so a step keeps its
    /// file when steps move.
    public static func mediaName(page name: String, ext: String) -> String {
        "\(name)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
    }

    // MARK: Starter pages

    /// The starter page for one of `starterNames` (concept-doc plan, phase C): drafts the owner fills in and writes
    /// over (owner, 2026-10-26: "write the guides and I can edit"). The general steps follow the guides each links to;
    /// every household detail is a "[Fill in: …]" blank. Nothing of the household is in them.
    public static func starter(_ name: String) -> HouseholdPage? {
        switch name {
        case "shutoffs":
            return HouseholdPage(
                title: "Utility shut-offs",
                when: "A gas smell, a burst pipe, water coming in, or before working on the wiring.",
                guides: ["utility-shutoff", "propane-leak", "downed-lines-flooded-wiring"],
                steps: [
                    Step(words: "Smell gas or hear hissing: get everyone out now. Don't switch lights on or off, or use "
                         + "phones or flames, until you're out. Call from a neighbor's house: [Fill in: the gas "
                         + "company's or propane supplier's emergency number], or 911.",
                         name: "Gas smell"),
                    Step(words: "Shut the gas or propane off outside, only if it's safe. Ours: [Fill in: where the valve "
                         + "is, the wrench or tool and where it's kept, and which way to turn it.] Ask the gas company "
                         + "or propane supplier how to shut off ours.",
                         name: "Gas or propane", caution: "Never turn the gas off just to practice."),
                    Step(words: "Shut the water at the main house valve, not the street valve at the curb. Ours: "
                         + "[Fill in: where it is and which way to turn it.]", name: "Water main"),
                    Step(words: "Sparks, frayed wires or wet appliances: if you're not standing in water, switch off the "
                         + "small breakers, then the main. If it isn't safe, leave and call for help. Ours: "
                         + "[Fill in: where the panel is.]", name: "Breaker panel"),
                    Step(words: "The well pump's breaker, to stop the water at a burst pipe: [Fill in: which one it is.]", name: "Well pump"),
                    Step(words: "Turning things back on: [Fill in: the order for the power and the water.] The gas "
                         + "stays off until a professional turns it back on.", name: "Back on"),
                ])
        case "generator":
            return HouseholdPage(
                title: "Hooking up the generator",
                when: "A power outage that may last more than a few hours.",
                guides: ["generator-co", "generator-house-connection", "generator-cords-gfci", "power-priorities"],
                steps: [
                    Step(words: "Run it outdoors only, well away from every door, window and vent, its exhaust pointed "
                         + "away from the house. Ours goes: [Fill in: the spot.]", name: "Where it sits",
                         caution: "Never in the garage, a shed or on the porch, even with the doors open."),
                    Step(words: "Press each carbon monoxide alarm's test button. Ours: [Fill in: where they are.]",
                         name: "CO alarms"),
                    Step(words: "The cord: [Fill in: where it's kept, and which end goes where.]", name: "The cord",
                         caution: "Never plug the generator into a wall outlet."),
                    Step(words: "Switch the house over to the generator: [Fill in: the outdoor plug (inlet), the transfer "
                         + "switch or interlock, and what to switch, in order.] Ask whoever installed it.",
                         name: "Switching over"),
                    Step(words: "With everything it powers turned off, start it and let it warm up. Then turn things "
                         + "on one at a time, with a pause between: [Fill in: which breakers, in order.]",
                         name: "Starting"),
                    Step(words: "Turn it off and let it cool before adding fuel.", name: "Refueling"),
                    Step(words: "When the power comes back: [Fill in: turning it off and switching the house back, in "
                         + "order.]", name: "Power back"),
                ])
        case "battery-backup":
            return HouseholdPage(
                title: "Setting up the battery backup",
                when: "A power outage, before the phones and fridge need power.",
                guides: ["outage-power-budget", "calc-outage-load", "power-priorities", "phone-power"],
                steps: [
                    Step(words: "Get it out: [Fill in: where the power station or battery bank is kept, and its cables.]",
                         name: "Where it is"),
                    Step(words: "Check how full it is: [Fill in: how to read it.]", name: "How full"),
                    Step(words: "Plug in what matters most first: [Fill in: what, in order, and about how long it lasts.]", name: "What plugs in"),
                    Step(words: "Charging it: [Fill in: from the wall, the generator or the solar panels, and how.]",
                         name: "Charging"),
                    Step(words: "When the power is back, charge it full and put it away: [Fill in: where.]",
                         name: "Putting it away"),
                ])
        case "evacuation":
            return HouseholdPage(
                title: "Our evacuation plan",
                when: "An evacuation order for our area, or water rising toward the house.",
                guides: ["flash-flood-home", "offline-maps", "document-kit", "damaged-home-reentry"],
                steps: [
                    Step(words: "Leave when told to, or sooner if water is rising. [Fill in: who decides, and how we "
                         + "tell everyone.]", name: "Go early"),
                    Step(words: "Take the go bags, medicines, documents, phones, chargers and pets. Ours: [Fill in: "
                         + "where they're kept.]", name: "What we take"),
                    Step(words: "If there's time before leaving: [Fill in: what to turn off (see Utility shut-offs), "
                         + "locking up, a note on where we went.] Tell our check-in person where we're going.", name: "The house"),
                    Step(words: "Where we go: [Fill in: the first place, and a second if that one can't take us.]",
                         name: "Where we go"),
                    Step(words: "The way out: [Fill in: our route, and a second one.]", name: "The route",
                         caution: "Never drive or walk into floodwater or past a road barrier."),
                    Step(words: "Come back only when officials say it's safe, and by day. [Fill in: who checks the "
                         + "house first.]", name: "Coming back"),
                ])
        case "rally-points":
            return HouseholdPage(
                title: "Where we meet",
                when: "We're apart and can't reach each other, or the house isn't safe.",
                guides: ["missing-person-search", "reaching-help"],
                steps: [
                    Step(words: "Leaving the house in a hurry, meet at: [Fill in: a spot just outside.]", name: "Near home"),
                    Step(words: "If we can't get home: [Fill in: a place nearby everyone knows.]",
                         name: "In the neighborhood"),
                    Step(words: "If the area is closed off: [Fill in: a place or a person farther away.]",
                         name: "Out of the area"),
                    Step(words: "Wait there [Fill in: how long]. If you have to move on, leave a note saying where you "
                         + "went. Our meeting places are on the street map.", name: "Waiting"),
                    Step(words: "If a child is missing, call the police right away, before searching yourselves. Don't "
                         + "wait out the time above.", name: "Someone missing"),
                ])
        case "how-we-reach-each-other":
            return HouseholdPage(
                title: "How we reach each other",
                when: "We're apart in an emergency, or the phones are struggling.",
                guides: ["reaching-help", "phone-alerts-sos", "gmrs-frs", "phone-power"],
                steps: [
                    Step(words: "Text each other instead of calling. In an emergency call 911. If the call won't go "
                         + "through, text 911 where it's offered, or keep calling.", name: "Text first"),
                    Step(words: "Everyone checks in with: [Fill in: a relative or friend outside the area.]",
                         name: "Our check-in person"),
                    Step(words: "Our numbers on paper: [Fill in: where each of us keeps the list.]",
                         name: "Numbers on paper"),
                    Step(words: "Walkie-talkies (family radios): [Fill in: where they are, our channel, and when we listen.]",
                         name: "Radios"),
                    Step(words: "Keeping phones charged: [Fill in: the power banks and car chargers, and where they "
                         + "are.]", name: "Charging"),
                ])
        case "school-pickup":
            return HouseholdPage(
                title: "School pickup",
                when: "School closes early, or an emergency while the kids are at school.",
                guides: ["kids-storms", "children-after-disaster", "reaching-help"],
                steps: [
                    Step(words: "Who picks up: [Fill in: who goes first, and who goes if they can't.]",
                         name: "Who picks up"),
                    Step(words: "The school's plan: [Fill in: where the school takes the children in an emergency, "
                         + "and how it tells parents. Ask the school office.]", name: "The school's plan"),
                    Step(words: "On the school's pickup list: [Fill in: who.] Keep the school's list up to date. Bring "
                         + "photo ID: the school may ask for it.",
                         name: "The pickup list"),
                    Step(words: "Kids: stay with your teacher until a grown-up on the list comes. [Fill in: anything "
                         + "else they should do.]", name: "Waiting at school"),
                    Step(words: "After pickup: [Fill in: home, or where we meet.]", name: "After pickup"),
                ])
        default:
            return nil
        }
    }
}

/// The daily library's guides (packer/guide_list.py, `household/guide-list.json`), for Household pages' "Links to
/// guides": read as strictly as GuideTopics; any other shape is refused and the editor offers no guides. Format 2
/// (the editor plan, Task 3) carries each guide's topic, the Guides list's section it sits under; format 1, from an
/// older library, reads with none ("").
public struct GuideList: Equatable, Sendable {
    public static let path = "household/guide-list.json"
    /// Each listed guide's topic (packer/guide_list.py's TOPICS_PATH), beside the list, which stays as every app
    /// reads it (the editor plan, Task 3); an older library has none, and the picker then shows one list.
    public static let topicsPath = "household/guide-list-topics.json"
    public struct Guide: Equatable, Sendable, Hashable {
        public let page, title: String
        public var topic = ""
        public var id: String { String(page.dropLast(5)) }
        public init(page: String, title: String, topic: String = "") {
            self.page = page
            self.title = title
            self.topic = topic
        }
    }
    public private(set) var guides: [Guide]

    public init(_ data: Data) throws {
        guard GuideTopics.keysAreOnceAndNumbersWhole(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "guides"], GuideTopics.count(top["format"]) == 1,
              let rows = top["guides"] as? [Any]
        else { throw GuideTopics.Problem.notTheShape }
        guides = try rows.map { row in
            guard let object = row as? [String: Any], Set(object.keys) == ["page", "title"],
                  let page = object["page"] as? String, GuideTopics.matches(page, "[a-z0-9-]+\\.html"),
                  let title = object["title"] as? String, GuideTopics.named(title)
            else { throw GuideTopics.Problem.notTheShape }
            return Guide(page: page, title: title)
        }
    }

    /// The list with `topicsPath`'s topics: `{"format": 1, "topics": [{"page", "topic"}, ...]}`, a guide it doesn't
    /// name under "Other". Unchanged, every topic empty, for a file of any other shape.
    public func withTopics(_ data: Data) -> GuideList {
        guard GuideTopics.keysAreOnceAndNumbersWhole(data),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(top.keys) == ["format", "topics"], GuideTopics.count(top["format"]) == 1,
              let rows = top["topics"] as? [Any] else { return self }
        var topic: [String: String] = [:]
        for row in rows {
            guard let object = row as? [String: Any], Set(object.keys) == ["page", "topic"],
                  let page = object["page"] as? String, let name = object["topic"] as? String, GuideTopics.named(name),
                  topic.updateValue(name, forKey: page) == nil else { return self }
        }
        var list = self
        list.guides = guides.map { Guide(page: $0.page, title: $0.title, topic: topic[$0.page] ?? Self.other) }
        return list
    }

    static let other = "Other"  // packer/guide_topics.py's OTHER_TOPIC
}
