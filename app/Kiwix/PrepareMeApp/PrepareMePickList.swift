import PrepareMeShared
import SwiftUI

#if PREPAREME_CHECK
@MainActor var pickListCheckOpened = false  // PREPAREME_CHECK_PICKLIST opens one list, once
#endif

/// A place or category pick on the Mac and the phone alike (entry fixes plan, Task 1.6; owner, 2026-10-23, by click):
/// its value in the pill, opening a searchable list of full paths A to Z, None at its top and, where the list allows,
/// New Place… or New Category… at its foot, which makes one and picks it.
struct PickListButton<NewForm: View>: View {
    let title: String
    let value: String
    let choices: [PickChoice]
    @Binding var picked: Int64
    var newTitle: String?
    /// The Mac's table cell (the inventory fresh look, spec 5.2): the list opens as the cell does, and `onClose` tells
    /// the cell it closed, picked or not, as the menu it replaced did.
    var startsOpen = false
    var onClose: (() -> Void)?
    @ViewBuilder var newForm: (_ done: @escaping (Int64) -> Void) -> NewForm
    @State private var open = false
    @State private var search = ""
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Button { search = ""; open = true } label: {
            HStack(spacing: 6) {
                // a long path whole at the large text sizes (spec section 8, fix 9)
                Text(value.isEmpty ? "None" : value).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(PrepareMeColors.edge)
            }
            .foregroundStyle(PrepareMeColors.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(PrepareMeColors.ground, in: Capsule())
            .overlay(Capsule().stroke(PrepareMeColors.line))
            #if os(iOS)
            .frame(minHeight: 44).contentShape(Rectangle())  // a 44-point tap around the pill
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value.isEmpty ? "None" : value)
        .onAppear { if startsOpen { search = ""; open = true } }
        .sheet(isPresented: $open, onDismiss: { onClose?() }) {
            NavigationStack {
                PMList {
                    row("None", selected: picked == 0) { picked = 0 }
                    ForEach(PickLists.filtered(choices, search: search)) { choice in
                        row(choice.title, selected: picked == choice.id) { picked = choice.id }
                    }
                    if let newTitle {
                        NavigationLink {
                            newForm { made in
                                picked = made
                                open = false
                            }
                        } label: {
                            Label(newTitle, systemImage: "plus").foregroundStyle(PrepareMeColors.ink)
                        }
                    }
                }
                .searchable(text: $search, prompt: "Search")
                .navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { open = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 480)
            #endif
        }
        #if PREPAREME_CHECK
        // the check build only (screenshots only, 2026-10-21): PREPAREME_CHECK_PICKLIST=<column label> opens that list once
        .task {
            guard ProcessInfo.processInfo.environment["PREPAREME_CHECK_PICKLIST"] == title, !pickListCheckOpened else { return }
            pickListCheckOpened = true
            try? await Task.sleep(for: .seconds(1))
            open = true
        }
        #endif
    }

    func row(_ text: String, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            open = false
        } label: {
            HStack {
                Text(text).foregroundStyle(PrepareMeColors.ink)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(PrepareMeColors.ink) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// New Place… (Task 1.6): its name, the place it's kept in (starting where the item is) and the Vehicle switch. The name
/// is checked here as the Mac's editor checks it (Task 1.3); `add` makes it and gives its number, or why it couldn't.
struct NewPlaceForm: View {
    let places: [PickChoice]
    let others: [(id: Int64, name: String, keptIn: Int64?)]
    @State var keptIn: Int64
    let add: (_ name: String, _ keptIn: Int64, _ vehicle: Bool) async -> (row: Int64?, why: String?)
    let done: (Int64) -> Void
    @State private var name = ""
    @State private var vehicle = false
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        PMForm {
            Section(pmTitle: "New place") {
                TextField("Name", text: $name)
                Picker("Kept in", selection: $keptIn) {
                    Text("None").tag(Int64(0))
                    ForEach(PickLists.filtered(places, search: "")) { Text($0.title).tag($0.id) }
                }
                Toggle("Vehicle", isOn: $vehicle).pmSwitch()
            }
            if let problem { Text(problem).foregroundStyle(PrepareMeColors.red) }
        }
        .navigationTitle("New Place")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
    }

    func save() async {
        if let why = PickLists.placeProblem(name: name, keptIn: keptIn, among: others) { problem = why; return }
        saving = true
        defer { saving = false }
        let made = await add(name.trimmingCharacters(in: .whitespacesAndNewlines), keptIn, vehicle)
        if let row = made.row { done(row) } else { problem = made.why }
    }
}

/// New Category… (Task 1.6): its name and its Counts as, which every category needs so its items count toward the
/// right supply (Task 1.3).
struct NewCategoryForm: View {
    let others: [String]
    let add: (_ name: String, _ countsAs: String) async -> (row: Int64?, why: String?)
    let done: (Int64) -> Void
    @State private var name = ""
    @State private var countsAs = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        PMForm {
            Section(pmTitle: "New category") {
                TextField("Name", text: $name)
                Picker("Counts as", selection: $countsAs) {
                    Text("Choose…").tag("")
                    ForEach(ToBuyList.groups, id: \.self) { Text(InventoryLook.title($0)).tag($0) }
                }
            }
            if let problem { Text(problem).foregroundStyle(PrepareMeColors.red) }
        }
        .navigationTitle("New Category")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || countsAs.isEmpty || saving)
            }
        }
    }

    func save() async {
        if let why = PickLists.categoryProblem(name: name, among: others) { problem = why; return }
        saving = true
        defer { saving = false }
        let made = await add(name.trimmingCharacters(in: .whitespacesAndNewlines), countsAs)
        if let row = made.row { done(row) } else { problem = made.why }
    }
}
