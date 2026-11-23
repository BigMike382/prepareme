// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Foundation
import PrepareMeShared

/// One library file at a time from the Mac, on a background URLSession, so a download started while the app is in
/// front carries on while it is away and iOS wakes the app when it finishes (the probe's way, app/Probe; Kiwix's own
/// downloader never replaces a file and checks nothing, assessment C11). The Mac's certificate is pinned in the
/// session's delegate. Each task carries its manifest entry as its description, so a download the system finished while
/// the app was gone is still judged against the file it was started for.
///
/// - A finished file is moved at once to the store's `incoming` as `<SHA-256>.zim`, never over a copy of the same
///   SHA-256 already waiting there (a second download of it is dropped), and handed to PrepareMeLibrary. The next file
///   can start only once the store's record names this one (`handedOver`), so two never run at once (review, I2).
/// - A cut-off download keeps iOS's resume data beside it, with the Mac's address it was fetched from; it resumes at
///   the next start of the same copy from the same address, and starts over otherwise (review, I4). The Mac answers a
///   resume with the rest only while it still serves the same file, by its ETag.
/// - A task gives up after 12 hours, and one fetching a copy the Mac no longer offers, or from an address the Mac no
///   longer answers on, is stopped at the next check (`cancelUnless`), so one stuck download never holds up the rest.
/// - Offline fixes, phase 5: an optional map (`LibraryPlan.waitsForPower`) goes on a second session that iOS may hold
///   until the phone is charging on Wi-Fi, given its default 7 days. Still one file at a time: a waiting map gives way
///   to a file that comes at once (`makeWay`), its resume data kept, and carries on after it.
final class LibraryDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = LibraryDownloader()
    static let identifier = AppCopy.id + ".library"
    static let optionalIdentifier = identifier + ".optional"
    static let giveUpAfter: TimeInterval = 12 * 60 * 60

    private let lock = NSLock()
    private var current: String?  // the SHA-256 of the copy being fetched, until its hand-over
    private var task: URLSessionTask?
    private var currentWaits = false  // the copy being fetched is on the session that may wait for power
    private var reportedShare = -1.0
    private var eventsWaiting: Set<String> = []  // a session's events finished before the system's handler arrived
    private var storedEvents: [String: () -> Void] = [:]

    /// The system's handler when it woke the app for a session's events; called once they are all delivered
    /// (review, M2: whichever of the two comes first).
    func finishEvents(_ identifier: String, _ handler: @escaping () -> Void) {
        let call = lock.withLock { () -> (() -> Void)? in
            if eventsWaiting.remove(identifier) != nil { return handler }
            storedEvents[identifier] = handler
            return nil
        }
        if let call { Self.onMain(call) }
    }

    private lazy var session = makeSession(Self.identifier, waits: false)
    private lazy var optionalSession = makeSession(Self.optionalIdentifier, waits: true)

    private func makeSession(_ identifier: String, waits: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = waits
        if !waits { configuration.timeoutIntervalForResource = Self.giveUpAfter }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// At launch: reconnects to both background sessions (so a download that finished while the app was gone reports),
    /// and learns which copy a still-running task is fetching.
    func reconnect() {
        for (made, waits) in [(session, false), (optionalSession, true)] {
            made.getAllTasks { tasks in
                let running = tasks.first { $0.state == .running || $0.state == .suspended }
                let entry = running.flatMap { Self.entry(of: $0) }
                self.lock.withLock {
                    if self.current == nil, let entry {  // never over a start
                        self.current = entry.sha256
                        self.currentWaits = waits
                        self.task = running
                    }
                }
            }
        }
    }

    var isRunning: Bool { lock.withLock { current != nil } }
    /// The SHA-256 of the copy being fetched; nil when none is (phase M: its own bytes aren't a lack of room)
    var fetching: String? { lock.withLock { current } }
    /// Whether the copy being fetched may wait for the charger (and so gives way to a file that comes at once)
    var fetchingWaits: Bool { lock.withLock { current != nil && currentWaits } }

    /// Stops the waiting map's download, its resume data kept (didCompleteWithError), and frees the downloader at once
    /// for a file that comes now; the map carries on from where it was at a later start.
    func makeWay() {
        let running = lock.withLock { () -> URLSessionTask? in
            guard currentWaits else { return nil }
            defer { current = nil; task = nil; currentWaits = false }
            return task
        }
        running?.cancel()
    }

    /// Starts fetching `entry`, resuming a cut-off download of the same copy from the same address; refused (false)
    /// while another runs or waits for its hand-over.
    @discardableResult
    func start(_ entry: Manifest.Entry, base: URL, token: String, store: LibraryStore, waits: Bool) -> Bool {
        let first = lock.withLock {
            guard current == nil else { return false }
            current = entry.sha256
            currentWaits = waits
            reportedShare = -1
            return true
        }
        guard first else { return false }
        let resumeFile = store.resumeFile(entry)
        let hostFile = resumeFile.appendingPathExtension("host")
        let session = waits ? optionalSession : self.session
        let made: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeFile),
           (try? String(contentsOf: hostFile, encoding: .utf8)) == base.absoluteString {
            made = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: base.appendingPathComponent("files").appendingPathComponent(entry.name))
            MacLink.authorize(&request, token: token)
            made = session.downloadTask(with: request)
        }
        try? FileManager.default.removeItem(at: resumeFile)
        try? FileManager.default.removeItem(at: hostFile)
        made.taskDescription = (try? JSONEncoder().encode(Started(entry: entry, base: base.absoluteString,
                                                                  incoming: store.incomingFolder.path)))
            .map { String(decoding: $0, as: UTF8.self) }
        made.countOfBytesClientExpectsToReceive = entry.size
        lock.withLock { task = made }
        made.resume()
        return true
    }

    /// The store's record names the finished copy: the next file may start.
    func handedOver(_ entry: Manifest.Entry) {
        lock.withLock {
            if current == entry.sha256 {
                current = nil
                task = nil
            }
        }
    }

    /// Stops the running download when the Mac no longer offers its copy or answers on another address; its resume
    /// data is kept for the same address only.
    func cancelUnless(offered: [Manifest.Entry], base: URL) {
        let running = lock.withLock { task }
        guard let running, let started = Self.started(running) else { return }
        if !offered.contains(where: { $0.sha256 == started.entry.sha256 }) || started.base != base.absoluteString {
            running.cancel()  // didCompleteWithError keeps its resume data with its own address
        }
    }

    struct Started: Codable {
        var entry: Manifest.Entry
        var base: String
        var incoming: String
    }

    static func started(_ task: URLSessionTask) -> Started? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Started.self, from: Data($0.utf8)) }
    }

    static func entry(of task: URLSessionTask) -> Manifest.Entry? {
        started(task)?.entry
    }

    private func release(_ task: URLSessionTask) {
        lock.withLock {
            if current == Self.entry(of: task)?.sha256 {
                current = nil
                self.task = nil
            }
        }
    }

    // MARK: The session's delegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let pin = MacLink.pairing?.fp, Pin.matches(trust, pin: pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let entry = Self.entry(of: downloadTask), entry.size > 0 else { return }
        let share = (Double(totalBytesWritten) / Double(entry.size) * 100).rounded(.down) / 100
        let fresh = lock.withLock {
            defer { reportedShare = max(reportedShare, share) }
            return share > reportedShare
        }
        guard fresh else { return }
        Task { @MainActor in PrepareMeLibrary.shared.downloadProgress(entry.name, share) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let started = Self.started(downloadTask) else { return }
        let entry = started.entry
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            release(downloadTask)
            Task { @MainActor in
                PrepareMeLibrary.shared.downloadFailed(entry, "The Mac answered with an error (\(status)); "
                                                       + "tried again at the next check.")
            }
            return
        }
        let folder = URL(fileURLWithPath: started.incoming)
        let kept = folder.appendingPathComponent("\(entry.sha256).\(entry.fileExtension)")  // LibraryStore.incoming
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: kept.path) {  // never over a waiting copy (review, I2)
            do {  // before this returns: the system deletes `location` then
                try FileManager.default.moveItem(at: location, to: kept)
            } catch {
                release(downloadTask)
                let code = (error as NSError).code
                let free = PrepareMeLibrary.availableBytes()  // phase 4: "ran out of room" in place of the code
                Task { @MainActor in
                    PrepareMeLibrary.shared.downloadFailed(entry, HomeMacWords.downloadNotKept(
                        code: code, free: free, device: ThisDevice.word))
                }
                return
            }
        }
        Task { @MainActor in await PrepareMeLibrary.shared.downloaded(entry) }  // released once handed over
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }  // a finished download is released at its hand-over
        release(task)
        guard let started = Self.started(task) else { return }
        let entry = started.entry
        let nsError = error as NSError
        if let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let folder = URL(fileURLWithPath: started.incoming)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(entry.sha256).resume")
            try? resume.write(to: file)
            try? started.base.write(to: file.appendingPathExtension("host"), atomically: true, encoding: .utf8)
        }
        guard nsError.code != NSURLErrorCancelled else { return }
        let received = task.countOfBytesReceived, code = nsError.code
        let free = PrepareMeLibrary.availableBytes()  // phase 4: "ran out of room" in place of the code
        Task { @MainActor in
            PrepareMeLibrary.shared.downloadFailed(entry, HomeMacWords.downloadStopped(
                received: received, code: code, free: free, device: ThisDevice.word))
        }
    }

    /// The system's handler, which it asks to have called on the main queue.
    static func onMain(_ call: @escaping () -> Void) {
        nonisolated(unsafe) let handler = call
        DispatchQueue.main.async { handler() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let call = lock.withLock { () -> (() -> Void)? in
            let identifier = session.configuration.identifier ?? Self.identifier
            guard let handler = storedEvents.removeValue(forKey: identifier) else {
                eventsWaiting.insert(identifier)
                return nil
            }
            return handler
        }
        if let call { Self.onMain(call) }
    }
}
#endif
