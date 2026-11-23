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

import Combine
import CoreData

import Defaults

enum SearchResultItems {
    case results([SearchResult])
    case suggestions([String])
    
    func firstIndex(where value: String) -> Int? {
        switch self {
        case let .results(results):
            results.firstIndex(where: { $0.url.absoluteString == value })
        case let .suggestions(suggestions):
            suggestions.firstIndex(where: { $0 == value})
        }
    }
    
    func index(before i: Int) -> Int {
        switch self {
        case let .results(results):
            results.index(before: i)
        case let .suggestions(suggestions):
            suggestions.index(before: i)
        }
    }
    
    func index(after i: Int) -> Int {
        switch self {
        case let .results(results):
            results.index(after: i)
        case let .suggestions(suggestions):
            suggestions.index(after: i)
        }
    }
    
    var startIndex: Int {
        switch self {
        case let .results(results):
            results.startIndex
        case let .suggestions(suggestions):
            suggestions.startIndex
        }
    }
    
    var endIndex: Int {
        switch self {
        case let .results(results):
            results.endIndex
        case let .suggestions(suggestions):
            suggestions.endIndex
        }
    }
    
    var count: Int {
        switch self {
        case let .results(results):
            results.count
        case let .suggestions(suggestions):
            suggestions.count
        }
    }
}

@MainActor
final class SearchViewModel: NSObject, ObservableObject, NSFetchedResultsControllerDelegate {
    @Published var searchText: String = ""  // text in the search field
    @Published private(set) var zimDataDict: [UUID: ZimArticleData]  // ID of zim files that are included in search
    @Published private(set) var inProgress = false
    @Published private(set) var results: SearchResultItems = .results([])
    /// PrepareMe: how many of `results`, from the first, are only the closest pages (SearchOperation.addClosest)
    @Published private(set) var closestCount = 0
    /// PrepareMe: how many of `results`, from the first, are meaning search's section (SearchOperation.addMeaning); the
    /// closest pages follow it
    @Published private(set) var meaningCount = 0
    /// PrepareMe: meaning search's best pages, shown above "Did you mean" when that is shown in place of results
    @Published private(set) var meaningAbove: [SearchResult] = []
    /// PrepareMe: nothing is ticked under Included in Search, so every opened library but the ones kept out by
    /// default (vehicles) is searched instead of none (owner, 2026-10-08: with nothing ticked Kiwix said only
    /// "No result")
    @Published private(set) var searchingAllUnticked = false

    private let fetchedResultsController: NSFetchedResultsController<ZimFile>
    private var searchSubscriber: AnyCancellable?
    @ZimActor
    private let queue = OperationQueue()
    /// PrepareMe: where the spelling help is built, one library at a time (updateSearchResults)
    nonisolated private static let spellingQueue = DispatchQueue(label: "prepareme.spelling", qos: .utility)

    override init() {
        // initialize fetched results controller
        // PrepareMe: every opened library, filtered by includedInSearch in searchable(), so ticking and unticking
        // still update the search, and the fallback sees every library
        let predicate = NSPredicate(format: "fileURLBookmark != nil")
        fetchedResultsController = NSFetchedResultsController(
            fetchRequest: ZimFile.fetchRequest(predicate: predicate),
            managedObjectContext: Database.shared.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )

        // initialize zim file IDs
        try? fetchedResultsController.performFetch()
        zimDataDict = [:]

        super.init()
        (zimDataDict, searchingAllUnticked) = Self.searchable(fetchedResultsController.fetchedObjects ?? [])

        // additional configurations
        queue.maxConcurrentOperationCount = 1
        fetchedResultsController.delegate = self

        // subscribers
        searchSubscriber = Publishers.CombineLatest(
            $searchText.removeDuplicates { prev, current in
                // consider search text to be the same ignoring spaces
                prev.trimmingCharacters(in: .whitespaces) == current.trimmingCharacters(in: .whitespaces)
            }, $zimDataDict.removeDuplicates { prev, current in
                // don't re-trigger for the same set of zim files
                Set(prev.keys) == Set(current.keys)
            })
            .map { [unowned self] searchText, zimDataDict in
                if !searchText.isEmpty, !zimDataDict.isEmpty {
                    self.updateProgress(true)
                }
                return (searchText, zimDataDict)
            }
            .debounce(for: 0.2, scheduler: DispatchQueue.main)
            .sink { [unowned self] searchText, zimDataDict in
                Task { @ZimActor [weak self] in
                    self?.updateSearchResults(searchText, Set(zimDataDict.keys))
                }
            }
    }
    
    @MainActor
    deinit {
        queue.cancelAllOperations()
        searchSubscriber?.cancel()
    }

    nonisolated func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        Task { @MainActor in
            (zimDataDict, searchingAllUnticked) = Self.searchable(fetchedResultsController.fetchedObjects ?? [])
        }
    }

    /// PrepareMe: the ticked libraries; or, when none is ticked, every one but those kept out of search by default
    private static func searchable(_ opened: [ZimFile]) -> ([UUID: ZimArticleData], Bool) {
        let ticked = opened.filter(\.includedInSearch)
        let unticked = ticked.isEmpty && !opened.isEmpty // the Mac's and the phone app's (plan phase 4) alike
        let chosen = unticked ? opened.filter { !PrepareMeLibraries.leftOutOfSearch.contains($0.fileID) } : ticked
        let dict = chosen.reduce(into: [UUID: ZimArticleData]()) { result, zimFile in
            result[zimFile.fileID] = ZimArticleData(from: zimFile)
        }
        return (dict, unticked)
    }
    
    private func updateProgress(_ value: Bool) {
        // don't publish duplicate values
        if value != inProgress {
            inProgress = value
        }
    }

    @ZimActor
    private func updateSearchResults(_ searchText: String, _ zimFileIDs: Set<UUID>) {
        queue.cancelAllOperations()
        // This is run at app start, and opens the archive of all searchable ZIM files
        let cacheDir: URL? = if FeatureFlags.suggestSearchTerms {
            try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
        } else {
            nil // don't use suggest search terms
        }
        for zimFileID in zimFileIDs {
            _ = ZimFileService.shared.openArchive(zimFileID: zimFileID)
        }
        // PrepareMe (2026-11-14): the spelling help is built off the ZimActor. Built on it, one large library's build
        // (about a minute, then refused for a long title, again every launch) held every page read and link behind it:
        // Guides stayed a spinner after the Library. One serial queue, so no build's temp file is deleted mid-build.
        if let cacheDir {
            Self.spellingQueue.async {
                for zimFileID in zimFileIDs {
                    // make sure we delete the temp file of the db indexing
                    // otherwise it will lock the user in an everlasting error
                    // that the db cannot be created
                    // if the temp file exists, it means the former creation was not finished
                    let tempFileComponent = zimFileID.uuidString.lowercased().appending(".spellingsdb.v0.1.tmp")
                    let tempFile = cacheDir.appendingPathComponent(tempFileComponent)
                    if FileManager.default.fileExists(atPath: tempFile.path()) {
                        try? FileManager.default.removeItem(at: tempFile)
                    }
                    ZimService.__sharedInstance().__createSpellingIndex(zimFileID, cachePath: cacheDir.path())
                }
            }
        }
        PrepareMeMeaning.shared.prepare(zimFileIDs)  // PrepareMe: meaning search's numbers, when its library changed
        // PrepareMe: the typed words without a question's own words (PrepareMeQuestionWords; owner, 2026-10-21)
        let operation = SearchOperation.prepareMe(typed: searchText, zimFileIDs: zimFileIDs, spelling: cacheDir)
        operation.extractMatchingSnippet = Defaults[.searchResultSnippetMode] == .matches
        operation.completionBlock = { [weak self] in
            guard !operation.isCancelled else { return }
            Task { @MainActor [weak self] in
                self?.results = operation.searchResultItems
                self?.closestCount = operation.closestCount
                self?.meaningCount = operation.meaningCount
                self?.meaningAbove = operation.meaningAboveSuggestions
                self?.updateProgress(false)
            }
        }
        queue.addOperation(operation)
    }
}
