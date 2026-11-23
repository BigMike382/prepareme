import Foundation

/// Changes made on a phone wait for the Mac (remaining-findings plan, Task 12.3; F34; owner, 2026-10-18, by click: Send
/// now and a retry while open). A waiting change had gone only at Inventory's next look, every 2 minutes while it
/// showed, or on a pull-down nothing mentioned: now the phone tries every 30 seconds wherever the app is, while any
/// change waits, and Send now tries at once.
public enum WaitingChanges {
    public static let retryEvery: TimeInterval = 30
    /// Edit on a new item still on the phone, saved after its add began to go to the Mac (Task 2.5).
    public static let sentWhileEditing = "This item went to the Mac while you edited. Edit it again once it's there."
    public static let lookEvery: TimeInterval = 120  // Inventory's own look while it shows, whatever waits

    /// Seconds to the app's next try while changes wait; nil when nothing waits. One loop does it, wherever the app
    /// is: Inventory's own look stays at `lookEvery`, so two loops never both run on Inventory (the phase 12 review).
    public static func next(waiting: Int) -> TimeInterval? {
        waiting > 0 ? retryEvery : nil
    }

    /// The changes the line counts: those Send now sends (PhoneOutbox.ready), never a Used 1 or 1 more still held
    /// for its Undo, nor one made after it, which goes with it a few seconds later (whole-plan review). 0: no line.
    public static func waiting(_ outbox: PhoneOutbox, now: Date = Date()) -> Int {
        outbox.ready(now: now).count
    }

    /// `taken`: how many of them the Mac's service has but PrepareMe on the Mac hasn't applied
    /// (PhoneOutbox.takenUnapplied; offline fixes, task 3.1); all of them changes the line
    public static func line(_ count: Int, taken: Int = 0, device: String) -> String {
        if taken > 0, taken == count {
            return "The Mac has \(count) change\(count == 1 ? "" : "s") from this \(device); PrepareMe on the Mac needs "
                + "to be open to keep \(count == 1 ? "it" : "them")."
        }
        return "\(count) change\(count == 1 ? "" : "s") waiting for the Mac. \(count == 1 ? "It goes" : "They go") once "
            + "you're home and the Mac is on."  // the retry every 30 seconds is the app's, not a thing to read (B2-17)
    }

    /// The waiting-changes file is on the phone but couldn't be read: it is never saved over (offline fixes, task 1.1)
    public static func unreadable(device: String) -> String {
        "The changes waiting on this \(device) couldn't be read, so they're kept as they are; tell the adult who set up "
            + "PrepareMe."
    }

    /// The last save of the waiting changes failed: they are held in the app until a save works or it is closed
    public static func notSaved(device: String) -> String {
        "A change couldn't be saved on this \(device) (is it full?). It stays until the app is closed."
    }

    /// Under an item's number on its own screen while a change to it waits (beta run 3, B3-07)
    public static let itemLine = "Waiting for the Mac."

    public static let sendNow = "Send now"
    /// While a try is under way: "trying", since away from home it can't reach the Mac (owner, 2026-10-31: "Sending…"
    /// read as if it were going)
    public static let sending = "Trying to send…"
}
