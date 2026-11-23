// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import AppKit
import PDFKit
import PrepareMeShared
import SwiftUI
import WebKit

/// Printable References (docs/plans/2026-10-21-printable-references-screen.md; the owner's mockup, 2026-10-21): the
/// Family Emergency Card's boxes beside its live picture, and the Essential Guides Binder's status. The card's rules,
/// limits and page are paper/card.py's own, run from the copy inside the app (PaperCardText); the card file is
/// Household Private › Plans › card.toml, written whole. Printing asks the scheduler's paper job, which runs the
/// Terminal command's own Chrome step (the app's sandbox can't), and the PDF it makes opens in the print dialog. The
/// card's text is shown on this screen only: never logged, never in a message.
enum PrintableWords {
    static let card = "Family Emergency Card"
    static let binder = "Essential Guides Binder"
    static let printCard = "Print Family Emergency Card…"
    static let printWhole = "Print the whole binder…"
    static let printChanged = "Print what changed…"
    static let blank = "Blank: prints as a line to write on"
    static let wontPrint = "Won't print: "
    static let reading = "Reading the card…"
    static let checking = "Checking every line…"
    static let notSaved = "Not saved yet."
    static let noFile = "No card file yet: fill in the boxes, then save to make it."
    static let saveFailed = "PrepareMe couldn't save the card file; nothing was changed."
    static let iCloud = "card.toml is still in iCloud only. PrepareMe has asked for it; this fills in when it arrives."
    static let asking = "Asking the print job…"
    static let making = "Making the PDF with Chrome… The print dialog opens when it's done."
    static let noAnswer = "The print job didn't answer. It's installed once, from a Claude session (\"install the paper "
        + "job\"); the main PrepareMe folder must be on main with nothing uncommitted."
    static let stillWorking = "The print job is still working. The PDF will be in Household Private › Print when it's "
        + "done; open it from there in Preview to print it."
    static let unreadable = "card.toml couldn't be read (it may still be coming down from iCloud), so PrepareMe shows "
        + "nothing and saves nothing over it. Try Read again in a minute."
    static let noJob = "Printing needs PrepareMe's print job."
    static let noJobWhy = "It's installed once, from a Claude session: \"install the paper job\". Until then the card "
        + "still saves, and Terminal still prints it."
    static let fixed = "911, the tornado step, Poison Control 1-800-222-1222, the gas smell and generator lines, the "
        + "Kiwix line, and a blank for the school code word. The code word is always written by hand, so there's no box "
        + "for it."
    static let picture = "The card as it prints now, redrawn as you type. The line you're typing is outlined."
    static let pdfButton = "The PDF opens in the Mac's print dialog. Its PDF button saves a copy wherever you like."

    static func printsIn(_ n: Int) -> String { "Prints in \(n) places on the card" }

    static func wontPrintCount(_ n: Int) -> String {
        n == 1 ? "1 line won't print as it is (marked below)." : "\(n) lines won't print as they are (marked below)."
    }

    static func saved(_ date: Date) -> String {
        "Saved \(date.formatted(date: .long, time: .shortened)), to Household Private › Plans › card.toml."
    }
}

/// The card file's identity when it was read: a save that finds it changed (TextEdit, say) asks first.
private struct Stamp: Equatable {
    let size: Int
    let modified: Date
    let inode: UInt64

    init?(_ url: URL) {
        guard let found = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (found[.size] as? NSNumber)?.intValue, let modified = found[.modificationDate] as? Date,
              let inode = (found[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        self.size = size
        self.modified = modified
        self.inode = inode
    }
}

@MainActor
final class PrintableReferencesModel: ObservableObject {
    static let shared = PrintableReferencesModel()

    enum Part: String { case card, binder }
    enum Ask: Identifiable {
        case replaceUnreadable, notInForm, changedOnDisk
        var id: Self { self }
    }

    /// A line under the header: plain, worth a look (amber) or danger (red), and the print job's own lines under it.
    struct Line: Equatable {
        enum Kind { case plain, caution, danger }
        let words: String
        var kind: Kind = .plain
        var more: [String] = []
    }

    @Published var part: Part = .card
    @Published private(set) var form: PaperCard.Form?
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var numbers: [PaperCard.Number] = []
    @Published private(set) var checked: PaperCard.Checked?
    @Published private(set) var dirty = false
    @Published private(set) var savedAt: Date?
    @Published private(set) var busy: String?
    @Published var line: Line?
    @Published var asking: Ask?
    @Published private(set) var status: PaperStatus?
    private var focus: String?
    private var stamp: Stamp?
    private var pending: Task<Void, Never>?
    private var waiting: Task<Void, Never>?
    private var statusWaiting: Task<Void, Never>?

    // MARK: Places

    private var household: URL? {
        PrepareMeHome.url?.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Household Private")
    }
    var cardFile: URL? { household?.appendingPathComponent("Plans/card.toml") }
    var printFolder: URL? { household?.appendingPathComponent("Print") }
    private var requests: URL? { PrepareMeMac.folders?.appendingPathComponent("requests") }

    /// Whether `python -m scheduler install paper` has run (jobs/installed.json names it).
    var jobInstalled: Bool {
        guard let url = PrepareMeMac.folders?.appendingPathComponent("jobs/installed.json"),
              let data = try? Data(contentsOf: url),
              let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return found["paper"] != nil
    }

    private var text: PaperCardText {
        PaperCardText(python: PythonTextCheck.venvPython() ?? URL(fileURLWithPath: "/nonexistent"),
                      code: Bundle.main.resourceURL?.appendingPathComponent("check") ?? URL(fileURLWithPath: "/nonexistent"))
    }

    // MARK: The card

    var problems: [PaperCard.Problem] { checked?.problems ?? form?.problems ?? [] }
    func problem(_ id: String) -> PaperCard.Problem? { problems.first { $0.field == id } }
    var fileProblems: [PaperCard.Problem] { problems.filter { $0.field == nil } }
    var printsIn: Int { checked?.printsIn ?? 0 }

    func value(_ id: String) -> String { values[id] ?? "" }

    func set(_ id: String, _ value: String) {
        guard values[id] != value else { return }
        values[id] = value
        changed()
    }

    func setNumber(_ row: Int, label: String? = nil, phone: String? = nil) {
        guard numbers.indices.contains(row) else { return }
        if let label { numbers[row].label = label }
        if let phone { numbers[row].phone = phone }
        changed()
    }

    func focused(_ id: String?) {
        guard id != focus else { return }
        focus = id
        recheckSoon()
    }

    private func changed() {
        dirty = true
        recheckSoon()
    }

    /// Reads card.toml (none yet: blank boxes). One that's only in iCloud is asked for and read when it arrives; one
    /// that's there but can't be read (still in iCloud when the wait ends, offline, refused) shows nothing, so Save can
    /// never write the boxes over it (the review, 2026-10-21).
    func load() async {
        guard let cardFile else { return }
        busy = PrintableWords.reading
        defer { busy = nil }
        let placeholder = cardFile.deletingLastPathComponent().appendingPathComponent(".card.toml.icloud")
        let there = FileManager.default.fileExists(atPath: cardFile.path)
        if there ? !Self.downloaded(cardFile) : FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: cardFile)
            line = Line(words: PrintableWords.iCloud, kind: .caution)
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: cardFile.path) || !Self.downloaded(cardFile) {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        let exists = FileManager.default.fileExists(atPath: cardFile.path)
        let data = exists ? (try? Data(contentsOf: cardFile)) : Data()
        guard let data, exists || !FileManager.default.fileExists(atPath: placeholder.path) else {
            form = nil
            checked = nil
            line = Line(words: PrintableWords.unreadable, kind: .danger)
            return
        }
        do {
            let read = try await text.read(data)
            form = read
            values = Dictionary(uniqueKeysWithValues: read.fields.map { ($0.id, $0.value) })
            numbers = read.numbers
            stamp = exists ? Stamp(cardFile) : nil
            savedAt = stamp?.modified
            dirty = false
            line = exists ? nil : Line(words: PrintableWords.noFile)
            await recheck()
        } catch let unavailable as CheckUnavailable {
            line = Line(words: unavailable.description.replacingOccurrences(of: "nothing was saved",
                                                                            with: "the card can't be shown"),
                        kind: .danger)
        } catch {
            line = Line(words: PrintableWords.unreadable, kind: .danger)
        }
    }

    /// Whether iCloud has the file here in full (a file it hasn't brought down keeps its name but holds nothing yet);
    /// a file outside iCloud, as in the check build, always is.
    private static func downloaded(_ url: URL) -> Bool {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let status = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    private func input(focus: String?) -> PaperCard.CheckInput {
        PaperCard.CheckInput(fields: values, numbers: numbers, printed: Self.day(.now), changed: savedAt.map(Self.day),
                             focus: focus)
    }

    /// A date as the card prints it, YYYY-MM-DD on this Mac's calendar (never UTC's, which is tomorrow by evening).
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func recheckSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await recheck()
        }
    }

    /// The problems and the live picture for the boxes as they are now.
    func recheck() async {
        guard form != nil else { return }
        let found = try? await text.check(input(focus: focus))
        guard !Task.isCancelled, let found else { return }  // a later check is on its way
        checked = found
    }

    /// Checks every box, then writes card.toml whole; whether it was saved. Fails closed: no answer, no save. A file
    /// that can't be read, one typed in TextEdit, or one changed since it was read is written only once the owner says.
    func save(confirmed: Ask? = nil) async -> Bool {
        guard let cardFile, let form else { return false }
        pending?.cancel()
        busy = PrintableWords.checking
        defer { busy = nil }
        let sent = input(focus: focus)  // what's saved: anything typed while it's checked stays not saved
        let found: PaperCard.Checked
        do {
            found = try await text.check(sent)
        } catch let unavailable as CheckUnavailable {
            line = Line(words: unavailable.description, kind: .danger)
            return false
        } catch {
            line = Line(words: PrintableWords.saveFailed, kind: .danger)
            return false
        }
        checked = found
        guard let toml = found.toml else {
            line = Line(words: PrintableWords.wontPrintCount(found.problems.count), kind: .danger)
            return false
        }
        let exists = FileManager.default.fileExists(atPath: cardFile.path)
        if exists, Stamp(cardFile) != stamp, confirmed != .changedOnDisk {
            asking = .changedOnDisk
            return false
        }
        if exists, !form.readable, confirmed == nil {
            asking = .replaceUnreadable
            return false
        }
        if exists, form.readable, !form.inForm, confirmed == nil {
            asking = .notInForm
            return false
        }
        do {
            try FileManager.default.createDirectory(at: cardFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try DurableFile.write(Data(toml.utf8), to: cardFile)
        } catch {
            line = Line(words: PrintableWords.saveFailed, kind: .danger)
            return false
        }
        stamp = Stamp(cardFile)
        savedAt = stamp?.modified ?? .now
        dirty = values != sent.fields || numbers != sent.numbers
        line = nil
        // what's on disk now is PrepareMe's own form
        if let data = try? Data(contentsOf: cardFile), let read = try? await text.read(data) { self.form = read }
        return true
    }

    // MARK: Printing

    /// Saves the card when it has changes (the print job prints the file), then asks the job for `request`'s PDF and
    /// opens it in the print dialog when it's made.
    func print(_ request: String) async {
        if request == PaperStatus.card, dirty || cardFile.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            guard await save() else { return }
            if dirty { return }  // typed while saving: the file isn't what's on screen, so it isn't printed
        }
        guard let requests, let pressed = press(request, in: requests) else {
            line = Line(words: PrintableWords.noAnswer, kind: .caution)
            return
        }
        busy = PrintableWords.asking
        line = nil
        waiting?.cancel()
        waiting = Task { await wait(for: request, pressed: pressed, in: requests) }
    }

    /// Creates the request file, or sets its time to now, and gives that time (nanoseconds), which the job's answer
    /// names; never follows a link by that name.
    private func press(_ request: String, in folder: URL) -> Int64? {
        try? PrepareMeRequests.touch(request, in: folder)
    }

    /// Waits for the job's answer to this press (its `pressed`, never an older answer), up to half an hour: a whole
    /// binder can take minutes. After 20 seconds with no sign of the job the line says so, and the wait goes on, so a
    /// job that starts late still opens its PDF.
    private func wait(for request: String, pressed: Int64, in folder: URL) async {
        var seen = false
        for second in 0..<1800 {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let found = PaperStatus.read(in: folder)
            if let found { status = found }
            if found?.running?.request == request, !seen {
                seen = true
                busy = PrintableWords.making
                line = nil
            }
            if let result = found?.results?[request], (result.pressed ?? 0) >= pressed {
                busy = nil
                answered(result)
                return
            }
            if !seen, second == 20 {
                busy = nil
                line = Line(words: PrintableWords.noAnswer, kind: .caution)
            }
        }
        busy = nil
        line = Line(words: PrintableWords.stillWorking, kind: .caution)
    }

    /// The binder's status: the last one the job wrote now, and a fresh one asked for. Its own wait never touches the
    /// buttons or the line (the review: it ended a save's busy).
    func refreshBinder() {
        guard let requests else { return }
        status = PaperStatus.read(in: requests)
        guard jobInstalled, let pressed = press(PaperStatus.binderStatus, in: requests) else { return }
        statusWaiting?.cancel()
        statusWaiting = Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let found = PaperStatus.read(in: requests) else { continue }
                status = found
                if (found.results?[PaperStatus.binderStatus]?.pressed ?? 0) >= pressed { return }
            }
        }
    }

    private func answered(_ result: PaperStatus.Result) {
        let lines = result.lines.filter { !$0.hasPrefix("Printed") }
        switch result.exit {
        case 0:
            guard let pdf = result.pdf, let folder = printFolder else {
                if result.request != PaperStatus.binderStatus { line = Line(words: result.lines.first ?? "") }
                return
            }
            line = lines.isEmpty ? nil : Line(words: lines.joined(separator: " "))
            openPDF(folder.appendingPathComponent(pdf))
        case 1:
            line = Line(words: lines.first ?? PrintableWords.noAnswer, kind: .danger, more: Array(lines.dropFirst()))
        default:
            line = Line(words: lines.first ?? PrintableWords.noAnswer, kind: .caution, more: Array(lines.dropFirst()))
        }
    }

    /// The PDF the job made, in the print dialog at its own size (its PDF button saves a copy anywhere).
    private func openPDF(_ pdf: URL) {
        guard let document = PDFDocument(url: pdf) else {
            line = Line(words: "PrepareMe couldn't open \(pdf.lastPathComponent) in Household Private › Print.",
                        kind: .danger)
            return
        }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)?.run()
    }

}

// MARK: - The screen

struct PrepareMePrintableReferencesView: View {
    @ObservedObject private var model = PrintableReferencesModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            if !model.jobInstalled { noJob }
            if model.part == .card {
                PrintableCardView()
            } else {
                PrintableBinderView()
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if model.form == nil { await model.load() }
            #if PREPAREME_CHECK
            // The check build only, for a check that can't click (screenshots only; 2026-10-21): PREPAREME_CHECK_PART=binder
            // shows the binder, PREPAREME_CHECK_PRINT names a request to press (print-card, print-binder, …)
            let check = ProcessInfo.processInfo.environment
            if check["PREPAREME_CHECK_PART"] == "binder" { model.part = .binder }
            if check["PREPAREME_CHECK_PART"] == "binder-then-card" {  // the card's picture made again (2026-10-27)
                model.part = .binder
                try? await Task.sleep(for: .seconds(3))
                model.part = .card
            }
            if let request = check["PREPAREME_CHECK_PRINT"] {
                try? await Task.sleep(for: .seconds(3))
                await model.print(request)
            }
            #endif
        }
        .toolbar {  // the switch and the buttons in the band (look 3, plan Task 6.2), as they were on a row of their own
            ToolbarItem(placement: .principal) { partPicker }
            ToolbarItemGroup(placement: .primaryAction) { buttons }
        }
        .focusedSceneValue(\.macSave, model.part == .card  // File › Save, as the card's Save button
                           ? MacSave(enabled: model.busy == nil && model.form != nil) { Task { await model.save() } } : nil)
        .onChange(of: model.part) { _, part in if part == .binder { model.refreshBinder() } }
        .alert(model.asking.map(title) ?? "", isPresented: Binding(get: { model.asking != nil },
                                                                  set: { if !$0 { model.asking = nil } }),
               presenting: model.asking) { ask in buttons(ask) } message: { ask in Text(message(ask)) }
    }

    private var partPicker: some View {
        Picker("", selection: $model.part) {
            Text(PrintableWords.card).tag(PrintableReferencesModel.Part.card)
            Text(PrintableWords.binder).tag(PrintableReferencesModel.Part.binder)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var buttons: some View {
        if model.part == .card, model.form == nil, model.busy == nil {
            Button("Read again") { Task { await model.load() } }
        } else if model.part == .card {
            // reads card.toml again: the card as last saved; click only, so Escape in a box never throws edits away
            Button("Cancel") { Task { await model.load() } }
                .disabled(model.busy != nil || model.form == nil || !model.dirty)
            Button("Save") { Task { await model.save() } }  // ⌘S is File › Save's (look 3, change 18)
                .disabled(model.busy != nil || model.form == nil)
            Button(PrintableWords.printCard) { Task { await model.print(PaperStatus.card) } }
                .disabled(model.busy != nil || model.form == nil)
        } else {
            Button(PrintableWords.printWhole) { Task { await model.print(PaperStatus.binder) } }
                .disabled(model.busy != nil)
            Button(PrintableWords.printChanged) { Task { await model.print(PaperStatus.binderChanged) } }
                .disabled(model.busy != nil || (model.status?.binder?.printed == nil))
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let busy = model.busy {
            Label(busy, systemImage: "hourglass").foregroundStyle(PrepareMeColors.text2)
        } else if let line = model.line {
            PrintableCallout(line: line)
        } else if model.part == .card {
            HStack(spacing: 8) {
                Circle().fill(model.dirty || !model.problems.isEmpty ? PrepareMeColors.accent : PrepareMeColors.okMark)
                    .frame(width: 9, height: 9)
                Text(cardStatus).foregroundStyle(PrepareMeColors.text2)
            }
        } else if let changed = model.status?.binder?.changed, !changed.isEmpty,
                  let printed = model.status?.binder?.printed {
            HStack(spacing: 8) {
                Circle().fill(PrepareMeColors.accent).frame(width: 9, height: 9)
                Text("\(changed.count == 1 ? "1 guide" : "\(changed.count) guides") changed since the binder printed on "
                     + "\(PrintableBinderView.longDate(printed)).").foregroundStyle(PrepareMeColors.text2)
            }
        }
    }

    private var cardStatus: String {
        let bad = model.problems.count
        var words = model.dirty ? PrintableWords.notSaved + " " : ""
        if bad > 0 { words += PrintableWords.wontPrintCount(bad) + " " }
        if let saved = model.savedAt { words += PrintableWords.saved(saved) } else if !model.dirty {
            words += PrintableWords.noFile
        }
        return words
    }

    private var noJob: some View {
        PrintableCallout(line: .init(words: PrintableWords.noJob, kind: .caution, more: [PrintableWords.noJobWhy]))
    }

    /// The card's questions before a save. Cancel on each (Apple's Alerts page: a destructive choice always has
    /// Cancel beside it).
    private func title(_ ask: PrintableReferencesModel.Ask) -> String {
        switch ask {
        case .replaceUnreadable: "Replace the card file PrepareMe can't read?"
        case .notInForm: "Save the card in PrepareMe's form?"
        case .changedOnDisk: "card.toml changed since PrepareMe opened it"
        }
    }

    private func message(_ ask: PrintableReferencesModel.Ask) -> String {
        switch ask {
        case .replaceUnreadable:
            "card.toml can't be read, so the boxes opened blank. Saving replaces it with what's in the boxes now."
        case .notInForm:
            "Your lines are kept. Comments you added in TextEdit aren't, and neither is anything the card doesn't know."
        case .changedOnDisk:
            "It was changed in another app, perhaps TextEdit. Reload it to see that version, or save over it with "
                + "what's in the boxes."
        }
    }

    @ViewBuilder private func buttons(_ ask: PrintableReferencesModel.Ask) -> some View {
        switch ask {
        case .replaceUnreadable:
            Button("Replace it", role: .destructive) { Task { await model.save(confirmed: .replaceUnreadable) } }
        case .notInForm:
            Button("Save") { Task { await model.save(confirmed: .notInForm) } }
        case .changedOnDisk:
            Button("Save over it", role: .destructive) { Task { await model.save(confirmed: .changedOnDisk) } }
            Button("Reload") { Task { await model.load() } }
        }
        Button("Cancel", role: .cancel) {}
    }
}

/// A line in a box: amber worth a look, red danger, each with its word first, so nothing rests on the color.
struct PrintableCallout: View {
    let line: PrintableReferencesModel.Line

    var body: some View {
        switch line.kind {
        case .plain:
            Text(line.words).foregroundStyle(PrepareMeColors.text2)
        case .caution, .danger:
            let danger = line.kind == .danger
            VStack(alignment: .leading, spacing: 4) {
                Text(line.words).bold().foregroundStyle(danger ? PrepareMeColors.red : PrepareMeColors.caution)
                ForEach(line.more, id: \.self) { more in Text(more).fixedSize(horizontal: false, vertical: true) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: 760, alignment: .leading)
            .background(danger ? PrepareMeColors.redBg : PrepareMeColors.accentBg)
            .overlay(alignment: .leading) {
                Rectangle().fill(danger ? PrepareMeColors.redMark : PrepareMeColors.accent).frame(width: 5)
            }
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.panel)
                .stroke(danger ? PrepareMeColors.redMark : PrepareMeColors.accent))
            .clipShape(RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
        }
    }
}

// MARK: - The card's boxes and picture

struct PrintableCardView: View {
    @ObservedObject private var model = PrintableReferencesModel.shared
    @FocusState private var focused: String?

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.fileProblems, id: \.message) { problem in
                        PrintableCallout(line: .init(words: problem.message, kind: .danger))
                    }
                    ForEach(sections, id: \.self) { section in
                        sectionView(section)
                    }
                    numbersView
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Already on every card").font(.pmHeadline)
                        Divider()
                        Text(PrintableWords.fixed).foregroundStyle(PrepareMeColors.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 10)
                .padding(.bottom, 20)
            }
            .frame(width: 440)
            Divider()
            VStack(spacing: 10) {
                PrintableCardPicture(page: model.checked?.page ?? "")
                    .aspectRatio(8.5 / 11, contentMode: .fit)
                    .frame(maxWidth: 620)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                Text(PrintableWords.picture).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 320, maxWidth: .infinity, alignment: .top)
        }
        .onChange(of: focused) { _, id in model.focused(id) }
        #if PREPAREME_CHECK
        // The check build only (screenshots only; 2026-10-21): PREPAREME_CHECK_FOCUS puts the cursor in a box, and
        // PREPAREME_CHECK_TYPE types made-up words into it, as the owner would
        .task {
            let check = ProcessInfo.processInfo.environment
            guard let id = check["PREPAREME_CHECK_FOCUS"] else { return }
            try? await Task.sleep(for: .seconds(2))
            focused = id
            if let words = check["PREPAREME_CHECK_TYPE"] { model.set(id, words) }
        }
        #endif
    }

    private var sections: [String] {
        var seen: [String] = []
        for field in model.form?.fields ?? [] where !seen.contains(field.section) { seen.append(field.section) }
        return seen
    }

    private func fields(_ section: String) -> [PaperCard.Field] {
        (model.form?.fields ?? []).filter { $0.section == section }
    }

    @ViewBuilder private func sectionView(_ section: String) -> some View {
        let found = fields(section)
        VStack(alignment: .leading, spacing: 10) {
            Text(found.first?.sectionName ?? section).font(.pmHeadline)
            Divider()
            let single = found.filter { $0.entry == nil }
            ForEach(single) { field in box(field) }
            let listed = found.filter { $0.entry != nil }
            if let first = listed.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section == "school" ? "Who picks up, in order" : "Leave when officials say to, or if")
                    ForEach(listed) { field in listRow(field, numbered: first.section == "school") }
                    if !first.hint.isEmpty {
                        Text(sentence(first.hint)).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    }
                }
            }
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { model.value(id) }, set: { model.set(id, $0) })
    }

    private func sentence(_ hint: String) -> String {
        guard let first = hint.first else { return "" }
        let text = first.uppercased() + hint.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    @ViewBuilder private func count(_ value: String, limit: Int) -> some View {
        let left = PaperCard.left(value, limit: limit)
        Text(left.words)
            .font(.pmNote.monospacedDigit())
            .fontWeight(left.over || left.near ? .semibold : .regular)
            .foregroundStyle(left.over ? PrepareMeColors.red : left.near ? PrepareMeColors.caution : PrepareMeColors.text2)
    }

    @ViewBuilder private func problemLine(_ id: String) -> some View {
        if let problem = model.problem(id) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PrepareMeColors.redMark)
                (Text(PrintableWords.wontPrint).bold() + Text(problem.message + "."))
                    .foregroundStyle(PrepareMeColors.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ id: String) -> some View {
        TextField("", text: binding(id), prompt: Text(PrintableWords.blank))
            .textFieldStyle(.plain)
            .pmBox()  // the typed box's one outline
            .focused($focused, equals: id)
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control)
                .stroke(PrepareMeColors.redMark, lineWidth: model.problem(id) == nil ? 0 : 2))
    }

    private func box(_ field: PaperCard.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.name)
                Spacer()
                count(model.value(field.id), limit: field.limit)
            }
            self.field(field.id)
            problemLine(field.id)
            HStack(alignment: .firstTextBaseline) {
                Text(sentence(field.hint)).foregroundStyle(PrepareMeColors.text2)
                Spacer()
                if focused == field.id, model.printsIn > 1 {
                    Text(PrintableWords.printsIn(model.printsIn)).foregroundStyle(PrepareMeColors.info)
                }
            }
            .font(.pmNote)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listRow(_ field: PaperCard.Field, numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(numbered ? "\(field.entry ?? 0)" : "•").foregroundStyle(PrepareMeColors.text2)
                    .frame(width: 16, alignment: .trailing)
                self.field(field.id)
                count(model.value(field.id), limit: field.limit).frame(width: 70, alignment: .trailing)
            }
            problemLine(field.id)
        }
    }

    private var numbersView: some View {
        let limits = model.form?.numberLimits ?? [:]
        let label = limits["label"] ?? 0, phone = limits["phone"] ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Phone numbers").font(.pmHeadline)
            Divider()
            Text("Up to \(model.form?.maxNumbers ?? 12), in the order they print. A label holds \(label) characters, a "
                 + "number \(phone).").font(.pmNote).foregroundStyle(PrepareMeColors.text2)
            ForEach(Array(model.numbers.indices), id: \.self) { row in
                let number = model.numbers[row]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(row + 1)").foregroundStyle(PrepareMeColors.text2).monospacedDigit()
                            .frame(width: 22, alignment: .trailing)
                        TextField("", text: Binding(get: { number.label },
                                                    set: { model.setNumber(row, label: $0) }),
                                  prompt: Text("Label"))
                            .textFieldStyle(.roundedBorder)
                        TextField("", text: Binding(get: { number.phone },
                                                    set: { model.setNumber(row, phone: $0) }),
                                  prompt: Text("Number"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                    problemLine("number.\(row + 1).label")
                    problemLine("number.\(row + 1).phone")
                }
            }
        }
    }
}

/// The live picture: the card's own page (cardtext's, with its margins and the outline) in WebKit, scaled to fit,
/// on white paper in both modes. No script runs and nothing is loaded: the page carries everything it draws.
struct PrintableCardPicture: NSViewRepresentable {
    let page: String

    /// Scales the page to its own width whenever that changes. Scaled only in updateNSView, a picture made again
    /// (back from the binder) took its zoom at zero width and kept it until a box changed (owner, 2026-10-27).
    final class Paper: WKWebView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            pageZoom = max(0.2, newSize.width / 816)  // 8.5 inches at 96 to the inch
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = Paper(frame: .zero, configuration: configuration)
        view.setAccessibilityLabel("The printed card")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != page else { return }
        context.coordinator.shown = page
        view.loadHTMLString(page, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: String?
    }
}

// MARK: - The binder

struct PrintableBinderView: View {
    @ObservedObject private var model = PrintableReferencesModel.shared

    /// The record's YYYY-MM-DD as "October 21, 2026", read on this Mac's calendar.
    static func longDate(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        return date.formatted(date: .long, time: .omitted)
    }

    var body: some View {
        let binder = model.status?.binder
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 12) {
                if let binder {
                    summary(binder)
                } else {
                    Text(model.jobInstalled ? "Asking the print job for the binder's list…"
                         : "The binder's list comes from the print job.").foregroundStyle(PrepareMeColors.text2)
                }
                Text(PrintableWords.pdfButton).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 470, alignment: .leading)
            if let sections = binder?.sections {
                contents(sections, guides: binder?.guides ?? 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func summary(_ binder: PaperStatus.Binder) -> some View {
        ForEach(binder.problems, id: \.self) { problem in
            PrintableCallout(line: .init(words: problem, kind: .danger))
        }
        let changed = binder.changed ?? [], new = binder.new ?? [], removed = binder.removed ?? []
        if let printed = binder.printed {
            Text("Since the binder printed").font(.pmHeadline)
            if changed.isEmpty, new.isEmpty, removed.isEmpty {
                Text("Nothing has changed since it printed on \(Self.longDate(printed)): \(binder.guides ?? 0) guides, "
                     + "\(binder.sheets) sheets.")
            } else {
                if !changed.isEmpty {
                    PrintableCallout(line: .init(words: "Changed (\(changed.count)).", kind: .caution,
                                                 more: ["Their words were rewritten or checked again, so the printed "
                                                        + "sheets are out of date:"] + changed.map { "• " + $0 }))
                }
                if !new.isEmpty {
                    PrintableCallout(line: .init(words: "New on the list (\(new.count)):", kind: .caution,
                                                 more: new.map { "• " + $0 }))
                }
                if !removed.isEmpty {
                    Text("Off the list: " + removed.joined(separator: "; ") + ". Take their sheets out.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Print what changed makes a first page that says which sheets to take out, by the version "
                     + "printed at their foot, and which to put in. Then come only the new sheets.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Print the whole binder prints every guide again: \(binder.guides ?? 0) guides, about "
                 + "\(binder.sheets) sheets, one-sided, for a three-hole binder.")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Not printed yet").font(.pmHeadline)
            Text("Print the whole binder prints all \(binder.guides ?? 0) guides, one-sided, for a three-hole binder. "
                 + "After that, Print what changed prints only the guides that change.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The list in two columns, sections kept whole, the first column taking sections until it holds half the guides.
    private func contents(_ sections: [PaperStatus.Binder.Section], guides: Int) -> some View {
        let numbered = numbering(sections)
        var split = sections.count, count = 0
        for (index, section) in sections.enumerated() {
            if count >= (guides + 1) / 2 { split = index; break }
            count += section.guides.count
        }
        let columns = [Array(sections.indices.prefix(split)), Array(sections.indices.dropFirst(split))]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("In the binder").font(.pmHeadline)
                    Text("\(guides) guides, in this order").foregroundStyle(PrepareMeColors.text2)
                }
                HStack(alignment: .top, spacing: 28) {
                    ForEach(columns.indices, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(columns[column], id: \.self) { index in
                                sectionList(sections[index], first: numbered[index])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionList(_ section: PaperStatus.Binder.Section, first: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.name).font(.pmHeadline).foregroundStyle(PrepareMeColors.text2)
            ForEach(Array(section.guides.enumerated()), id: \.offset) { at, guide in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(first + at)").monospacedDigit().foregroundStyle(PrepareMeColors.text2)
                        .frame(width: 26, alignment: .trailing)
                    Text(guide.title).fontWeight(guide.state.isEmpty ? .regular : .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !guide.state.isEmpty {
                        Text(guide.state).font(.pmNote.weight(.semibold))
                            .foregroundStyle(PrepareMeColors.caution)
                            .padding(.horizontal, 5)
                            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control).stroke(PrepareMeColors.accent))
                    }
                }
            }
        }
    }

    /// Each section's first guide's number, counting on from the last section.
    private func numbering(_ sections: [PaperStatus.Binder.Section]) -> [Int] {
        var next = 1
        return sections.map { section in
            defer { next += section.guides.count }
            return next
        }
    }
}
#endif
