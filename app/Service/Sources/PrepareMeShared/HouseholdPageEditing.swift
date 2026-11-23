import Foundation

/// The Mac editor's changes to an Our Home page (docs/plans/2026-11-16-our-home.md, Task 2.5), kept here so they're
/// tested: moving and removing steps keep every Yes and No on the step it meant, a blank is filled in place, and a
/// step's kind (Next, Yes or No, Checklist) follows from its lines. A Yes or No of 0 points at no step (its step was
/// removed, or it hasn't been chosen yet): `problem` says so and Save waits.
extension HouseholdPage {
    public enum Kind: Equatable, Sendable, CaseIterable {
        case next, yesNo, checklist
    }

    /// A blank on the page: where it is (the when, or a step's caution or words, by index) and which one there.
    public struct Blank: Equatable, Hashable, Sendable {
        public enum Field: Equatable, Hashable, Sendable {
            case when, caution(Int), words(Int)
        }
        public let field: Field
        public let index: Int
        public let question: String
        public let answer: String?
    }

    /// Every blank in page order (the start screen's when, then each step's caution and words, as a phone shows them).
    public var blanks: [Blank] {
        let fields = [Blank.Field.when] + steps.indices.flatMap { [Blank.Field.caution($0), .words($0)] }
        return fields.flatMap { field in
            Self.blanks(text(field)).enumerated().map { Blank(field: field, index: $0, question: $1.question, answer: $1.answer) }
        }
    }

    /// The blanks not filled yet, in page order.
    public var unfilledBlanks: [Blank] { blanks.filter { $0.answer == nil } }

    /// Board 7's Go to the next (the editor plan, Task 6): the first blank left after `after` in the screen's order
    /// (Use this when, then each step's words and its warning's row), past the last back to the first; nil with none.
    public func nextBlank(after: Blank?) -> Blank? {
        let fields = [Blank.Field.when] + steps.indices.flatMap { [Blank.Field.words($0), .caution($0)] }
        let order = fields.flatMap { field in blanks.filter { $0.field == field } }
        let first = order.first { $0.answer == nil }
        guard let after, let at = order.firstIndex(where: { $0.field == after.field && $0.index == after.index }) else {
            return first
        }
        return order[(at + 1)...].first { $0.answer == nil } ?? first
    }

    /// Fills `blank` with `answer` (one line; a [, ], { or } left out so the blank stays whole), or empties it for a
    /// blank answer. A step's checked mark never changes: a blank isn't part of the words as checked. While typing
    /// the answer keeps its spaces, a trailing one too, so a second word can follow (owner check 95, 2026-11-20:
    /// each key trimmed "Call " back to "Call"); `trim`, which Save's `tidied` passes, makes it one tidy line.
    public mutating func fill(_ blank: Blank, with answer: String, trim: Bool = false) {
        let text = text(blank.field)
        let matches = Self.blank.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.indices.contains(blank.index), let range = Range(matches[blank.index].range, in: text) else { return }
        let question = Self.blanks(text)[blank.index].question
        let kept = String(answer.compactMap { "[]{}".contains($0) ? nil : Self.line(String($0)).isEmpty ? " " : $0 })
        let words = trim || Self.line(kept).isEmpty ? Self.line(kept) : String(kept.drop { $0 == " " })
        setText(blank.field, text.replacingCharacters(in: range, with: "[Fill in: \(question)]" + (words.isEmpty ? "" : "{\(words)}")))
    }

    func text(_ field: Blank.Field) -> String {
        switch field {
        case .when: when
        case .caution(let i): steps.indices.contains(i) ? steps[i].caution : ""
        case .words(let i): steps.indices.contains(i) ? steps[i].words : ""
        }
    }

    mutating func setText(_ field: Blank.Field, _ text: String) {
        switch field {
        case .when: when = text
        case .caution(let i): if steps.indices.contains(i) { steps[i].caution = text }
        case .words(let i): if steps.indices.contains(i) { steps[i].words = text }
        }
    }

    /// Moves the step at `from` to `to` (indices), every Yes and No still pointing at the step it named.
    public mutating func moveStep(from: Int, to: Int) {
        guard steps.indices.contains(from), steps.indices.contains(to), from != to else { return }
        var order = Array(steps.indices)
        order.insert(order.remove(at: from), at: to)
        steps = order.map { steps[$0] }
        renumber { old in order.firstIndex(of: old - 1).map { $0 + 1 } ?? 0 }
    }

    /// Removes the step at `index`; a Yes or No that named it becomes 0, which `problem` won't let be saved.
    public mutating func removeStep(at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
        renumber { old in old == index + 1 ? 0 : old > index + 1 ? old - 1 : old }
    }

    private mutating func renumber(_ new: (Int) -> Int) {
        for i in steps.indices {
            steps[i].yes = steps[i].yes.map { $0 == 0 ? 0 : new($0) }
            steps[i].no = steps[i].no.map { $0 == 0 ? 0 : new($0) }
        }
    }

    /// Sets a step's kind: Next clears its question and ticks, Yes or No asks for both steps (0 until chosen), and a
    /// Checklist keeps an empty first tick so it stays one while the ticks are typed.
    public mutating func setKind(_ kind: Kind, step i: Int) {
        guard steps.indices.contains(i), steps[i].kind != kind else { return }
        steps[i].yes = kind == .yesNo ? 0 : nil
        steps[i].no = kind == .yesNo ? 0 : nil
        steps[i].ticks = kind == .checklist ? [""] : []
    }
}

extension HouseholdPage {
    /// A part a step may carry, each one row in the editor's step card (boards 1 and 2; the editor plan, Task 5).
    /// `items` is an old page's "Where it's kept" line: shown and removable, never offered.
    public enum Part: Equatable, Hashable, Sendable, CaseIterable {
        case danger, caution, place, call, guide, manual, photo, video, items
    }
}

extension HouseholdPage.Step {
    /// Yes or No when it has its two steps, Checklist when it has ticks (even one still empty), else Next.
    public var kind: HouseholdPage.Kind { yes != nil ? .yesNo : ticks.isEmpty ? .next : .checklist }

    /// Whether the step carries `part`: its row shows when the page opens.
    public func has(_ part: HouseholdPage.Part) -> Bool {
        switch part {
        case .danger: !danger.isEmpty
        case .caution: !caution.isEmpty
        case .place: place != nil
        case .call: call != nil
        case .guide: !guide.isEmpty
        case .manual: manual != nil
        case .photo: !photo.isEmpty
        case .video: !video.isEmpty
        case .items: !items.isEmpty
        }
    }

    /// Takes `part` away and nothing else (a photo's or video's file is the editor's to set aside first).
    public mutating func remove(_ part: HouseholdPage.Part) {
        switch part {
        case .danger: danger = ""
        case .caution: caution = ""
        case .place: place = nil
        case .call: call = nil
        case .guide: guide = ""
        case .manual: manual = nil
        case .photo: photo = ""
        case .video: video = ""
        case .items: items = []
        }
    }

    /// "Add to this step", in the boards' order: Warning (as the kind the step lacks, Danger first) while it lacks
    /// either, then each part it neither has nor shows as a row just added (`showing`, still empty).
    public func offered(showing: Set<HouseholdPage.Part>) -> [HouseholdPage.Part] {
        let shown = { (part: HouseholdPage.Part) in has(part) || showing.contains(part) }
        let warning: [HouseholdPage.Part] = !shown(.danger) ? [.danger] : !shown(.caution) ? [.caution] : []
        return warning + [.place, .call, .guide, .manual, .photo, .video].filter { !shown($0) }
    }

    /// Whether a warning of `kind` can become the other kind: only while the step doesn't hold that one.
    public func canSwitch(_ kind: HouseholdPage.Part) -> Bool {
        kind == .danger ? caution.isEmpty : kind == .caution ? danger.isEmpty : false
    }

    /// "make it a Caution" or "make it a Danger": the warning's words move to the other kind.
    public mutating func switchWarning(_ kind: HouseholdPage.Part) {
        guard canSwitch(kind) else { return }
        if kind == .danger { (caution, danger) = (danger, "") } else { (danger, caution) = (caution, "") }
    }
}

/// The editor's fixed words (OK'd with phase D's boards 18 to 21, 2026-11-16; "1 blank left" by click the same day).
public enum HomeEditorWords {
    /// Board 7's bar, a folded step's line and the page list's line: nil with none left, so no bar shows
    public static func leftToFill(_ n: Int) -> String? { n == 0 ? nil : "\(n) left to fill in" }
    public static let goToNext = "Go to the next"
    public static func fillInLabel(_ question: String) -> String { "Fill in: \(question)" }
    /// Under a blank's box, which shows the marker itself, not a line (the review, 2026-11-20)
    public static func answerReplaces(_ question: String) -> String { "Your answer takes the place of [Fill in: \(question)] above." }
    public static let addOne = "Add one, then Return"
    public static func answerTo(_ n: Int, _ name: String) -> String { "Step \(n): \(name)" }
    /// "Walked through Oct 4" for a YYYY-MM-DD date (the page list's line)
    public static func walked(_ iso: String) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return "Walked through \(iso)" }
        return "Walked through \(months[parts[1] - 1]) \(parts[2])"
    }
    public static let notWritten = "Not written yet"
    public static let preview = "Preview"
    public static let previewTitle = "Preview, as a phone shows it"
    public static let pageDetails = "Page details"
    public static let dangerFirst = "Danger first"
    public static let dangerHint = "Shown first on the start screen, in red. Leave empty if none."
    public static let need = "What you need", next = "What comes next", sources = "Sources"
    public static let walkedLabel = "Last walked through", notYet = "Not yet", today = "Today"
    public static let kind = "Kind"
    public static let kinds: [(HouseholdPage.Kind, String)] = [(.next, "Next"), (.yesNo, "Yes or No"), (.checklist, "Checklist")]
    public static let question = "Question", yesGoesTo = "Yes goes to", noGoesTo = "No goes to", chooseStep = "Choose a step"
    public static let ticks = "Ticks", ticksHint = "One a line, 2 to 12."
    public static let kept = "Where it's kept", call = "Number to call"
    public static let checked = "As checked against the sources"
    public static let photoWanted = "Photo wanted here"
    // the fresh look (docs/design/our-home/editor-boards.html's word list, and the design session's of 2026-11-20)
    public static let whatToDo = "What to do", shortName = "Short name", stepIs = "This step is"
    public static let addToStep = "Add to this step"
    public static let warning = "Warning", place = "Place", guide = "Guide", manual = "Manual", photo = "Photo",
                      video = "Video", danger = "Danger", caution = "Caution"
    public static let makeCaution = "make it a Caution", makeDanger = "make it a Danger"
    public static let inInventory = "In your inventory", notInInventory = "not in your inventory", or = "Or"
    public static let fromInventory = "from your inventory"
    public static func useTyped(_ words: String) -> String { "Use “\(words)” as typed" }
    public static func noPlace(_ words: String) -> String { "No place matches “\(words)”." }
    public static func itemCount(_ n: Int) -> String { n == 0 ? "no items" : n == 1 ? "1 item" : "\(n) items" }
    public static let searchGuides = "Search guides"
    public static func topicOf(_ topic: String, _ found: Int, _ total: Int) -> String { "\(topic) · \(found) of \(total)" }
    public static let withManual = "Items with a manual"
    public static let manualNote = "An item with no manual isn't listed. Attach one in Inventory with Add Manual…, then pick it here."
    public static let stale = "No longer in your inventory", pickAgain = "Pick again"
    /// A set part's small line (board 2): its name, then what it says, joined by " · "
    public static func row(_ name: String, _ detail: String) -> String { detail.isEmpty ? name : "\(name) · \(detail)" }
    /// The folded step's names for its parts (board 2's "Danger, a place, a number to call")
    public static let partNames: [(HouseholdPage.Part, String)] = [
        (.danger, "Danger"), (.caution, "Caution"), (.place, "a place"), (.call, "a number to call"), (.guide, "a guide"),
        (.manual, "a manual"), (.photo, "a photo"), (.video, "a video"),
    ]
    /// What "Add to this step" calls each part; a warning is added by its kind's name, Warning
    public static func adds(_ part: HouseholdPage.Part) -> String {
        switch part {
        case .danger, .caution: warning
        case .place: place
        case .call: call
        case .guide: guide
        case .manual: manual
        case .photo: photo
        case .video: video
        case .items: kept
        }
    }
}
