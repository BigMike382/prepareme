// This file is part of Kiwix (PrepareMe), a local build of Kiwix for one household's Mac.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(macOS)
import Foundation
import SwiftUI

/// PrepareMe: the sidebar's "Keep conditions fresh for 6 hours" and "Check conditions once" (mostly-disconnected spec, section 2).
/// A press touches an empty file in Application Support › PrepareMe › requests under the real home; the Mac's
/// dashboard job (launchd WatchPaths on those files) reads only its modification time, never its contents. The job
/// answers in status.json there (dashboard/quick.py), shown here in fixed words. The sandbox lets the app into that one
/// folder through a temporary exception in project.yml, which the App Store would refuse; this build is for this Mac
/// only. The app starts no program and gets no new network access.
@MainActor
enum PrepareMeRequests {
    enum Kind {
        case refresh, checkOnce

        var fileName: String {
            switch self {
            case .refresh: return "refresh-conditions"
            case .checkOnce: return "check-once"
            }
        }
    }

    /// How long a press may wait for the job's answer before the line says it hasn't answered: a quarter-hour start
    /// plus a minute
    static let answerWait: TimeInterval = 16 * 60
    static let states: Set<String> = ["refreshing", "checked", "offline", "busy"] // quick.STATUS_KEYS

    /// The tests' home; nil is the real one
    static var homeOverride: URL?
    /// The last press this launch, kept to show the job hasn't answered yet
    static var lastPress: Date?

    /// The real home, not the app's container (the sandbox gives the app a home of its own)
    private static var home: URL? {
        if let homeOverride { return homeOverride }
        guard let dir = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir))
    }

    static var folder: URL? { home?.appending(path: "Library/Application Support/PrepareMe/requests") }

    /// Creates the request file, or sets its modification time to now. Never follows a link by that name.
    static func press(_ kind: Kind) throws {
        guard let folder else { throw POSIXError(.ENOENT) }
        try touch(kind.fileName, in: folder)
        lastPress = .now
    }

    /// Creates `name` in `folder` (made 0700), or sets its time to now, and gives that time (nanoseconds): a job's
    /// request file, which launchd watches. Never follows a link by that name. Every press's one way in (the quick
    /// refresh's, the USB backup's, Printable References'; the audit, 2026-10-22, had found three copies).
    @discardableResult
    static func touch(_ name: String, in folder: URL) throws -> Int64 {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(folder.appending(path: name).path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard futimens(fd, nil) == 0, fstat(fd, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    /// The status line, or nil when status.json is missing, can't be read or names a state not known here and no
    /// press is waiting. A press newer than the job's last answer shows instead, until the job answers.
    #if PREPAREME_APP && os(macOS)
    /// The View menu's two items (the Library menu's until 2026-11-14) and Today's Keep Conditions Fresh for 6 Hours (the Apple guidelines plan, phases 2 and 3): the same
    /// request as the buttons, its line in the status after.
    static func pressFromMenu(_ kind: Kind) {
        do {
            try press(kind)
            PrepareMeStatus.shared.update()
        } catch {
            PrepareMeStatus.shared.failed()
        }
    }
    #endif

    static func statusLine(now: Date) -> String? {
        let status = readStatus()
        if let pressed = lastPress {
            // The job writes whole seconds, so an answer in the press's own second counts as after it
            let pressedSecond = Date(timeIntervalSince1970: pressed.timeIntervalSince1970.rounded(.down))
            let answered = status.map { $0.at >= pressedSecond } ?? false
            if !answered {
                if now.timeIntervalSince(pressed) >= answerWait {
                    return "The Mac's job hasn't answered since \(clock(pressed))"
                }
                return "Asked at \(clock(pressed)); waiting for the Mac's job"
            }
        }
        guard let status else { return nil }
        // A cycle whose end has passed is over, though the job hasn't written since (the Mac asleep, say)
        let until = status.until.flatMap { $0 > now ? $0 : nil }
        switch status.state {
        case "refreshing":
            guard status.until != nil else { return nil }
            guard let until else { return "Checked at \(clock(status.at))" }
            return "Refreshing every 15 minutes until \(clock(until))"
        case "checked":
            return "Checked at \(clock(status.at))"
        case "offline":
            var line = "No internet at the last try (\(clock(status.at)))"
            if let until { line += "; refreshing until \(clock(until))" }
            return line
        case "busy":
            return "Waiting: another PrepareMe job is running (\(clock(status.at)))"
        default:
            return nil
        }
    }

    private struct Status {
        let state: String
        let at: Date
        let until: Date?
    }

    /// status.json as {"state", "at", "until"}; anything else, or a time without its offset, is nil
    private static func readStatus() -> Status? {
        guard let url = folder?.appending(path: "status.json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String, states.contains(state),
              let at = time(object["at"]) else { return nil }
        var until: Date?
        switch object["until"] {
        case nil, is NSNull: until = nil
        case let value: guard let read = time(value) else { return nil }; until = read
        }
        return Status(state: state, at: at, until: until)
    }

    private static func time(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter() // with its offset, as Python's isoformat writes it
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    /// The short time style in the local zone
    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// The status line the sidebar shows, re-read on PrepareMeRefresh's 30-second check and right after a press
@MainActor
final class PrepareMeStatus: ObservableObject {
    static let shared = PrepareMeStatus()
    @Published private(set) var line: String?
    /// Fixed words for a press that couldn't be written (the sandbox exception missing, say)
    static let notSent = "The request couldn't be written; the Mac's job wasn't asked"

    func update() { line = PrepareMeRequests.statusLine(now: .now) }

    func failed() { line = Self.notSent }
}

/// Kiwix (PrepareMe)'s sidebar section: the two buttons and the status line under them.
struct PrepareMeRequestsSection: View {
    var body: some View {
        Section {
            PrepareMeRequestsRows()
        } header: {
            Text("Conditions")
                #if PREPAREME_APP
                .font(.pmHeadline)  // the Mac draws a section's title small whatever the window's font
                #endif
        }
    }
}

/// The two buttons and the status line under them: rows in a list's section, or stacked. A button rests for 5 seconds
/// after a press.
struct PrepareMeRequestsRows: View {
    @ObservedObject private var status = PrepareMeStatus.shared
    @State private var resting: Set<PrepareMeRequests.Kind> = []

    var body: some View {
        button("Keep conditions fresh for 6 hours", systemImage: "arrow.clockwise", kind: .refresh)  // look 3, change 21
        button("Check conditions once", systemImage: "checkmark.circle", kind: .checkOnce)
        if let line = status.line {
            Text(line)
                #if PREPAREME_APP
                .font(.pmNote)  // the Today redesign's phase 5: PrepareMe's note size
                #else
                .font(.caption)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func button(_ title: String, systemImage: String, kind: PrepareMeRequests.Kind) -> some View {
        Button {
            resting.insert(kind)
            do {
                try PrepareMeRequests.press(kind)
                status.update()
            } catch {
                status.failed()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                resting.remove(kind)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(resting.contains(kind))
    }
}
#endif
