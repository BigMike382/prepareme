// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (Our Home plan, Task 4.3).
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

/// An Our Home page's paper card (board 24), printed from its right-click in Edit Our Home (the owner's click,
/// 2026-11-16), drawn here as Grab Sheets are: what it says is HomeCard's (PrepareMeShared, tested there), on one US
/// Letter sheet in print colors only (BASE's light tokens in either mode), the QR code drawn as squares so it prints
/// sharp. A page too long for the sheet is drawn smaller to fit, never cut or carried onto a second sheet.
enum HomeCardPrint {
    static let page = CGSize(width: 612, height: 792)

    @MainActor
    static func pdf(_ card: HomeCard, photos: URL?) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let renderer = ImageRenderer(content: HomeCardPage(card: card, photos: photos)
            .environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: page.width, height: nil)
        context.beginPDFPage(nil)
        renderer.render { size, draw in
            let scale = min(1, page.height / max(size.height, 1), page.width / max(size.width, 1))
            context.translateBy(x: (page.width - size.width * scale) / 2, y: page.height - size.height * scale)
            context.scaleBy(x: scale, y: scale)
            draw(context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @MainActor
    static func print(_ card: HomeCard, photos: URL?) {
        guard let document = PDFDocument(data: pdf(card, photos: photos)) else { return }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = page
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)?.run()
    }
}

struct HomeCardPage: View {
    let card: HomeCard
    let photos: URL?

    static func ink(_ token: String) -> Color { PrepareMeColors.mapMark(token) }

    /// Words with each blank left drawn as a blank (its question on a shaded ground), after `lead` in bold.
    static func words(_ parts: [HomeCard.Part], lead: String = "", leadColor: Color = ink("text")) -> AttributedString {
        var out = AttributedString(lead)
        out.inlinePresentationIntent = .stronglyEmphasized
        out.foregroundColor = leadColor
        for part in parts {
            var piece = AttributedString(part.text)
            if part.blank { piece.backgroundColor = ink("miss") }
            out += piece
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.home).font(.system(size: 12, weight: .bold)).foregroundStyle(Self.ink("text2"))
                    Text(card.title).font(.system(size: 28, weight: .bold, design: .serif))
                    if !card.unfinished.isEmpty {
                        Text(card.unfinished).font(.system(size: 12, weight: .bold)).foregroundStyle(Self.ink("caution"))
                    }
                    if !card.when.isEmpty {
                        Text(Self.words(card.when, lead: "\(HomePage.word("USE_WHEN")) ")).font(.system(size: 14))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)  // every line wraps whole, never cut with "…"
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    CardCode(modules: card.qr).fill(Self.ink("text")).frame(width: 112, height: 112)
                    Text(card.scan).font(.system(size: 10)).multilineTextAlignment(.center)
                        .foregroundStyle(Self.ink("text2")).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 130)
            }
            if !card.danger.isEmpty {
                Text(Self.words(card.danger, lead: "⚠️ \(HomePage.word("DANGER")): ", leadColor: Self.ink("red")))
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.ink("red-mark"), lineWidth: 3))
            }
            if !card.things.isEmpty {  // What you need's things, as their words (the editor plan, Task 1)
                Text("\(HomePage.word("NEED")): \(card.things.joined(separator: ", "))").font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(card.steps, id: \.number) { step in
                    StepRow(step: step, photos: photos).padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Self.ink("line")).frame(height: 1) }
                }
            }
            Text(card.foot).font(.system(size: 9)).foregroundStyle(Self.ink("text2")).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Self.ink("line")).frame(height: 1) }
        }
        .foregroundStyle(Self.ink("text"))
        .padding(.horizontal, 44).padding(.vertical, 40)
        .frame(width: HomeCardPrint.page.width, alignment: .topLeading)
        .background(Color.white)
    }

    struct StepRow: View {
        let step: HomeCard.Step
        let photos: URL?

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(step.number)").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Circle().fill(HomeCardPage.ink("text")))
                VStack(alignment: .leading, spacing: 4) {
                    if !step.danger.isEmpty {
                        Text(HomeCardPage.words(step.danger, lead: "⚠️ \(HomePage.word("DANGER")): ",
                                                leadColor: HomeCardPage.ink("red"))).font(.system(size: 12, weight: .semibold))
                    }
                    if !step.caution.isEmpty {
                        Text(HomeCardPage.words(step.caution, lead: "🟠 \(HomePage.word("CAUTION")): ",
                                                leadColor: HomeCardPage.ink("caution"))).font(.system(size: 12, weight: .semibold))
                    }
                    if !step.name.isEmpty {  // the screen's label
                        Text(step.name).font(.system(size: 13, weight: .bold, design: .rounded))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(HomeCardPage.ink("text"), lineWidth: 2))
                    }
                    Text(HomeCardPage.words(step.words)).font(.system(size: 14, weight: .semibold))
                    if !step.answer.isEmpty { Text(step.answer).font(.system(size: 13, weight: .bold)) }
                    ForEach(step.ticks, id: \.self) { tick in Text("☐ \(tick)").font(.system(size: 13)) }
                    if !step.call.isEmpty { Text("📞 \(step.call)").font(.system(size: 13, weight: .bold)) }
                    if !step.place.isEmpty { Text("📍 \(step.place)").font(.system(size: 13)) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // a fixed width: beside the words' greedy column a flexible photo is squeezed to nothing
                if !step.photo.isEmpty, let photos,
                   let source = CGImageSourceCreateWithURL(photos.appendingPathComponent(step.photo) as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 96, height: 96, alignment: .top)
                }
            }
        }
    }
}

/// The QR code's modules as squares, with a four-module quiet zone, filling the frame.
struct CardCode: Shape {
    let modules: [[Bool]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = CGFloat(modules.count + 8)
        guard !modules.isEmpty else { return path }
        let side = min(rect.width, rect.height) / n
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                path.addRect(CGRect(x: rect.minX + CGFloat(x + 4) * side, y: rect.minY + CGFloat(y + 4) * side,
                                    width: side, height: side))
            }
        }
        return path
    }
}
#endif
