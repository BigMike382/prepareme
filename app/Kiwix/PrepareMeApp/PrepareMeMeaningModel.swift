// This file is part of PrepareMe, a local build of Kiwix for one household.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import MeaningSearch

/// Meaning search's model (docs/plans/2026-10-28-meaning-search.md, phase 3): bge-small-en-v1.5 at full precision
/// (phase 1, on the oldest phone: 35 MB against half precision's 216 MB, and the original's numbers exactly), in the
/// app as its Meaning folder (kiwix-mac/build.sh copies it in). Loaded and warmed up once at launch, off the main
/// thread; search uses it from then on (PrepareMeMeaning). A build without the folder, or a model that won't load,
/// searches by words alone.
enum PrepareMeMeaningModel {
    /// The model behind a lock: two windows' searches may ask at once
    private final class Held: @unchecked Sendable {
        let model: MeaningModel
        let lock = NSLock()
        init(_ model: MeaningModel) { self.model = model }
        func numbers(_ typed: String) -> [Float]? { lock.withLock { try? model.searchVector(typed) } }
    }

    static func start() {
        Task.detached(priority: .utility) {
            guard let folder = Bundle.main.url(forResource: "Meaning", withExtension: nil) else {
                Log.LibraryOperations.error("meaning search: the model isn't in this build")
                return
            }
            do {
                let model = try MeaningModel(folder: folder, precision: .full)
                try model.warmUp()
                let held = Held(model)
                PrepareMeMeaning.shared.ready { held.numbers($0) }
            } catch {
                Log.LibraryOperations.error("meaning search: the model didn't load (\(error, privacy: .public))")
            }
        }
    }
}
