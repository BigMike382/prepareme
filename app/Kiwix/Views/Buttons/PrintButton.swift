// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(macOS)
import SwiftUI
import PDFKit

struct PrintButton: View {
    @FocusedValue(\.isBrowserURLSet) var isBrowserURLSet
    let articleTitle: () -> String?
    /// browser.webView.pdf()
    let browserDataAsPDF: () async throws -> Data?

    private func tempFileURL() async -> URL? {
        await Self.tempFileURL(title: articleTitle(), data: browserDataAsPDF)
    }

    static func tempFileURL(title articleTitle: String?, data browserDataAsPDF: () async throws -> Data?) async -> URL? {
        guard let pdfData = try? await browserDataAsPDF() else {
            return nil
        }
        let title: String
        if let articleTitle, !articleTitle.isEmpty {
            title = articleTitle.slugifiedFileName
        } else {
            title = "article"
        }
        return FileExporter.tempFileFrom(exportData: .init(data: pdfData, fileName: title))
    }

    /// The page as a PDF, through the print panel (the toolbar's button, and PrepareMe's File › Print).
    static func print(title: String?, data: () async throws -> Data?) async {
        guard let url = await tempFileURL(title: title, data: data) else { return }
        let pdfDoc = PDFDocument(url: url)
        let operation = pdfDoc?.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true)
        operation?.run()
    }

    var body: some View {
        Button {
            Task { await Self.print(title: articleTitle(), data: browserDataAsPDF) }
        } label: {
            Label {
                Text(LocalString.common_button_print)
            }  icon: {
                Image(systemName: "printer")
            }
        }.disabled(isBrowserURLSet != true)
        #if !PREPAREME_APP  // PrepareMe's ⌘P is File › Print's (Task 13.3; F48)
            .keyboardShortcut("p", modifiers: .command)
        #endif
    }
}
#endif
