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

import CoreData
import os
#if PREPAREME_APP
import PrepareMeShared  // DatabaseAside (audit D4)
#endif

struct Database {
    static let shared = Database()
    private let container: NSPersistentContainer

    private init() {
        container = Self.createContainer()
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    /// A persistent container to set up the Core Data stack.
    private static func createContainer() -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "DataModel")
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve a persistent store description.")
        }
        if ProcessInfo.processInfo.arguments.contains("testing") {
            description.url = URL(fileURLWithPath: "/dev/null")
        }

        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        #if PREPAREME_APP
        // PrepareMe (audit D4): a store that won't open never stops every launch. A damaged one is moved aside and a
        // fresh one made (PrepareMe registers its library again from its own record); one that can't be read now
        // (still locked after a restart) is left for the next launch, this run using one in memory, as does any
        // store that still won't open. Open tabs and bookmarks are what's lost; never the guides or the inventory.
        if !load(container) {
            let log = Logger(subsystem: "com.bigmike382.prepareme", category: "database")
            if let url = description.url, DatabaseAside.readable(url), DatabaseAside.move(url), load(container) {
                log.error("reader database would not open: set aside, started fresh")
            } else {
                log.error("reader database would not open: kept as it is, this run uses one in memory")
                let memory = NSPersistentStoreDescription()
                memory.type = NSInMemoryStoreType
                container.persistentStoreDescriptions = [memory]
                _ = load(container)
            }
        }
        #else
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        #endif

        /// - Tag: viewContextMergeParentChanges
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.name = "viewContext"
        /// - Tag: viewContextMergePolicy
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.undoManager = nil
        container.viewContext.shouldDeleteInaccessibleFaults = true
        return container
    }

    #if PREPAREME_APP
    /// Whether the container's stores opened (each call is answered before it returns: stores load one after another).
    private static func load(_ container: NSPersistentContainer) -> Bool {
        nonisolated(unsafe) var opened = true
        container.loadPersistentStores { _, error in
            if error != nil { opened = false }
        }
        return opened
    }
    #endif
}
