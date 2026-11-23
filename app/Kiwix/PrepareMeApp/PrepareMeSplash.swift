import PrepareMeShared
import SwiftUI

/// PrepareMe's opening screen (owner, 2026-11-12, by click: design A), in place of Kiwix's logo while the library opens
/// (`LoadingDataView`): the band's teal, its contour hill behind the icon, and the name. Everything is drawn as shapes
/// and the vector `PrepareMeMark` (make_icon.py), so it is sharp at any size and still. The mark and the name scale
/// with the window's shorter side, laid out as on a 390-point phone; the hill scales with the window so it covers a wide
/// Mac window as it covers the phone. iOS's own opening color (`PrepareMeLaunch`) is this teal, so one runs into the
/// other; with red night on, the red layer turns this screen dark like the rest of the app.
struct PrepareMeSplash: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = min(size.width, size.height) / 390
            let mark = 112 * scale, markTop = size.height / 2 - 92 * scale
            ZStack(alignment: .top) {
                PrepareMeColors.band
                SplashHill(middle: CGPoint(x: size.width / 2, y: markTop + mark / 2),
                           scale: max(size.width / 390, size.height / 844))
                    .stroke(PrepareMeColors.bandText.opacity(0.12), lineWidth: 1.2 * scale)
                VStack(spacing: 18 * scale) {
                    Image("PrepareMeMark").resizable().frame(width: mark, height: mark)
                    // fixed to the window, not the text size: the name is part of the picture
                    Text("PrepareMe").font(.system(size: 38 * scale, weight: .semibold, design: .serif))
                        .foregroundStyle(PrepareMeColors.bandText)
                }
                .padding(.top, markTop)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PrepareMe is opening")
    }
}

/// The band's contour rings (`Contour.rings`) around `middle`, smoother than the band's so they hold at Mac sizes.
private struct SplashHill: Shape {
    let middle: CGPoint
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for ring in Contour.rings(points: 144) {
            path.addLines(ring.map {
                CGPoint(x: middle.x + ($0.x - Contour.width / 2) * scale, y: middle.y + ($0.y - Contour.height / 2) * scale)
            })
            path.closeSubpath()
        }
        return path
    }
}

#Preview {
    PrepareMeSplash()
}
