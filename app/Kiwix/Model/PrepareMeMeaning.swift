// This file is part of PrepareMe, a local build of Kiwix for one household.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// PrepareMe: meaning search (docs/plans/2026-10-28-meaning-search.md, phase 3; owner, 2026-10-28). The daily library
/// carries each guide's and household page's numbers from bge-small-en-v1.5 (packer/meaning.py); a search's own numbers
/// come from the same model, in the PrepareMe app only (PrepareMeMeaningModel calls `ready` once it has loaded), so
/// Kiwix (PrepareMe), and PrepareMe while its model loads, search by words alone. The pages most alike to a search go
/// above word search's results in their own section: meaning's best two, then word search's own first result unless it
/// is one of meaning's best three (then those three), then every result as before. No section when the first word
/// result's title begins with what was typed (PrepareMeSearchOrder.group 0: the guide named for it already leads), or
/// when no searched library carries numbers of this format and model. packer/searchcheck.py's with_meaning is the same
/// rule, and the search test measured it: the right guide first in 90 of 131 searches against 88, and none lost.
final class PrepareMeMeaning: @unchecked Sendable {  // its state only under `lock`: set on the ZimActor, read by search
    static let shared = PrepareMeMeaning()
    /// packer/meaning.py's MEANING_PATH, FORMAT, REVISION and DIMENSIONS
    static let path = "household/meaning.json"
    static let format = 1
    static let revision = "bge-small-en-v1.5@5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
    static let dimensions = 384
    static let shown = 3

    struct Page: Equatable {
        let path: String
        let title: String
        let vectors: [[Float]]
    }

    private let lock = NSLock()
    private var searchNumbers: (@Sendable (String) -> [Float]?)?
    private var library: UUID?
    private var pages: [Page] = []
    private var readFrom: String?  // the library, its file's date and the meaning file's size `pages` came from

    /// Meaning search starts: `numbers` turns what was typed into the model's numbers (nil when it can't)
    func ready(_ numbers: @escaping @Sendable (String) -> [Float]?) {
        lock.withLock { searchNumbers = numbers }
    }

    /// The numbers of the first of `libraries` that carries them, read again only when its file changed (by the file's
    /// date and the meaning file's size, so a search doesn't read about a megabyte each time); each page's title from
    /// the library itself. Run on the ZimActor before each search, which reads them.
    /// shortcut: a search in the moment between a new copy's arrival and its reopening keeps the old copy's numbers
    /// until the library next changes; nearly the same numbers, so upgrade only if a page's place ever looks stale
    @ZimActor
    func prepare(_ libraries: Set<UUID>) {
        guard lock.withLock({ searchNumbers != nil }) else { return }
        let service = ZimFileService.shared
        let found = libraries.sorted { $0.uuidString < $1.uuidString }.lazy.compactMap { id in
            URL(zimFileID: id.uuidString, contentPath: Self.path)
                .flatMap { service.getContentMetaData(url: $0) }.map { (id, $0) }
        }.first
        guard let (id, meta) = found else { return }
        let key = "\(id) \(meta.lastModified?.timeIntervalSince1970 ?? 0) \(meta.size)"
        guard lock.withLock({ readFrom != key }),
              let data = service.getURLContent(zimFileID: id.uuidString, contentPath: Self.path)?.data else { return }
        let read = (try? Self.read(data)) ?? []
        let titled = read.compactMap { path, vectors -> Page? in
            guard let url = URL(zimFileID: id.uuidString, contentPath: path),
                  let title = service.getContentMetaData(url: url)?.zimTitle else { return nil }
            return Page(path: path, title: title, vectors: vectors)
        }
        lock.withLock { (library, pages, readFrom) = (id, titled, key) }
    }

    /// Meaning's best pages for what was typed, in their library, when one of `libraries` holds them; nil when meaning
    /// search can't run (no model yet, no numbers, or its library isn't searched)
    func best(_ typed: String, in libraries: Set<UUID>) -> (library: UUID, pages: [Page])? {
        let (numbers, library, pages) = lock.withLock { (searchNumbers, library, pages) }
        guard let numbers, let library, libraries.contains(library), !pages.isEmpty,
              let search = numbers(typed), search.count == Self.dimensions else { return nil }
        return (library, Self.best(pages, search: search))
    }

    /// The meaning file's pages, (path, its sets of numbers); refused unless it is this format and this model's, and
    /// each set is 384 little-endian 32-bit floats (packer/meaning.py's meaning_json)
    static func read(_ data: Data) throws -> [(path: String, vectors: [[Float]])] {
        struct File: Decodable {
            struct Page: Decodable {
                let path: String
                let vectors: [String]
            }
            let format: Int
            let model: String
            let pages: [Page]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format == format, file.model == revision else { throw CocoaError(.fileReadCorruptFile) }
        return try file.pages.map { page in
            (page.path, try page.vectors.map { text in
                guard let bytes = Data(base64Encoded: text), bytes.count == dimensions * 4 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (0..<dimensions).map { place in
                    Float(bitPattern: UInt32(littleEndian: bytes.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: place * 4, as: UInt32.self)
                    }))
                }
            })
        }
    }

    /// The `shown` pages most alike to a search's numbers (each page by its closer set), most alike first, ties by path
    static func best(_ pages: [Page], search: [Float], shown: Int = shown) -> [Page] {
        func likeness(_ page: Page) -> Float {
            page.vectors.map { zip($0, search).reduce(0) { $0 + $1.0 * $1.1 } }.max() ?? -1
        }
        return pages.map { ($0, likeness($0)) }
            .sorted { ($1.1, $0.0.path) < ($0.1, $1.0.path) }
            .prefix(shown).map(\.0)
    }

    /// Word search's results (`found`, in order, its first `closest` the closest pages) with meaning's best pages in
    /// their library on top, by `merged`'s rule. A page word search found too stays the same result, its snippet kept.
    /// The list, the section's size and how many closest pages follow it; nil: no section
    static func placed(_ found: [SearchResult], closest: Int, best: (library: UUID, pages: [Page]),
                       typed: String) -> (results: [SearchResult], top: Int, closest: Int)? {
        let byURL = Dictionary(found.map { ($0.url, $0) }) { first, _ in first }
        let meaning = best.pages.compactMap { page in
            SearchResult(zimFileID: best.library, path: page.path, title: page.title).map { byURL[$0.url] ?? $0 }
        }
        guard let merged = merged(found.map(\.url), best: meaning.map(\.url), typed: typed,
                                  firstTitle: found.first?.title) else { return nil }
        let held = byURL.merging(meaning.map { ($0.url, $0) }) { first, _ in first }
        let top = Set(merged.0.prefix(merged.top))
        return (merged.0.compactMap { held[$0] }, merged.top, found.prefix(closest).filter { !top.contains($0.url) }.count)
    }

    /// Word search's results (`found`, in order) with meaning's best (`best`) on top, by the rule above; `firstTitle`
    /// is found's first title. The list and how many of it are the top section; nil: no section
    static func merged<T: Equatable>(_ found: [T], best: [T], typed: String, firstTitle: String?) -> ([T], top: Int)? {
        guard !best.isEmpty else { return nil }
        if let firstTitle, PrepareMeSearchOrder.group(firstTitle, typed: PrepareMeSearchOrder.words(typed)) == 0 {
            return nil
        }
        let top = found.first.map { best.contains($0) ? best : Array(best.prefix(2)) + [$0] } ?? best
        return (top + found.filter { !top.contains($0) }, top.count)
    }
}
