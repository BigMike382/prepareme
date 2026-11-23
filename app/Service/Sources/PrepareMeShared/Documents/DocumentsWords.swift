import Foundation

/// How a copy leaves PrepareMe; its word is what the document's Info records.
public enum DocumentSendWay: String, Sendable, CaseIterable {
    case print = "Print"
    case airDrop = "AirDrop"
    case share = "Share"
    case lockedPDF = "Locked PDF"
}

/// Essential Documents' fixed words (the design page's, approved 2026-10-24), shared so `swift test` pins them. None
/// of them ever carries a document's contents; names appear only on screen, never in a log.
public enum DocumentsWords {
    public static let title = "Essential Documents"
    public static let lockedHeading = "Essential Documents are locked"
    public static let lockedBody = "Unlock to see the household's insurance, IDs, deeds, medical and money papers."
    /// What macOS and iOS show under the Touch ID or Face ID prompt ("PrepareMe is trying to …" on the Mac).
    public static let unlockReason = "unlock Essential Documents"
    public static let sendReason = "send a copy of a document outside PrepareMe"
    public static let emptyHeading = "Keep copies of the papers you'd need after a disaster"
    public static let emptyBody = "Insurance, IDs, deeds, medical and money papers. They're locked, kept whole on this "
        + "Mac and the adults' phones, and open with no internet."
    public static let notUnlocked = "Not unlocked. Try again when you're ready."
    public static let noSecureEnclave = "This Mac can't keep Essential Documents' key: it has no Secure Enclave."
    public static let cantOpenKey = "This Mac's key for Essential Documents couldn't be opened, so nothing was changed."
    public static let cantRead = "Essential Documents couldn't be read, so nothing was changed. Try again; if it "
        + "happens again, a backup restores it."
    /// A damaged document's heading, `damaged` its red line (PMState colors the line, not the heading: after phase 8).
    public static let damagedHeading = "This document can't be shown"
    public static let damaged = "This document's stored copy doesn't match its fingerprint, so it isn't shown. "
        + "A backup restores it."
    public static let quickLookNote = "Opened from a short-lived copy that's wiped when Essential Documents locks."
    public static let sendMessage = "Once it leaves PrepareMe it isn't locked, and PrepareMe can't take it back. "
        + "Anyone the copy reaches can read it."
    public static let printMessage = "The pages go straight to the printer; no file is made. The print queue and some "
        + "printers keep a job until it finishes, so print on the home printer."
    public static let lockedPDFMessage = "PrepareMe makes a copy that opens only with the password you type here. "
        + "Tell the person the password by phone, not in the same message. PrepareMe doesn't keep it."
    public static let addFolderMessage = "Everything in the folder you pick is added here, its folders and subfolders "
        + "kept as they are."
    public static let waitForAdd = "Wait a moment: PrepareMe is still bringing documents in."
    public static let scanNotReceived = "The scan didn't come through from the iPhone or iPad, so nothing was added. "
        + "Try again."
    public static let noPrint = "Print is for PDFs and photos. Print this one from a PDF of it."

    public static func unlockButton(biometry: String?) -> String {
        biometry.map { "Unlock with \($0)" } ?? "Unlock"
    }

    public static func documents(_ count: Int) -> String { count == 1 ? "1 document" : "\(count) documents" }

    public static func footer(count: Int, device: String = "Mac") -> String {
        count == 0 ? "No documents yet" : "\(documents(count)), all on this \(device)"
    }

    public static func deleteDocumentTitle(_ name: String) -> String { "Delete “\(name)”?" }
    public static let deleteDocumentMessage = "It goes to Recently Deleted for 30 days, then it's gone for good."

    public static func deleteFolderTitle(_ name: String) -> String { "Delete the folder “\(name)”?" }
    public static func deleteFolderMessage(documents count: Int) -> String {
        count == 0 ? "It goes to Recently Deleted for 30 days, then it's gone for good."
            : "It and the \(documents(count)) in it go to Recently Deleted for 30 days, then they're gone for good."
    }

    public static func sendTitle(_ name: String, _ way: DocumentSendWay) -> String {
        switch way {
        case .print: return "Print “\(name)”?"
        case .airDrop: return "Send “\(name)” by AirDrop?"
        case .share: return "Share “\(name)” outside PrepareMe?"
        case .lockedPDF: return "Send “\(name)” as a locked PDF?"
        }
    }

    /// The Mac's command that brings in a folder from the Mac, in the Documents menu and on the empty screen (menu
    /// bar plan, owner 2026-11-14: "Add a Folder…" until then, which read as New Folder…'s double).
    public static let addFolder = "Add Folder of Documents…"

    /// One Add Folder of Documents…'s result, in counts only.
    public static func report(_ report: DocumentImportReport) -> String {
        var parts = ["Added \(documents(report.added))"
            + (report.foldersMade > 0 ? " and \(report.foldersMade == 1 ? "1 folder" : "\(report.foldersMade) folders")" : "")
            + "."]
        if report.alreadyHere > 0 { parts.append("\(report.alreadyHere) \(report.alreadyHere == 1 ? "was" : "were") already here.") }
        for reason in DocumentRefusal.allCases {
            guard let count = report.refused[reason], count > 0 else { continue }
            parts.append("\(count == 1 ? "1 file" : "\(count) files") \(count == 1 ? reason.rawValue : plural(reason)).")
        }
        return parts.joined(separator: " ")
    }

    public static func refused(_ reason: DocumentRefusal) -> String { "That file \(reason.rawValue)." }

    private static func plural(_ reason: DocumentRefusal) -> String {
        switch reason {
        case .notAType: return "aren't a type PrepareMe keeps"
        case .package: return "are packages, not single files"
        case .unreadable: return "couldn't be read"
        case .mismatch: return "didn't match their stored copies, so they weren't kept"
        }
    }

    /// A send's line in the document's Info.
    public static func sendLine(_ send: DocumentSend) -> String {
        "\(send.date.formatted(date: .abbreviated, time: .shortened)) · \(send.how) · \(send.device)"
    }

    // The insurance move (phase 2: InsuranceMove)
    public static let bringInsurance = "Bring In the Insurance Record…"
    public static let insuranceReportTitle = "The insurance record move"
    public static let insuranceReportNote = "Counts, item numbers and fingerprints only. The inventory isn't changed: "
        + "its insurance record keeps working as it is. PrepareMe brings in new photos and the newer insurance PDF each "
        + "time you unlock."
    public static let noInsuranceRecord = "The inventory has no insurance record yet: start it in an item's form "
        + "(Insurance record)."
    public static let noInventory = "The inventory couldn't be read, so the insurance record wasn't brought in."

    /// After an unlock brought in new photos or couldn't bring something in, in counts only; nil otherwise. A newer
    /// insurance PDF alone says nothing: the Mac writes it again each time PrepareMe starts (its "Made" time).
    public static func broughtLine(_ brought: InsuranceMove.Brought) -> String? {
        if brought.refused > 0 {
            return "\(brought.refused == 1 ? "1 part" : "\(brought.refused) parts") of the insurance record couldn't be "
                + "brought in. \(bringInsurance.dropLast()) shows which."
        }
        guard brought.photos > 0 else { return nil }
        return "Brought in \(brought.photos == 1 ? "1 new insurance photo" : "\(brought.photos) new insurance photos")"
            + (brought.pdf ? " and the newer insurance PDF." : ".")
    }

    // The adults' phones (phase 3: DocumentsPhones)
    public static let giveReason = "give a device Essential Documents"
    public static let giveButton = "Give It Essential Documents…"
    public static let cantGive = "The device couldn't be given Essential Documents, so nothing changed. Try again."

    /// After the Mac applied the adults' phones' changes, in counts only; nil when nothing came.
    public static func phoneChanges(_ result: DocumentInbox.Result) -> String? {
        if result.refused > 0 {
            return "\(changes(result.refused)) from a phone couldn't be read or didn't match, so "
                + "\(result.refused == 1 ? "it wasn't" : "they weren't") applied."
        }
        return result.applied > 0 ? "Brought in \(changes(result.applied)) from the adults' phones." : nil
    }

    static func changes(_ count: Int) -> String { count == 1 ? "1 change" : "\(count) changes" }

    /// Settings › Phones: an adult's phone's Essential Documents, short (`text`, beside its label), what follows from
    /// it (`note`), whether it is amber (behind) and when the phone last counted them (owner, 2026-11-14, by click:
    /// the card's short lines in place of one long sentence).
    public struct PhoneStatus: Equatable, Sendable {
        public let text: String
        public let note: String?
        public let caution: Bool
        public let reported: Date?
    }

    public static func phoneStatus(asked: Date?, given: Bool, report: DocumentsPhoneReport?, now: Date = Date())
        -> PhoneStatus {
        guard given else {
            guard let asked else {
                return PhoneStatus(text: "Not asked for yet",
                                   note: "The device asks at its next check at home once it has this update.",
                                   caution: false, reported: nil)
            }
            return PhoneStatus(text: "Asked \(asked.formatted(date: .abbreviated, time: .omitted))",
                               note: "\(giveButton.dropLast()) sends it every document, opened there with its own "
                                   + "Face ID, Touch ID or passcode.", caution: false, reported: nil)
        }
        guard let report else {
            return PhoneStatus(text: "Given", note: "It gets every document at its next check at home.",
                               caution: false, reported: nil)
        }
        let when = report.at.flatMap { ISO8601DateFormatter().date(from: $0) }
        let waiting = report.waiting == 0 ? nil
            : "\(changes(report.waiting)) made on it \(report.waiting == 1 ? "waits" : "wait") for Essential "
                + "Documents to be unlocked on this Mac."
        if report.inStep {
            return PhoneStatus(text: "All \(report.all) on it, every fingerprint matching", note: waiting,
                               caution: false, reported: when)
        }
        let missing = max(report.all - report.matching, report.index ? 0 : 1)
        let gets = "It gets \(missing == 1 ? "it" : "them") at its next check at home."
        return PhoneStatus(text: "\(missing) of \(report.all) \(missing == 1 ? "isn't" : "aren't") on it yet",
                           note: waiting.map { "\(gets) \($0)" } ?? gets, caution: true, reported: when)
    }

    /// The phone's amber banner in Documents and its line on Today (design: "Missing is loud, not a footer").
    public static func missing(_ count: Int, device: String) -> String {
        "\(documents(count)) \(count == 1 ? "isn't" : "aren't") on this \(device) yet. Open PrepareMe at home to get "
            + (count == 1 ? "it." : "them.")
    }

    /// A phone that kept its own copy instead of the Mac's list (audit G2: DocumentMirror.judge). `ownKeyID`: this
    /// phone's key's fingerprint, known only while Documents is open; a `missing` list under another key reads as
    /// one. The words for the phone's Documents banner, in amber.
    public static func keptOwnCopy(_ refusal: DocumentMirror.Refusal, ownKeyID: String?, device: String) -> String {
        let otherKey = refusal.reason == .otherKey
            || (ownKeyID != nil && refusal.keyID != nil && ownKeyID != refusal.keyID)
        if otherKey {
            return "The Mac's Essential Documents are locked with a different key, so this \(device) kept its own copy. "
                + "On the Mac, open Essential Documents with the recovery password."
        }
        if refusal.reason == .unstamped {
            return "The Mac's Essential Documents haven't been unlocked since they were put back on it, so this "
                + "\(device) kept its own copy. Unlock Essential Documents on the Mac, then open PrepareMe here at home."
        }
        return "The Mac's Essential Documents are missing \(documents(refusal.files)) this \(device) has, so it kept "
            + "its own copy. On the Mac, put back a newer copy of Essential Documents, or use the Mac's copy here."
    }

    /// Whether "Use the Mac's Copy…" is offered: a `missing` list under this phone's own key, while Documents is open.
    public static func offersMacsCopy(_ refusal: DocumentMirror.Refusal, ownKeyID: String?) -> Bool {
        refusal.reason == .missing && ownKeyID != nil && refusal.keyID == ownKeyID
    }

    public static let useMacsCopy = "Use the Mac's Copy…"
    public static let useMacsCopyTitle = "Use the Mac's copy?"
    public static let useMacsCopyConfirm = "Use the Mac's Copy"
    public static func useMacsCopyMessage(_ count: Int, device: String) -> String {
        "This removes \(documents(count)) that \(count == 1 ? "is" : "are") only on this \(device). Share any you need "
            + "first."
    }

    public static func usingMacsCopy(device: String) -> String {
        "This \(device) takes the Mac's copy at its next check at home."
    }

    /// The phone's Documents before the Mac has given it the key.
    public static func notGivenYet(asked: Bool) -> String {
        asked ? "This phone has asked the Mac for Essential Documents. On the Mac: Settings › Devices › "
            + "\(giveButton) Then open PrepareMe here at home."
            : "Essential Documents come from the Mac. Open PrepareMe at home, with the Mac on, to ask for them."
    }

    /// The phone's key file or gift couldn't hold the key, so it was set aside (DocumentKey.setAside).
    public static let phoneKeySetAside = "This phone's key for Essential Documents was damaged, so it was set aside. "
        + "Its documents stay here, and the key comes again from the Mac."
    /// The phone's key couldn't be opened for another reason; nothing was set aside.
    public static let phoneCantOpenKey = "Essential Documents couldn't be unlocked on this phone, so nothing was "
        + "changed. Try again."

    public static let outboxFull = "Too many changes wait for the Mac, so this one wasn't made. Open PrepareMe at "
        + "home first."
    public static let cantSave = "That change couldn't be saved, so nothing changed. Try again."
    /// The Mac's Remove for an adult's phone given the key (ruling B, owner 2026-10-24).
    public static let removeNote = "Its Essential Documents stay on it: PrepareMe can't pull them back. If the device is "
        + "lost, erase it with Find My."
    // Backups and restore (phase 4: DocumentSpare, DocumentBackup, DocumentRestoreTest; owner, 2026-10-24: the spare
    // is a recovery password kept in the Passwords app)
    public static let makeSpare = "Make a Recovery Password…"
    public static let makeNewSpare = "Make a New Recovery Password…"
    public static let noSpare = "No recovery password yet. Without one, the backups can't open Essential Documents on "
        + "another Mac."
    public static let spareTitle = "Your recovery password"
    public static let spareSteps = "Save it in the Passwords app now: open Passwords, click New Password (+), name it "
        + "“PrepareMe Recovery Password”, paste it in as the password, and save. It's the only way to open the backups on "
        + "another Mac, and PrepareMe doesn't keep it."
    public static let spareNewNote = "This replaces your old recovery password: after the next copy to iCloud, the "
        + "backups open only with this one. Keep the old one in Passwords until then."
    public static let spareCheckTitle = "Paste it back from Passwords"
    public static let spareCheckBody = "To be sure it was saved, copy it from the Passwords app and paste it here."
    public static let spareMismatch = "That isn't the same password. Copy it again from Passwords."
    public static let spareMade = "Recovery password set. The backups can now be opened on another Mac with it."
    public static let spareCopied = "Copied. It leaves the clipboard in 2 minutes."
    public static let spareReason = "make a recovery password for Essential Documents"
    public static let recoverButton = "Use the Recovery Password…"
    public static let recoverBody = "On a new Mac, or when this Mac's key won't open: paste the recovery password from "
        + "the Passwords app. This Mac then keeps its own key, opened with Touch ID or its password."
    public static let recoverReason = "keep Essential Documents' key on this Mac"
    public static let recoverWrong = "That recovery password doesn't open these documents."
    public static let testRestore = "Test a Restore…"
    public static let testRestoreBody = "Opens a backup copy with the recovery password alone, as a new Mac would, and "
        + "reads back every document. Nothing in the copy changes."
    public static let fromICloud = "The iCloud copy (Household Private › Backups › Documents)"
    public static let fromFolder = "Another copy: choose its documents folder (the USB drive's is in PrepareMe USB "
        + "Backup › PrepareMe › documents)"

    public static func restoreLine(_ result: DocumentRestoreTest.Result, from: String) -> String {
        switch result {
        case .passed(let count):
            return "Test a restore passed: all \(documents(count)) in the \(from) opened with the recovery password, every "
                + "fingerprint matching."
        case .mismatched(let matching, let all):
            return "Test a restore failed: only \(matching) of \(documents(all)) in the \(from) opened and matched. Keep "
                + "the plain originals, and say so in a session."
        case .notDownloaded(let count):
            return "\(count == 1 ? "1 file" : "\(count) files") of the \(from) \(count == 1 ? "is" : "are") still in "
                + "iCloud and coming down now. Try again in a few minutes."
        case .wrongPassword: return "That recovery password doesn't open the \(from)."
        case .noSpare: return "The \(from) has no spare key in it, so no other Mac could open it."
        case .noIndex: return "The \(from) has no list of documents that opens."
        }
    }

    /// The iCloud copy holds documents the Mac's store doesn't (audit G2: a Mac set up again from an older copy).
    public static let backupOlder = "This Mac's Essential Documents are missing documents the iCloud copy has, so "
        + "the copy is kept as it is and nothing more is copied. Say so in a session."

    /// Settings › Backups' Essential Documents lines: the iCloud copy, then the last Test a restore.
    public static func backupLines(_ status: DocumentBackup.Status?, test: DocumentRestoreTest.Record?,
                                   hasSpare: Bool, now: Date = Date()) -> [(text: String, caution: Bool)] {
        func ago(_ date: Date) -> String { date.formatted(.relative(presentation: .named, unitsStyle: .wide)) }
        var lines: [(String, Bool)] = []
        if !hasSpare {
            lines.append(("Essential Documents: not copied to iCloud: make a recovery password first (Documents › "
                          + "\(makeSpare.dropLast()))", true))
        } else if let status, let files = status.files {
            let copied = "Essential Documents: copied to Household Private › Backups › Documents \(ago(status.at)) "
                + "(\(files == 1 ? "1 file" : "\(files) files"))."
            switch status.problem {
            case nil: lines.append((copied, false))
            case "otherKey": lines.append((copied + " The copy there now belongs to another key, so it's kept as it "
                                            + "is and nothing more is copied. Say so in a session.", true))
            case "older": lines.append((copied + " " + backupOlder, true))
            default: lines.append((copied + " The latest try didn't finish; it tries again at the next check.", true))
            }
        } else if status?.problem == "older" {
            lines.append(("Essential Documents: not copied: " + backupOlder, true))
        } else if status?.problem == "otherKey" {
            lines.append(("Essential Documents: not copied: the iCloud copy there belongs to another key, so it's kept "
                          + "as it is. Say so in a session.", true))
        } else {
            lines.append(("Essential Documents: not copied to iCloud yet; it copies at the next unlock.", false))
        }
        if let test {
            let when = test.at.formatted(date: .abbreviated, time: .omitted)
            let place = test.from == "iCloud" ? "the iCloud copy" : "another copy"
            lines.append((test.passed ? "Last Test a restore: passed \(when), \(documents(test.documents)) from \(place)."
                          : "Last Test a restore: failed \(when) (\(place)). Keep the plain originals.", !test.passed))
        } else {
            lines.append(("Test a restore hasn't been run yet. Until it passes, keep the plain originals.", true))
        }
        return lines
    }

    public static let scanName = "Scan"
    /// The Add menu's button for a paper, named for what it scans (look 3 change 23); `scanName` stays the file's.
    public static let scanButton = "Scan a paper"
    public static let photoName = "Photo"
    public static func waitingHere(_ count: Int) -> String {
        "\(changes(count)) made here \(count == 1 ? "waits" : "wait") for the Mac. Open PrepareMe at home."
    }

    /// Audit D5: documents added on this device the Mac hasn't taken yet exist only here (a phone keeps Essential
    /// Documents out of its backup): "2 documents are only on this phone until it reaches the Mac."
    public static func onlyHere(_ count: Int, device: String) -> String {
        "\(documents(count)) \(count == 1 ? "is" : "are") only on this \(device) until it reaches the Mac."
    }

    /// Lock after this long away from the section or without a touch (design: "after 2 minutes").
    public static let idleLock: TimeInterval = 120

    public static func shouldLock(lastActive: Date, now: Date) -> Bool { now.timeIntervalSince(lastActive) >= idleLock }
}
