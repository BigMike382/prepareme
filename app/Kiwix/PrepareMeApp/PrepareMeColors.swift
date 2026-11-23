import PrepareMeShared
import SwiftUI

/// The pages' colors and type on the app's own screens (the Today redesign's phase 5, ruling 12; design note
/// section 12). Colors come only from `Palette`, BASE's tokens, by the pages' meanings: the tint and links are
/// PrepareMe's teal (look 3; they had been ink, A9), red is danger or needs action, amber caution or worth a look, blue a key fact, green fine, and nothing is
/// colored for decoration. A "couldn't" or "refused" message is secondary text. `PaletteTests` holds the values to
/// front_style.py and fails on a system color or text under 15 points in a screen file. The one color set outside it
/// is the red night screen's pure red layer (PrepareMeRedNight.swift; CLAUDE.md's dated exception, phase D).
enum PrepareMeColors {
    static let ink = color(Palette.text)
    /// Grey reading text: BASE's darker `text2`, which passes contrast where the system grey didn't (remaining-findings
    /// plan, Task 9.2; F63; owner, 2026-10-18, by click). Every app screen's grey line uses it, never `.secondary`.
    static let text2 = color(Palette.text2, more: Palette.moreContrast("text2"))
    static let red = color(Palette.red)  // words
    static let redMark = color(Palette.redMark)  // symbols and edges
    static let caution = color(Palette.caution)  // words
    static let accent = color(Palette.accent)  // symbols and edges
    static let accentBg = color(Palette.accentBg)  // a worth-a-look box's ground
    static let redBg = color(Palette.redBg)  // a danger box's ground
    static let okMark = color(Palette.okMark)
    static let okBg = color(Palette.okBg)  // a fine box's ground: the item forms' "Nothing missing" line
    static let info = color(Palette.info)
    static let infoMark = color(Palette.infoMark)
    static let edge = color(Palette.edge, more: Palette.moreContrast("edge"))
    static let fill = color(Palette.fill)
    static let panel = color(Palette.panel)
    static let onFill = color(Palette.onFill)
    static let ground = color(Palette.bg)  // the pages' neutral ground: an entry screen's pick button
    static let line = color(Palette.line, more: Palette.moreContrast("line"))  // a rule or a typed box's outline
    static let infoBg = color(Palette.infoBg)  // a key fact's box: the whole package's calories
    // Look 3 (spec section 3): PrepareMe's teal marks what you can press and where you are, never a status
    static let teal = color(Palette.link)  // words, links and icons
    static let tealFill = color(Palette.idFill)  // a filled button
    static let onTeal = color(Palette.onId)  // the words on a teal fill
    static let tealTint = color(Palette.idTint)  // the row or tab you're on
    static let tile = color(Palette.miss)  // a chip's or a bar's ground (spec section 3's Tile)
    static let band = color(Palette.band)  // the band at a screen's top
    static let bandText = color(Palette.bandText)
    static let eventBand = color(Palette.ev)  // the band when something needs action
    static let eventBandText = color(Palette.evText)
    /// A player's chip (players plan, stage 2): the players' own few colors (`PlayerColor`), apart from the pages'
    /// meanings and always under the player's letter, and the letter's color on them.
    static func player(_ choice: PlayerColor) -> Color { color(choice.pair) }
    static let onPlayer = color(PlayerColor.onChip)

    /// A token's light and dark; with Increase Contrast on, `more`'s instead, as the pages do (the Apple guidelines
    /// plan, phase 4).
    static func color(_ pair: Palette.Pair, more: Palette.Pair? = nil) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let use = traits.accessibilityContrast == .high ? more ?? pair : pair
            return traits.userInterfaceStyle == .dark ? ui(use.dark) : ui(use.light)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            let high = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            let use = high ? more ?? pair : pair
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            return dark ? ns(use.dark) : ns(use.light)
        })
        #endif
    }

    /// A BASE token's light value in both modes, as the map draws its marks (a pin's dot under its white symbol).
    static func mapMark(_ token: String) -> Color {
        let hex = Palette.tokens[token]?.light ?? Palette.accent.light
        #if os(iOS)
        return Color(uiColor: ui(hex))
        #else
        return Color(nsColor: ns(hex))
        #endif
    }

    private static func parts(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255)
    }
    #if os(iOS)
    private static func ui(_ hex: UInt32) -> UIColor {
        let (r, g, b) = parts(hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
    #else
    private static func ns(_ hex: UInt32) -> NSColor {
        let (r, g, b) = parts(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    #endif
}

/// Nothing on a phone screen under 15 points (ruling 12): the text styles from `.subheadline` up are 15 or larger and
/// grow with the phone's text size. On the Mac, PrepareMe's own windows use the Mac's own text styles, ordinary text
/// at 13 points like every Mac app (owner, 2026-10-22, by click, the Apple guidelines plan's phase 3; it had been 15
/// since 2026-10-15). The printed sheets keep their print sizes.
extension Font {
    /// Ages, hints, notes and messages: the pages' 15 px floor on the phone, the Mac's body size on the Mac.
    static var pmNote: Font {
        #if os(iOS)
        .subheadline
        #else
        .body
        #endif
    }

    /// A row's or a section's heading.
    static var pmHeadline: Font {
        .headline
    }

    /// Ordinary text, set once at each of PrepareMe's own roots on the Mac.
    static var pmBody: Font {
        .body
    }

    // Look 3 (spec section 2): titles in the book typeface already on every Apple device (New York), numbers in the
    // rounded one (SF Rounded), each through a text style so it grows with the text size; no font is shipped.

    /// A screen's or a section's title.
    static var pmTitle: Font {
        .system(.title2, design: .serif).weight(.semibold)
    }

    /// A screen's big title.
    static var pmLargeTitle: Font {
        .system(.largeTitle, design: .serif).weight(.semibold)
    }

    /// Words or a number typed into a large box (a name, a quantity): the size those boxes had before look 3.
    static var pmEntry: Font {
        .title3
    }

    /// A count's or a number tile's number.
    static var pmCount: Font {
        .system(.title, design: .rounded).weight(.bold)
    }

    /// A step's number on its teal circle (the household page editor's step cards; look 3, plan Task 6.2).
    static var pmStepNumber: Font {
        .system(.headline, design: .rounded).weight(.bold)
    }

    /// The place number read out from "I'm lost" (spec section 8, fix 1): the size it had, through a text style so it
    /// grows with the text, each digit its own width.
    static var pmPlaceNumber: Font {
        .system(.largeTitle, design: .monospaced).weight(.bold)
    }
}

/// The corners (owner, 2026-10-22, by click: one box and corner style, as the pages': 12 px buttons, 14 px panels).
enum PrepareMeCorners {
    static let control: CGFloat = 12  // a button, a typed box, a pick
    static let panel: CGFloat = 14  // a notice, a card, a key fact's box
}

/// An app screen's list or form on the pages' ground, its rows on the pages' panel (owner, 2026-10-22, by click: the
/// app's own screens match the pages; Apple's own had left them a lighter grey, and black in dark mode). Every list
/// and form in a screen file is one of these (`PaletteTests`); a Mac sidebar (`List(selection:)`) keeps the Mac's own.
struct PMList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        List { Group(content: content).listRowBackground(PrepareMeColors.panel) }.pmScreen()
    }
}

/// A whole page drawn on the pages' ground as one bare row of the system's list, on the phone (Library matches Guides
/// plan, phase 2): a list, not a ScrollView, because the search bar over a reading tab tracks a list and stays drawn in
/// at its top; over a ScrollView it hid itself on the iPad and lost its words at the largest text.
#if os(iOS)
struct PMPageRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        List {
            content().listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .listStyle(.plain).pmScreen()
    }
}
#endif

/// A row drawn as the guide list's groups are (owner, 2026-10-25, by click: Inventory looks like Guides): a section of
/// its own, so each is a panel apart, `.listSectionSpacing(12)` (the guide list's gap) on the screen's list. The panel
/// keeps the system's corners: iOS 26 clips a list's rows to its own, rounder than the pages' 14 points, so a card
/// drawn inside one lost its corners and outline (2026-10-26). `title`: the heading over a run of cards, on its first.
struct PMCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            content()
        } header: {
            if let title { Text(title).foregroundStyle(PrepareMeColors.text2) }  // as Section(pmTitle:) on the phone
        }
    }
}

/// A card that opens a screen: its emoji and bold name (PMCardLabel), the arrow at its end.
struct PMCardLink<Destination: View>: View {
    let emoji: String
    let title: String
    var note = ""
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) { PMCardLabel(emoji: emoji, title: title, note: note) }
    }
}

/// A card's words, as a guide list group's: the emoji in a box of its own so the words line up, hidden from VoiceOver
/// as every emoji beside its words is, then the name in bold, and an optional grey line under it.
struct PMCardLabel: View {
    let emoji: String
    let title: String
    var note = ""
    @ScaledMetric private var box: CGFloat = 26  // the pages' 1.5em at 17 points

    var body: some View {
        HStack(spacing: 8) {
            Text(emoji).frame(width: box).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                if !note.isEmpty { Text(note).font(.pmNote).foregroundStyle(PrepareMeColors.text2) }
            }
        }
    }
}

struct PMForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form { Group(content: content).listRowBackground(PrepareMeColors.panel) }.pmScreen()
    }
}

extension View {
    /// The small top-bar title the page tabs use, on every phone screen (owner, 2026-10-22, by click: no title jumping
    /// in size from Today to Inventory); the Mac's window titles are its own.
    @ViewBuilder func pmTitleSmall() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// The pages' ground behind a screen that isn't a list: the welcome, a sheet, a bar.
    func pmScreen() -> some View {
        scrollContentBackground(.hidden).background(PrepareMeColors.ground)
    }
}

/// A titled section whose title reads at the headline size: the Mac draws a section's title at its own small size
/// (11 points in a sidebar) whatever the window's font, so PrepareMe's Mac screens title their sections through this;
/// on both, in the darker grey that passes contrast (Task 9.2), so the phone's sections are titled through it too.
extension Section where Parent == Text, Footer == EmptyView, Content: View {
    init(pmTitle: String, @ViewBuilder content: () -> Content) {
        #if os(iOS)  // the phone's own header size, in the darker grey (Task 9.2; F63)
        self.init(content: content, header: { Text(pmTitle).foregroundStyle(PrepareMeColors.text2) })
        #else
        self.init(content: content, header: { Text(pmTitle).font(.pmHeadline).foregroundStyle(PrepareMeColors.text2) })
        #endif
    }

    #if os(macOS)
    /// The same, folding (the sidebar's Other Libraries).
    init(pmTitle: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(isExpanded: isExpanded, content: content,
                  header: { Text(pmTitle).font(.pmHeadline).foregroundStyle(PrepareMeColors.text2) })
    }
    #endif
}

#if os(macOS)
extension View {
    /// One of PrepareMe's own Mac screens: the Mac's own text and control sizes, and the app's tint.
    func pmMacWindow() -> some View { font(.pmBody).pmTint() }
}
#endif

/// The app's tint: PrepareMe's teal (look 3), and the ink while the red night screen is on, since red night keeps only
/// a color's red part and the dark teal's is dim, 1.6:1 on black (look 3 phase 0, question 4); the pages do the same
/// (BASE's `html[data-pm-red]` line).
private struct PMTint: ViewModifier {
    @ObservedObject private var redNight = PrepareMeRedNight.shared

    func body(content: Content) -> some View { content.tint(redNight.on ? PrepareMeColors.ink : PrepareMeColors.teal) }
}

extension View {
    /// Every tint in the app goes through this, never `.tint(PrepareMeColors.teal)`, so red night reaches it.
    func pmTint() -> some View { modifier(PMTint()) }
}

/// A menu's destroying item, red and last (docs/design/menus.md, rule 3). The phone colors `role: .destructive`'s
/// words itself, but its icon takes the screen's tint (PrepareMe's teal: the owner saw a blue trash can beside a red
/// Delete…, 2026-11-14), so the tint is let go there and the icon goes the system's red with the words. macOS colors no
/// menu item for the role (checked on the macOS 27.2 SDK, 2026-11-14: the owner saw no red) but draws a label's own
/// color, so on the Mac the words carry the pages' red. The Mac's menus carry no icon (rule 6).
struct PMMenuDelete: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    #if os(macOS)
    @Environment(\.isEnabled) private var enabled
    #endif

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        #if os(macOS)
        Button(role: .destructive, action: action) {
            // a menu keeps a label's own color on a grayed-out item too, so only one that works is red
            if enabled { Text(title).foregroundStyle(PrepareMeColors.red) } else { Text(title) }
        }
        #else
        Group {
            if let systemImage {
                Button(title, systemImage: systemImage, role: .destructive, action: action)
            } else {
                Button(title, role: .destructive, action: action)
            }
        }
        .tint(nil)
        #endif
    }
}

private struct PMProminentLook: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).foregroundStyle(enabled ? PrepareMeColors.panel : PrepareMeColors.ink)
    }
}

/// The tint fills only what the ink can fill in both modes (owner, 2026-10-15, by click: in dark mode the ink is
/// near-white, and a switch, a checkbox or a filled button showed white on white).
extension View {
    /// A switch or a checkbox: the pages' green when on.
    func pmSwitch() -> some View { tint(PrepareMeColors.okMark) }

    /// A filled button: ink, with its words in the panel's color, so they read in both modes. Grayed out, its words are
    /// ink on the system's gray fill, which the system dims by a quarter: 7:1 and more in light and dark (the panel's
    /// color all but vanished there, and text2 dimmed came to 4.3:1 in light: the child's "I'm lost", map pins phase 4).
    func pmProminent() -> some View { modifier(PMProminentLook()) }

    /// An action: on the phone and iPad Apple's glass button, the row's width, its words centered (owner, 2026-10-22,
    /// by click from screenshots of three looks: the Apple guidelines plan, phase 5), and before iOS 26, which has no
    /// glass, the outlined box chosen 2026-10-18 (F41, F64); on the Mac its push button. Beside other words in a row (a
    /// Spacer between), `fullWidth: false` keeps it to its own width, so it never squeezes them.
    /// `compact`: the regular size, where a row of actions sits inside a card that must stay short (the street map's
    /// strip, the map pins plan); else large.
    func pmAction(fullWidth: Bool = true, compact: Bool = false) -> some View {
        #if os(iOS)
        modifier(PMActionLook(fullWidth: fullWidth, compact: compact))
        #else
        buttonStyle(.bordered)
        #endif
    }

    /// `pmAction` for a Menu's label: a Menu ignores the custom button style, so on iOS 26 it takes the glass button
    /// itself (verified beside a Button on the simulator, 2026-11-12); before 26, the same outlined box.
    @ViewBuilder func pmMenuAction() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            menuStyle(.button).buttonStyle(.glass).controlSize(.large).buttonSizing(.flexible)
                .font(.pmBody.weight(.semibold)).foregroundStyle(PrepareMeColors.ink)
        } else {
            menuStyle(.button).buttonStyle(PMActionStyle())
        }
        #else
        menuStyle(.button)
        #endif
    }

    /// A control floating over the street map: Apple's glass where the system has it (iOS and macOS 26), else the
    /// frosted material (the Apple guidelines plan, phase 10). Words and lists over the map keep the material.
    @ViewBuilder func pmGlass(in shape: some Shape) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// A row under the top bar or over the bottom edge: on iOS 26 in Apple's own bar, the page scrolling under its
    /// glass; before that on the painted bar (the Apple guidelines plan, phase 10).
    @ViewBuilder func pmBar(_ edge: VerticalEdge, spacing: CGFloat? = nil,
                            @ViewBuilder content: () -> some View) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing) { content().background(.bar) }
        }
    }
}

#if os(iOS)
/// Apple's glass button where the system has it (iOS 26 and later), else the outlined box.
private struct PMActionLook: ViewModifier {
    let fullWidth: Bool
    var compact = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // a regular glass button measured about 34 points tall: its words take 32 so the whole is 44 (phase 2 review)
            content.buttonStyle(PMGlassStyle(minHeight: compact ? 44 - 12 : nil)).controlSize(compact ? .regular : .large).buttonSizing(fullWidth ? .flexible : .fitted)
                .font(.pmBody.weight(.semibold))
        } else {
            content.buttonStyle(PMActionStyle(fullWidth: fullWidth))
        }
    }
}

/// Apple's glass button, its words in ink, or the pages' red for a destructive one (the color roles: red is danger).
@available(iOS 26, *)
private struct PMGlassStyle: PrimitiveButtonStyle {
    var minHeight: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(minHeight: minHeight)
                .foregroundStyle(configuration.role == .destructive ? PrepareMeColors.red : PrepareMeColors.ink)
        }
        .buttonStyle(.glass)
    }
}

/// The phone's action box before iOS 26 (`pmAction`).
struct PMActionStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        configuration.label
            .font(.pmBody.weight(.semibold))
            .foregroundStyle(destructive ? PrepareMeColors.red : PrepareMeColors.ink)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44, alignment: .leading)
            .background(configuration.isPressed ? PrepareMeColors.color(Palette.miss) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(destructive ? PrepareMeColors.redMark : PrepareMeColors.edge,
                              lineWidth: contrast == .increased ? 3 : 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
#endif

/// The pages' filled "Life-safety" tag (owner, 2026-10-15, by click: it replaced the orange triangle and the small
/// red words), with the star of life the guide list's ★ stands for.
struct LifeSafetyTag: View {
    var body: some View {
        Label("Life-safety", systemImage: "staroflife.fill")
            .labelStyle(.titleAndIcon)
            .font(.pmNote.weight(.bold))
            .foregroundStyle(PrepareMeColors.onFill)
            .padding(.horizontal, 8)
            .background(PrepareMeColors.fill, in: Capsule())
            .fixedSize()
    }
}
