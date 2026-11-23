// This file is part of PrepareMe, a local build of Kiwix for one household's Mac (build plan phase 9).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import ImageIO
import PrepareMeShared
import SwiftUI

// The printed street map's pages, on the Mac (Print household map) and the phone (Save as PDF, the street map fixes
// plan, task 4.2): moved here from PrepareMeStreetMapMac.swift unchanged but for the picture, a CGImage on both.

/// The household map's pages: the map, then the close-up, then the legend's overflow.
enum HouseholdMap {
    static let page = CGSize(width: 792, height: 612)  // US Letter, landscape, in points
    /// The legend's room beside the whole map, and in each of a legend page's two columns, in points: entries are
    /// fitted by their own height (`height`), so a long note is never cut short (a stress test, 2026-10-14).
    static let besideMap: Double = 430
    static let perColumn: Double = 500

    /// About how tall an entry prints: its name (two lines when long), role, note at 9 points (`perLine` characters a
    /// line: about 40 beside the map, 70 in a legend page's column) and place.
    static func height(_ mark: MapMark, perLine: Double) -> Double {
        let noteLines = mark.note.isEmpty ? 0 : (Double(mark.note.count) / perLine).rounded(.up)
        let nameLines = (Double(mark.name.count) / (perLine * 0.8)).rounded(.up)
        return nameLines * 16 + (mark.role == nil && mark.routeRole == nil ? 0 : 12) + noteLines * 12 + (mark.kind != .route ? 22 : 0) + 6
    }

    /// The entries, in order, cut into runs that each fit `room`; never an empty run.
    static func fitted(_ marks: [MapMark], room: Double, perLine: Double) -> (first: [MapMark], rest: [MapMark]) {
        var used = 0.0, count = 0
        for mark in marks {
            used += height(mark, perLine: perLine)
            if used > room, count > 0 { break }
            count += 1
        }
        return (Array(marks.prefix(count)), Array(marks.dropFirst(count)))
    }

    struct Sheet {
        let picture: CGImage
        let bounds: [Double]  // west, south, east, north: the whole picture
        var title: String

        /// From the page's PNG (StreetMapController.snapshot); nil when it isn't one.
        init?(png: Data, bounds: [Double], title: String) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            (self.picture, self.bounds, self.title) = (picture, bounds, title)
        }
    }

    @MainActor
    /// `numbered`: every mark the picture's circles were numbered from, when the legend lists only some (the phone's
    /// view: the W9 review); the legend's numbers must match the circles'.
    static func pdf(whole: Sheet, close: Sheet?, marks: [MapMark], numbered: [MapMark]? = nil,
                    made: Date = Date()) -> Data {
        let (first, overflow) = fitted(Position.ordered(marks), room: besideMap, perLine: 40)
        let numbers = Position.rallyNumbers(numbered ?? marks)  // as the map's circles show them (Task 11.6; F29)
        var pages: [AnyView] = [AnyView(HouseholdMapPage(sheet: whole, marks: first, more: overflow.count, made: made,
                                                         numbers: numbers))]
        if let close { pages.append(AnyView(HouseholdMapPage(sheet: close, marks: [], more: 0, made: made))) }
        var rest = overflow
        while !rest.isEmpty {
            let left = fitted(rest, room: perColumn, perLine: 70), right = fitted(left.rest, room: perColumn, perLine: 70)
            pages.append(AnyView(HouseholdLegendPage(columns: [left.first, right.first], numbers: numbers)))
            rest = right.rest
        }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for view in pages {
            let renderer = ImageRenderer(content: view.frame(width: page.width, height: page.height))
            context.beginPDFPage(nil)
            renderer.render { _, draw in draw(context) }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The grid's spacing for an area this many meters across: 1 km for a town, 10 km for a county or two.
    static func step(across meters: Double) -> Int {
        meters < 12_000 ? 1000 : meters < 120_000 ? 10_000 : 100_000
    }
}

// print sizes: from here (the printed household map keeps its print sizes and colors; PaletteTests skips it)

/// One entry of the legend: name, role, note and, for a rally point, its place, after the number its circle on the
/// map shows (Task 11.6; F29).
struct HouseholdLegendEntry: View {
    let mark: MapMark
    var number: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let number {
                HStack(spacing: 5) {
                    Text("\(number)").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    Text(mark.name)
                }
                .font(.system(size: 11, weight: .semibold))
            } else {
                Label(mark.name, systemImage: mark.symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            if let role = mark.role { Text(role.words).font(.system(size: 9, weight: .medium)) }
            if let role = mark.routeRole { Text(role.words).font(.system(size: 9, weight: .medium)) }
            if !mark.note.isEmpty { Text(mark.note).font(.system(size: 9)).fixedSize(horizontal: false, vertical: true) }
            if mark.kind != .route, let p = mark.points.first, p.count == 2 {
                Text(Position.latLon(p[1], p[0])).font(.system(size: 8).monospacedDigit())
                if let grid = Position.usng(p[1], p[0]) {
                    Text("USNG \(grid)").font(.system(size: 8).monospacedDigit())
                }
            }
        }
    }
}

struct HouseholdMapPage: View {
    let sheet: HouseholdMap.Sheet
    let marks: [MapMark]
    let more: Int  // legend entries on the pages after
    let made: Date
    var numbers: [Int64: Int] = [:]

    var body: some View {
        let size = fitted(CGSize(width: sheet.picture.width, height: sheet.picture.height),
                          into: CGSize(width: 520, height: 556))
        let across = Position.meters(from: ((sheet.bounds[1] + sheet.bounds[3]) / 2, sheet.bounds[0]),
                                     to: ((sheet.bounds[1] + sheet.bounds[3]) / 2, sheet.bounds[2]))
        let grid = Position.grid(west: sheet.bounds[0], south: sheet.bounds[1], east: sheet.bounds[2],
                                 north: sheet.bounds[3], step: HouseholdMap.step(across: across))
        HStack(alignment: .top, spacing: 16) {
            Image(decorative: sheet.picture, scale: 1).resizable().frame(width: size.width, height: size.height)
                .overlay { HouseholdGrid(lines: grid.lines, bounds: sheet.bounds) }
                .overlay(alignment: .bottomLeading) { HouseholdScale(metersAcross: across, width: size.width) }
                .overlay(alignment: .bottomTrailing) {
                    Text(StreetMap.attribution).font(.system(size: 7)).padding(3).background(.white.opacity(0.8))
                }
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(sheet.title).font(.system(size: 20, weight: .bold))
                Text("Printed \(made.formatted(date: .abbreviated, time: .omitted)). North is up.")
                    .font(.system(size: 9)).foregroundStyle(PrepareMeColors.text2)
                Text("Blue lines: US National Grid, zone \(grid.zone), \(HouseholdMap.step(across: across) / 1000) km "
                     + "apart; the numbers are kilometers. Read right, then up.")
                    .font(.system(size: 8)).foregroundStyle(PrepareMeColors.text2)
                Divider()
                ForEach(marks) { HouseholdLegendEntry(mark: $0, number: numbers[$0.id]) }
                if more > 0 {
                    Text("\(more) more on the pages after.").font(.system(size: 9, weight: .medium))
                }
                Spacer(minLength: 0)
                Text("Meeting places are the numbered circles, numbered as listed \(marks.isEmpty ? "on the first page" : "here"); "
                     + "routes are lines edged in black.")
                    .font(.system(size: 8))
                    .foregroundStyle(PrepareMeColors.text2)
            }
        }
        .padding(28)
        .foregroundStyle(.black)
        .background(.white)
    }

    func fitted(_ picture: CGSize, into box: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0 else { return box }
        let scale = min(box.width / picture.width, box.height / picture.height)
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }
}

/// The legend's overflow: two columns a page, each filled to its room.
struct HouseholdLegendPage: View {
    let columns: [[MapMark]]
    var numbers: [Int64: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Household map: more meeting places and routes").font(.system(size: 16, weight: .bold))
            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(column) { HouseholdLegendEntry(mark: $0, number: numbers[$0.id]) }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .foregroundStyle(.black)
        .background(.white)
    }
}

/// The grid's lines over the picture: web Mercator, as the map is drawn, from the picture's own area.
struct HouseholdGrid: View {
    let lines: [Position.GridLine]
    let bounds: [Double]

    var body: some View {
        Canvas { context, size in
            func y(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
            let (top, bottom) = (y(bounds[3]), y(bounds[1]))
            func point(_ p: [Double]) -> CGPoint {
                CGPoint(x: (p[0] - bounds[0]) / (bounds[2] - bounds[0]) * size.width,
                        y: (top - y(p[1])) / (top - bottom) * size.height)
            }
            let blue = Color(red: 0.1, green: 0.44, blue: 0.76)
            for line in lines {
                var path = Path()
                path.addLines(line.points.map(point))
                context.stroke(path, with: .color(blue.opacity(0.7)), lineWidth: 0.6)
                let label = Text(line.label).font(.system(size: 7, weight: .semibold)).foregroundColor(blue)
                if line.easting, let end = line.points.max(by: { $0[1] < $1[1] }) {
                    context.draw(label, at: CGPoint(x: point(end).x + 2, y: 6), anchor: .leading)
                } else if !line.easting, let end = line.points.min(by: { $0[0] < $1[0] }) {
                    context.draw(label, at: CGPoint(x: 3, y: point(end).y - 5), anchor: .leading)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A scale bar in miles, with its length in kilometers.
struct HouseholdScale: View {
    let metersAcross: Double
    let width: Double

    var body: some View {
        let miles = Position.scaleMiles(fitting: metersAcross / 4)
        let length = miles * 1609.344 / metersAcross * width
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(.black).frame(width: length, height: 3)
            Text(String(format: miles < 1 ? "%.2g mi (%.2g km)" : "%.0f mi (%.1f km)", miles, miles * 1.609344))
                .font(.system(size: 8, weight: .semibold))
        }
        .padding(4)
        .background(.white.opacity(0.85))
        .padding(6)
    }
}

// print sizes: to here
