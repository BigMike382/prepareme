import PrepareMeShared
import SwiftUI

/// The item entry screens' look (owner, 2026-10-22, by click: docs/plans/2026-10-22-item-entry-redesign.md), shared by
/// the phone's and the Mac's: a group's header with its symbol, a typed field as an outlined box, a pick from a list as
/// a button on the neutral ground, and the whole package's calories as the screen's one key fact, in blue.

extension View {
    /// An item name's first typed letter as a capital (owner, 2026-10-30; `PhoneEditRules.capitalFirst`): the Mac's
    /// keyboard adds none. `on` false leaves the box as typed.
    func capitalFirst(_ text: Binding<String>, _ on: Bool = true) -> some View {
        onChange(of: text.wrappedValue) { old, new in
            if on, let fixed = PhoneEditRules.capitalFirst(was: old, now: new) { text.wrappedValue = fixed }
        }
    }
}

/// A group of fields under its symbol and sentence-case title (`ItemFieldGroup`).
struct EntrySection<Content: View>: View {
    let group: ItemFieldGroup
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section(content: content, header: {
            Label(group.title, systemImage: group.symbol)
                .font(.pmHeadline).textCase(nil).foregroundStyle(PrepareMeColors.text2)
        })
    }
}

/// More details: its fields folded under the group's title, open by itself when any of them holds something.
struct EntryFold<Content: View>: View {
    @Binding var open: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            // the Mac: each row's box clear of its row's top, which cut off Model's top edge under the heading (owner,
            // 2026-10-30)
            DisclosureGroup(isExpanded: $open, content: {
                #if os(macOS)
                content().padding(.top, 4)
                #else
                content()
                #endif
            }) {
                Label(ItemFieldGroup.more.title, systemImage: ItemFieldGroup.more.symbol)
                    .font(.pmHeadline).foregroundStyle(PrepareMeColors.text2)
            }
        }
    }
}

extension View {
    /// A typed field: an outlined box, so it never looks like a pick.
    func pmBox() -> some View {
        padding(.horizontal, 8).padding(.vertical, 6)  // its row's own ground, so it reads the same in dark mode
            .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control).stroke(PrepareMeColors.edge.opacity(0.6)))
    }
}

/// The whole package's calories, the screen's one key fact in blue: its box large, what it's for, and how it was
/// reached ("About 2.4 servings of 60 calories, from USDA"). Typed over, the words under it go.
struct WholeCalories: View {
    @Binding var calories: String
    let how: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $calories)
                    .accessibilityLabel(Inventory.Label.caloriesEach)  // VoiceOver: not "0" (entry fixes, phase 4)
                    .font(.pmCount.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .pmBox()
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text(ProductLookup.wholeLabel.replacingOccurrences(of: "Calories, ", with: "calories, "))
                    .font(.pmBody)
            }
            if let how { Text(how).font(.pmNote) }
        }
        .foregroundStyle(PrepareMeColors.info)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PrepareMeColors.infoBg, in: RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
        .accessibilityElement(children: .contain)
    }
}

/// The item forms' what's-missing line (inventory fresh look, spec 5.3; `ItemNeeds`), above Add or Save: amber, in the
/// warning row's colors, naming the one field a supply's count still needs; green when nothing is missing. It never
/// stops Add or Save. The phone's form and the Mac's share it.
struct PMNeedsLine: View {
    let line: ItemNeeds.Line

    var body: some View {
        let (words, missing): (String, Bool) = switch line {
        case .missing(let words): (words, true)
        case .complete(let words): (words, false)
        }
        Label {
            Text(words).foregroundStyle(missing ? PrepareMeColors.caution : PrepareMeColors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: missing ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(missing ? PrepareMeColors.accent : PrepareMeColors.okMark)
        }
        .font(.pmNote.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(missing ? PrepareMeColors.accentBg : PrepareMeColors.okBg,
                    in: RoundedRectangle(cornerRadius: PrepareMeCorners.control))
        .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.control)
            .stroke(missing ? PrepareMeColors.accent : PrepareMeColors.okMark))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// VoiceOver hears the what's-missing line as its state changes (`ItemNeeds.announcement`), from the form, which
    /// sees it appear, not on each keystroke (phase 2 review, 6 and M3).
    func announcesNeeds(_ line: ItemNeeds.Line?) -> some View {
        onChange(of: line) { old, new in
            if let words = ItemNeeds.announcement(from: old, to: new) {
                AccessibilityNotification.Announcement(words).post()
            }
        }
    }
}
