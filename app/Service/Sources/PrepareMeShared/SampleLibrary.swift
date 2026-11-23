import Foundation

/// The sample library (Unlisted plan, phase 4; docs/plans/2026-11-22-unlisted-phase-4-sample.md): what a device that has
/// never been paired and holds no library may show from "Try the sample" on its welcome screen. Three files in the
/// app's own Sample folder, read only (packer/sample.py makes them; kiwix-mac/build.sh bundles them only once the owner
/// approved them), never copied into the library folder or the inventory copy file. These are its rules; the app's
/// PrepareMeSample follows them.
public enum SampleLibrary {
    public static let folder = "Sample"
    public static let library = "sample-library.zim"
    public static let map = "sample-street-map.pmtiles"
    public static let inventory = "sample-inventory.json"
    public static let files = [library, map, inventory]
    /// The sample library's own ID, packer/sample.py's SAMPLE_ID (made from "PrepareMe sample"; never a volume's)
    public static let id = "2f4505f6-de41-5f44-b4e8-7b672e1030a9"
    /// Whether the sample was open when the app last ran, in the app's defaults
    public static let onKey = "prepareme.sample.on"
    /// What the app keeps in its defaults while the sample is open, removed when it is put away: where the street map
    /// was looking, its switches and route side, the Maps side picked, and the searches made (a device with no library
    /// had no street map to switch and nothing to search; a Maps side picked before goes back to the first one).
    public static let leftoverKeys = ["streetMapCamera", "streetMap.useAlternate", "streetMap.showConditions",
                                      "streetMap.showMarks", "streetMap.showPins", "streetMap.showOld",
                                      "prepareme.mapsPane", "recentSearchTexts"]

    /// The strip on every tab while it is open (the plan's picture), and its button.
    public static let stripTitle = "Sample library."
    public static let stripWords = "Made-up household, Washington, DC."
    public static let leave = "Leave"
    public static let leaveSample = "Leave the Sample"
    public static let tryIt = "Try the Sample"
    public static let tryWhy = "Not set up yet? See how PrepareMe works with a sample library: a made-up household in "
        + "Washington, DC."
    public static let noTopo = "The sample has no topo maps. A household's Mac adds them."
    public static let noPins = "The sample can't add pins. In a household, pins go to every phone through the Mac."
    public static let inventoryFoot = "A made-up household's inventory, for the sample. It can't be changed."
    /// About's Acknowledgements line for the sample's pages, shown while the app carries the sample
    public static let credit = "Sample library: six pages from Ready.gov (FEMA) and CDC, works of the U.S. government in "
        + "the public domain; street map © OpenStreetMap contributors"

    /// "Try the sample" is offered only with all three files in the app, on a device never paired that holds no library.
    public static func offered(hasFiles: Bool, paired: Bool, held: Int) -> Bool {
        hasFiles && !paired && held == 0
    }

    public enum AtLaunch: Equatable, Sendable { case open, putAway, nothing }

    /// At launch: a sample left open opens again, whole, at the files' new place (an update moves the app's folder),
    /// while it is still offered; otherwise everything of it is put away (paired since, a library arrived, or an app
    /// without the sample). A sample never opened is left alone.
    public static func atLaunch(wasOn: Bool, hasFiles: Bool, paired: Bool, held: Int) -> AtLaunch {
        guard wasOn else { return .nothing }
        return offered(hasFiles: hasFiles, paired: paired, held: held) ? .open : .putAway
    }

    /// What putting it away removes from the app's defaults: the sample's keys only when it was open (open now, or left
    /// open when the app last ran). Put away also runs on every pairing and every Add from Files, on the family's
    /// devices too, so a device that never opened it keeps its own map position, switches, Maps side and searches.
    public static func removedAtPutAway(wasOn: Bool) -> [String] {
        wasOn ? leftoverKeys + [onKey] : []
    }

    /// The made-up inventory, in the phones' own format; nil when it is missing or can't be read, and then the sample
    /// isn't opened at all, never half.
    public static func readInventory(in folder: URL) -> PhoneInventory? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(inventory)) else { return nil }
        return try? JSONDecoder().decode(PhoneInventory.self, from: data)
    }

    /// Whether `folder` holds all three files.
    public static func hasFiles(in folder: URL?) -> Bool {
        guard let folder else { return false }
        return files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}
