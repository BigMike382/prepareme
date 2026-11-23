// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 7, slice 6).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import AVFoundation
import PrepareMeShared
import SwiftUI
import VisionKit

/// Scan (build plan phase 7, slice 6), on the device, with no network: a bin label's QR code opens that bin; a
/// product's barcode opens the item it was linked to, or, on an adult's phone, offers to link it to an item or start a
/// new one with it. Codes are matched against the ones scanned before (the Mac's copy, and this phone's own waiting
/// links); there is no product lookup online.
struct ScanSheet: View {
    @ObservedObject private var model = PhoneInventoryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var found: Found?

    enum Found: Hashable {
        case place(Int64)
        case item(Int64)
        case unknown(String)
        case notACode
    }

    var body: some View {
        NavigationStack {
            Group {
                switch found {
                case nil:
                    if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                        CodeScanner { text in found = read(text) }.ignoresSafeArea()
                    } else {
                        CameraCantScan(words: StateWords.cantReadCodes)
                            .task { if let code = Self.checkCode { found = read(code) } }
                    }
                case .place(let id):
                    if let copy = model.shown, let place = copy.places.first(where: { $0.id == id }) {
                        PlaceContents(copy: copy, place: place)
                    } else if model.busy {
                        ProgressView("Getting the inventory from the Mac…").padding()
                    } else {
                        PMStateScreen {  // look 3's one look; the sentence says where to go (spec section 10)
                            PMState(symbol: "shippingbox", heading: StateWords.binNotInCopy(device: ThisDevice.word), line: "")
                        }
                    }
                case .item(let id):
                    ItemDetail(id: id)
                case .unknown(let code):
                    UnknownCode(code: code) { dismiss() }
                case .notACode:
                    VStack(spacing: 12) {
                        Text("That isn't a product's barcode or a PrepareMe bin label.").multilineTextAlignment(.center)
                        Button("Scan again") { found = nil }
                    }
                    .padding()
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    /// A session's simulator check only (no camera): PREPAREME_CHECK_SCAN_CODE=<digits> is read as if the camera saw
    /// it, so "A new item with this code" can be reached; nil on a device.
    static var checkCode: String? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["PREPAREME_CHECK_SCAN_CODE"]
        #else
        nil
        #endif
    }

    func read(_ text: String) -> Found {
        if let place = Barcode.place(in: text) {
            if model.shown?.places.contains(where: { $0.id == place }) != true { Task { await model.look() } }
            return .place(place)
        }
        guard let code = Barcode.valid(text) else { return .notACode }
        if let item = model.item(forCode: code) { return .item(item) }
        return .unknown(code)
    }
}

/// A bin opened from its label: what's in it and in anything kept in it.
struct PlaceContents: View {
    let copy: PhoneInventory
    let place: PhoneInventory.Place

    var body: some View {
        let inside = copy.within(place.id)
        let rows = copy.column("Location").map { column in
            copy.items.filter { ($0.values[column.colId]?.whole).map(inside.contains) ?? false }
        } ?? []
        PMList {
            if !place.label.isEmpty { Text(place.label).foregroundStyle(PrepareMeColors.text2) }
            if rows.isEmpty { Text("Nothing in it.").foregroundStyle(PrepareMeColors.text2) }
            ForEach(rows) { ItemLink(copy: copy, row: $0) }
        }
        .navigationTitle(InventoryLook.title(place.name))  // as Inventory titles a place (fix round 1)
        .pmTitleSmall()
    }
}

/// A code no item has yet: an adult's phone links it to an item, or starts a new item with it.
struct UnknownCode: View {
    let code: String
    let done: () -> Void
    @ObservedObject private var model = PhoneInventoryModel.shared
    @State private var search = ""

    var body: some View {
        PMList {
            Section {
                Text("No item has this code yet.")
                if !model.canEdit {
                    Text("Codes are linked on an adult's phone.").foregroundStyle(PrepareMeColors.text2)
                }
            }
            if model.canEdit, let copy = model.shown {
                Section {
                    NavigationLink("A new item with this code") { ItemForm(copy: copy, row: nil, barcode: code) }
                }
                Section(pmTitle: "Or link it to") {
                    ForEach(copy.items.filter { $0.id > 0 && matches($0, copy) }) { row in
                        Button(copy.shownName(row)) {
                            model.edit(.linkBarcode(code: code, row: row.id),
                                       what: "\(copy.shownName(row)): barcode")
                            done()
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Find the item")
    }

    func matches(_ row: PhoneInventory.Row, _ copy: PhoneInventory) -> Bool {
        search.isEmpty || copy.shownName(row).range(of: search, options: [.caseInsensitive]) != nil
    }
}

/// VisionKit's scanner for product barcodes and QR codes; it hands back the first code it reads.
struct CodeScanner: UIViewControllerRepresentable {
    /// Keep scanning, handing back each code as it comes into view (quick add): a code still in view after it was
    /// handled is never handed back again, only one taken out of view and brought back (review 2026-10-14).
    var continuous = false
    /// Stopped while another camera sheet is open over it (quick add's Read the date): one camera at a time.
    var paused = false
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr, .ean8, .ean13, .upce, .itf14])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        // only a pause this view made is undone: a one-code scanner stopped after its code stays stopped
        if paused, controller.isScanning {
            controller.stopScanning()
            context.coordinator.pausedHere = true
        } else if !paused, context.coordinator.pausedHere {
            context.coordinator.pausedHere = false
            try? controller.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(continuous: continuous, found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let continuous: Bool
        let found: (String) -> Void
        private var used = false
        var pausedHere = false

        init(continuous: Bool, found: @escaping (String) -> Void) {
            self.continuous = continuous
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                guard !used, let text = code.payloadStringValue else { continue }
                if !continuous {
                    used = true
                    scanner.stopScanning()
                }
                found(text)
            }
        }
    }
}

/// Read the date (plan 2026-10-28, phase 2): the camera reads the package's text on the device, `PackageDate` picks the
/// best-by date from it, and the date is kept only when Use this date (or one of a choice's dates) is tapped. Until
/// then it keeps reading; a date or choice once shown stays until Try again. No picture is kept.
struct DateReadSheet: View {
    let use: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reading = PackageDate.Reading.refused(PackageDate.nothingFound)

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.clear
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    TextScanner { lines in
                        if case .refused = reading { reading = PackageDate.read(lines) }  // a shown date stays put
                    }
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
                    card.padding(12)
                } else {
                    CameraCantScan(words: StateWords.cantReadDates).frame(maxHeight: .infinity)
                }
            }
            .background(PrepareMeColors.ground)
            .navigationTitle("Read the Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    @ViewBuilder var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch reading {
            case .refused(let sentence):
                Text(sentence)
            case .found(let found):
                Text(found.headline).font(.pmTitle)
                ForEach(found.notes, id: \.self) { Text($0).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
                Button(PackageDate.useThisDate) { pick(found.day) }.pmAction()
                Button(PackageDate.tryAgain) { again() }.frame(maxWidth: .infinity)
            case .choice(let first, let second, let question):
                Text(question).font(.pmHeadline)
                Button(first.words) { pick(first) }.pmAction()
                Button(second.words) { pick(second) }.pmAction()
                Button(PackageDate.tryAgain) { again() }.frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
    }

    func again() { reading = .refused(PackageDate.nothingFound) }

    /// That day on this phone's calendar at noon, as the item form's date picker holds a stored day.
    func pick(_ day: PackageDate.Day) {
        guard let date = Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                                      hour: 12)) else { return }
        use(date)
        dismiss()
    }
}

/// VisionKit's scanner reading text: each update hands back every line in view, top to bottom, so a "BEST BY"
/// printed above its date comes first (`PackageDate`'s rule 1).
struct TextScanner: UIViewControllerRepresentable {
    let lines: ([String]) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.text()], qualityLevel: .accurate,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(lines: lines) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let lines: ([String]) -> Void

        init(lines: @escaping ([String]) -> Void) { self.lines = lines }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) { hand(allItems) }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate items: [RecognizedItem],
                         allItems: [RecognizedItem]) { hand(allItems) }

        func hand(_ all: [RecognizedItem]) {
            let texts = all.compactMap { item -> (y: Double, x: Double, text: String)? in
                guard case .text(let text) = item else { return nil }
                return (item.bounds.topLeft.y, item.bounds.topLeft.x, text.transcript)
            }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            lines(texts.flatMap { $0.text.split(whereSeparator: \.isNewline).map(String.init) })
        }
    }
}
/// A camera that can't scan (look 3, spec section 10, rule 2): one turned off for PrepareMe says so, with the way to
/// Settings, apart from one that can't read codes here, which keeps its words; both in the one look for "something's
/// wrong" (PMState).
struct CameraCantScan: View {
    let words: String

    var body: some View {
        if StateWords.cameraIsOff(Self.camera) {
            PMState(symbol: "camera", heading: StateWords.cameraOff, line: StateWords.cameraTurnOn, kind: .attention,
                    action: (StateWords.openSettings, {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }))
        } else {
            PMState(symbol: "camera", heading: words, line: "")
        }
    }

    static var camera: StateWords.Camera {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        default: .notAsked
        }
    }
}
#endif
