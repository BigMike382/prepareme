import PrepareMeShared
import SwiftUI

/// Look 3's shared native pieces (spec docs/design/2026-11-11-look-3-design.md sections 4, 8 and 10; plan Task 1.4):
/// the band, the one look for an empty or failed screen, the amber warning row and the count tile. Screens take them
/// phase by phase; colors and type only through `PrepareMeColors` (`PaletteTests`), and the band never fixes its
/// height or cuts a line short, so it grows at large text sizes (`testTheBandNeverFixesItsHeight`).

/// Today's day: teal while nothing needs action, red while the page's Needs action or event block shows (section 3).
enum PMBandState { case calm, needsAction }

/// The band at a screen's top: its ground, the contour lines behind its content, its words in the band's text color.
/// It has no height of its own: its content sets it, and it grows as the text does. The lines are decoration, hidden
/// from VoiceOver; a red band always comes with the Needs action words, which its content carries (section 8).
struct PMBand<Content: View>: View {
    let state: PMBandState
    let content: Content

    init(state: PMBandState = .calm, @ViewBuilder content: () -> Content) {
        self.state = state
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(state == .calm ? PrepareMeColors.bandText : PrepareMeColors.eventBandText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background { PMBandGround(state: state).accessibilityHidden(true) }
    }

    /// The band set inside a page, as the guide list's (front_style's div.page-band): a panel's corners.
    func card() -> some View { clipShape(.rect(cornerRadius: PrepareMeCorners.panel)).modifier(PMBandCardRedNight()) }
}

/// Red night leaves the band card's teal near black, so it is ringed with the line, as the pages ring theirs
/// (front_style's `[data-pm-red] .page-band`).
private struct PMBandCardRedNight: ViewModifier {
    @ObservedObject private var redNight = PrepareMeRedNight.shared

    func body(content: Content) -> some View {
        content.overlay {
            if redNight.on {
                RoundedRectangle(cornerRadius: PrepareMeCorners.panel).strokeBorder(PrepareMeColors.line, lineWidth: 2)
                    .accessibilityHidden(true)
            }
        }
    }
}

#if os(iOS)
extension View {
    /// The band behind a tab's top bar (spec section 4; plan Task 4.1; phase 0, question 4, "drawn under the bar"):
    /// the band and its lines laid over the screen's top, behind the status bar, the bar's title and buttons, and any
    /// row the screen sets under the bar (Maps' switch), which sits on it; the bar's words and buttons in their light
    /// colors. It follows the bar's height, so it grows with the text and never fixes one of its own. Decoration only:
    /// no taps, hidden from VoiceOver.
    func pmBandBar() -> some View {
        overlay(alignment: .top) {
            GeometryReader { box in  // the screen sits under the bar: its top inset is the bar's height
                PMBandGround(state: .calm).frame(maxHeight: box.safeAreaInsets.top).offset(y: -box.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// A control sitting on the band (Maps' and Guides' switches): drawn as on a dark ground, so its words read.
    func pmOnBand() -> some View { environment(\.colorScheme, .dark) }
}
#endif

#if os(macOS)
extension View {
    /// The Mac's sidebar as the band (spec section 5; plan Task 6.1; phase 0, question 1, variant 1): its list's own
    /// ground hidden, the band and its lines behind it, the PrepareMe wordmark at its top, and the list drawn dark so
    /// its words and icons read on the teal in either mode. The picked row keeps the Mac's own highlight, its words
    /// already semibold (beyond color, section 8).
    func pmMacSidebar() -> some View {
        scrollContentBackground(.hidden)
            .environment(\.colorScheme, .dark)  // the list only: the band under it keeps the mode's own teal
            .safeAreaInset(edge: .top, spacing: 0) { PMWordmark() }
            .background { PMBandGround(state: .calm).ignoresSafeArea().accessibilityHidden(true) }
    }

    /// A Mac window's top as the band (plan Task 6.1): the toolbar takes the band as a flat color (it takes a color,
    /// not a drawing, so the lines stay in the sidebar: phase 0), and its title and buttons the dark look, so they read
    /// light on it in light mode too (drawn dark they measured 1.33:1). The window's content keeps the chosen mode.
    func pmMacBand() -> some View {
        toolbarBackground(PrepareMeColors.band, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .background(PMDarkTitlebar())
    }
}

/// The PrepareMe wordmark over the sidebar, in the book typeface, a heading to VoiceOver.
struct PMWordmark: View {
    var body: some View {
        Text("PrepareMe")
            .font(.pmTitle)
            .foregroundStyle(PrepareMeColors.bandText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Gives the window's title bar, which holds its toolbar, the dark look (`toolbarColorScheme` is ignored for a Mac
/// window's toolbar: phase 0). Only the title bar: the content under it keeps the light or dark the owner chose.
private struct PMDarkTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Finder: NSView {
        private var watching: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)  // also when the view leaves its window
            watching = []
            guard let window else { return }
            Self.darken(window)
            // full screen moves the toolbar into a title bar of its own: give that one the dark look too
            watching = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { if let window { Self.darken(window) } }
                }
            }
        }

        /// The close button's parent is the title bar view, the toolbar's own parent.
        static func darken(_ window: NSWindow) {
            window.standardWindowButton(.closeButton)?.superview?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
#endif

/// The band's ground and its contour lines.
private struct PMBandGround: View {
    let state: PMBandState

    var body: some View {
        ZStack {
            state == .calm ? PrepareMeColors.band : PrepareMeColors.eventBand
            PMContourLines().stroke(PrepareMeColors.bandText.opacity(0.12), lineWidth: 1.2)
        }
        .clipped()
    }
}

/// The contour rings (`Contour.rings`, the pages' own numbers) at their own size, the hill's middle toward the top
/// right as the pages place it (phase 0's band: the 640 by 500 box 90 points past the right edge, 120 above the top).
private struct PMContourLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = rect.maxX + 90 - Contour.width, dy = rect.minY - 120
        for ring in Contour.rings() {
            path.addLines(ring.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            path.closeSubpath()
        }
        return path
    }
}

/// One color rule for messages (section 10, rule 3): gray information, amber needs your attention, red damaged or
/// refused.
enum PMMessageKind {
    case info, attention, damaged

    var color: Color {
        switch self {
        case .info: PrepareMeColors.text2
        case .attention: PrepareMeColors.caution
        case .damaged: PrepareMeColors.red
        }
    }
}

/// The one look for "nothing here", "not set up" and "something's wrong" (section 10, rule 1): a symbol, a heading in
/// the book typeface, one line in its kind's color, and one button where there is a next step.
struct PMState: View {
    let symbol: String
    let heading: String
    let line: String
    var kind: PMMessageKind = .info
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.pmLargeTitle).foregroundStyle(kind.color).accessibilityHidden(true)
            Text(heading).font(.pmTitle).foregroundStyle(PrepareMeColors.ink).accessibilityAddTraits(.isHeader)
            if !line.isEmpty { Text(line).font(.pmBody).foregroundStyle(kind.color) }  // a one-sentence message: none
            if let action {
                Button(action.title, action: action.run).pmAction(fullWidth: false)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 480)
        .padding(24)
    }
}

/// A whole screen holding a `PMState` and what follows it (a second offer, a note, a warning row): centered when it
/// fits, scrolling when it doesn't, so at the largest text a button below the fold stays in reach (B3-02's rule).
struct PMStateScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { screen in
            ScrollView {
                VStack(spacing: 16, content: content)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: screen.size.height)
            }
        }
        .pmScreen()
    }
}

/// The one amber warning row (section 10, rule 4), for the Mac's bar and the phone's rows on Today: a warning sign,
/// the words in caution's color on the worth-a-look ground, and a button where there is a next step. `accessory`: a
/// row's own buttons, drawn as they are (the Mac bar's Show All and Open Settings, with their tooltips).
struct PMWarningRow<Accessory: View>: View {
    let words: String
    var action: (title: String, run: () -> Void)?
    /// The button under the words, for a long title ("Remove Wikipedia (4.2 GB)…", family downloads plan, phase 4)
    var below = false
    let accessory: Accessory

    init(_ words: String, action: (title: String, run: () -> Void)? = nil, below: Bool = false,
         @ViewBuilder accessory: () -> Accessory) {
        self.words = words
        self.action = action
        self.below = below
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrepareMeColors.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(words)
                    .foregroundStyle(PrepareMeColors.caution)
                    .fixedSize(horizontal: false, vertical: true)
                if below, let action {
                    Button(action.title, action: action.run).pmAction(fullWidth: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
            if !below, let action {
                Button(action.title, action: action.run).pmAction(fullWidth: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // a background reaches into the safe area by default: under the bar on Today it covered the band (2026-11-15)
        .background(PrepareMeColors.accentBg, ignoresSafeAreaEdges: .horizontal)
    }
}

extension PMWarningRow where Accessory == EmptyView {
    init(_ words: String, action: (title: String, run: () -> Void)? = nil, below: Bool = false) {
        self.init(words, action: action, below: below) { EmptyView() }
    }
}

/// A count: its number in the rounded typeface over its words, one VoiceOver stop read "words, count" (section 8:
/// "To buy, 3"). The words say what a color says (a low supply's word as well as its red); a count that opens
/// something is a button.
struct PMCount: View {
    let number: String
    let words: String
    var kind: PMMessageKind = .info
    var action: (() -> Void)?
    private var panel = false

    init(_ count: Int, _ words: String, kind: PMMessageKind = .info, action: (() -> Void)? = nil) {
        self.init(number: count.formatted(), words, kind: kind, action: action)
    }

    /// A number already in its words ("7" days, "–" not counted: `InventoryHome.chip`).
    init(number: String, _ words: String, kind: PMMessageKind = .info, action: (() -> Void)? = nil) {
        (self.number, self.words, self.kind, self.action) = (number, words, kind, action)
    }

    /// The count on a panel of its own (the Mac's strip), the panel inside its button so a click anywhere on it counts.
    func onPanel() -> PMCount {
        var count = self
        count.panel = true
        return count
    }

    var body: some View {
        if let action {
            Button(action: action) { tile }.buttonStyle(.plain)
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(number).font(.pmCount).foregroundStyle(kind == .info ? PrepareMeColors.ink : kind.color)
            Text(words).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
        // on a panel, as tall as the row's tallest count (Inventory's home page: fix round 1, finding 6)
        .frame(maxWidth: .infinity, maxHeight: panel ? .infinity : nil, alignment: .topLeading)
        .padding(panel ? 10 : 0)
        .background { if panel { RoundedRectangle(cornerRadius: PrepareMeCorners.panel).fill(PrepareMeColors.panel) } }
        .contentShape(Rectangle())  // a click on the tile's empty part counts too
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(words), \(number)")
    }
}

extension View {
    /// One place for Add on the phone (look 3 change 13): a labeled button over the bottom edge, in thumb reach, on
    /// Inventory, Documents, To Buy and To Do. `show` false (a search with words, a read-only phone) leaves the bar out.
    func pmAddBar(show: Bool = true, @ViewBuilder button: () -> some View) -> some View {
        pmBar(.bottom) {
            if show { button().padding(.horizontal).padding(.vertical, 8) }
        }
    }
}
