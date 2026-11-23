// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac (Unlisted plan, phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import PrepareMeShared
import SwiftUI

/// What About must show a reviewer (Unlisted plan, phase 4; audit C5 and P2e): the standing notice, the two public
/// pages once they exist, and every part the app is built from with its license.
enum AboutCopy {
    /// Word for word as the guide list's (packer/build.py MEDICAL_NOTICE; PrepareMeAboutTests pins both)
    static let medicalNotice = "PrepareMe's guides are reference material, not medical advice. In an emergency, call 911."
    /// The public privacy page and the published source (Unlisted plan, phase 6; the owner confirmed both 2026-11-23). A
    /// row whose address is nil shows nothing at all, never a button that goes nowhere.
    static let privacyPage = URL(string: "https://bigmike382.github.io/prepareme/privacy.html")
    static let source = URL(string: "https://github.com/BigMike382/prepareme")
}

/// A part the app is built from: its name, its license, and the license's text where the app carries it (a path inside
/// the app: the street map's folder or meaning search's), else nil.
struct Acknowledgement: Identifiable, Equatable {
    let name: String
    let license: String
    let file: String?
    var id: String { name }

    /// The license text the app carries, read from inside the app; nil when it carries none or it can't be read.
    var text: String? {
        file.flatMap { Bundle.main.resourceURL?.appendingPathComponent($0) }.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Each license text the app carries is in its Licenses folder (app/Kiwix/PrepareMeApp/Licenses), from the
    /// project's own license file at the version built in; liblzma is public domain and has none.
    static let all: [Acknowledgement] = [
        .init(name: "Kiwix", license: "GNU GPL 3.0", file: "Licenses/GPL-3.0.txt"),
        .init(name: "libkiwix", license: "GNU GPL 3.0", file: "Licenses/GPL-3.0.txt"),
        .init(name: "libzim", license: "GNU GPL 2.0", file: "Licenses/libzim-GPL-2.0.txt"),
        .init(name: "Xapian", license: "GNU GPL 2.0", file: "Licenses/xapian-GPL-2.0.txt"),
        .init(name: "ICU", license: "Unicode License", file: "Licenses/icu-LICENSE.txt"),
        // libkiwix's own libraries, as built into Kiwix's CoreKiwix 14.2.1 (each license from its header there)
        .init(name: "curl", license: "curl License", file: "Licenses/curl-COPYING.txt"),
        .init(name: "libmicrohttpd", license: "GNU LGPL 2.1", file: "Licenses/libmicrohttpd-COPYING.txt"),
        .init(name: "zstd", license: "BSD 3-Clause", file: "Licenses/zstd-LICENSE.txt"),
        .init(name: "zlib", license: "zlib License", file: "Licenses/zlib-LICENSE.txt"),
        .init(name: "pugixml", license: "MIT", file: "Licenses/pugixml-LICENSE.txt"),
        .init(name: "Mustache (Kevin Wojniak)", license: "Boost Software License 1.0",
              file: "Licenses/mustache-LICENSE.txt"),
        .init(name: "liblzma", license: "Public domain", file: nil),
        .init(name: "MapLibre GL JS", license: "BSD 3-Clause", file: "StreetMapAssets/web/LICENSE-maplibre-gl.txt"),
        .init(name: "PMTiles", license: "BSD 3-Clause", file: "StreetMapAssets/web/LICENSE-pmtiles.txt"),
        .init(name: "Protomaps basemap style", license: "BSD 3-Clause",
              file: "StreetMapAssets/web/LICENSE-protomaps-basemaps.md"),
        .init(name: "Noto Sans", license: "SIL Open Font License 1.1", file: "StreetMapAssets/fonts/OFL.txt"),
        .init(name: "Tangram icons (Mapzen)", license: "MIT", file: "StreetMapAssets/sprites/LICENSE-tangrams-icons.txt"),
        .init(name: "bge-small-en-v1.5 (search model)", license: "MIT", file: "Meaning/LICENSE-bge-small-en-v1.5.txt"),
        .init(name: "Defaults", license: "MIT", file: "Licenses/defaults-LICENSE.txt"),
        .init(name: "Swift System", license: "Apache 2.0", file: "Licenses/swift-system-LICENSE.txt"),
        .init(name: "Swift Certificates, Swift ASN.1 and Swift Crypto (the Mac's phone service)", license: "Apache 2.0",
              file: "Licenses/swift-crypto-certificates-asn1-LICENSE.txt"),
        .init(name: "Street map data: © OpenStreetMap contributors", license: "Open Database License 1.0", file: nil),
    ]
}

#if os(iOS)
/// About's PrepareMe rows on the phone and iPad: the notice, then the privacy page and the source (each only once it
/// has an address), then Acknowledgements.
struct PrepareMeAboutRows: View {
    var body: some View {
        Text(AboutCopy.medicalNotice).foregroundStyle(PrepareMeColors.info)
        if let page = AboutCopy.privacyPage { Link("Privacy", destination: page) }
        if let page = AboutCopy.source { Link("PrepareMe's Source", destination: page) }
        NavigationLink("Acknowledgements") { AcknowledgementsList() }
    }
}

struct AcknowledgementsList: View {
    /// The sample library's pages and map, in a build that carries them (Unlisted plan, phase 4)
    private var sample: [Acknowledgement] {
        guard SampleLibrary.hasFiles(in: PrepareMeSample.folder) else { return [] }
        return [.init(name: SampleLibrary.credit, license: "Public domain; map data Open Database License 1.0", file: nil)]
    }

    var body: some View {
        List(Acknowledgement.all + sample) { item in
            if let text = item.text {
                NavigationLink { LicenseText(title: item.name, text: text) } label: { row(item) }
            } else {
                row(item)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: Acknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
            Text(item.license).font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
    }
}

private struct LicenseText: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView { Text(text).font(.pmNote).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
#else
/// About's PrepareMe rows on the Mac: the notice and the two pages (each only once it has an address).
struct PrepareMeAboutRows: View {
    var body: some View {
        Text(AboutCopy.medicalNotice).foregroundStyle(PrepareMeColors.info)
        if let page = AboutCopy.privacyPage { Link("Privacy", destination: page) }
        if let page = AboutCopy.source { Link("PrepareMe's Source", destination: page) }
    }
}

/// The Mac's Acknowledgements, in About's Licenses and credits fold: each part, its license, and Show for the text the
/// app carries (opened in the Mac's text viewer).
struct AcknowledgementsList: View {
    var body: some View {
        ForEach(Acknowledgement.all) { item in
            LabeledContent(item.name) {
                HStack {
                    Text(item.license).foregroundStyle(PrepareMeColors.text2)
                    if let file = item.file, let url = Bundle.main.resourceURL?.appendingPathComponent(file),
                       FileManager.default.fileExists(atPath: url.path) {
                        Button("Show") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }
}
#endif
