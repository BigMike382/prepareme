// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import Network
import PrepareMeShared
import Security

/// The home Mac as the app reaches it: the pairing code (host, address, port, the certificate's SHA-256 and this
/// phone's token) kept in the Keychain, readable after the first unlock so a background refresh can use it, and one
/// request at a time to the Mac's library service with the certificate pinned. The probe's way (app/Probe), under the
/// app's own Keychain name.
enum MacLink {
    static let keychainService = AppCopy.id  // PrepareMe Dev's own (Unlisted plan, phase 3)

    static var pairing: PairingCode? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else {
            return nil
        }
        return try? PairingCode.read(String(decoding: data, as: UTF8.self))
    }

    /// Keeps a scanned or pasted code; a code that isn't one (or points outside the home network) is refused. So is
    /// one this copy may not keep (Unlisted plan, phase 3; PairingCode.keptBy): PrepareMe Dev keeps only a test
    /// service's code, and the family's PrepareMe on a real device only the family's Mac's. A refused code changes
    /// nothing: no token is stored and an earlier pairing stays.
    @discardableResult
    static func pair(_ text: String) throws -> PairingCode {
        let code = try PairingCode.read(text)
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        guard code.keptBy(dev: AppCopy.isDev, simulator: simulator) else {
            throw AppCopy.isDev ? Problem.familyMac : Problem.testCode
        }
        SecItemDelete(keychainQuery() as CFDictionary)
        var add = keychainQuery()
        add[kSecValueData as String] = Data(try code.text().utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Problem.other("the Keychain refused it (\(added))") }
        SecItemDelete(roleQuery() as CFDictionary)  // a new pairing's role is learned afresh
        MacLookupKeys.forget()  // and its barcode keys asked for afresh (Unlisted plan, phase 4)
        InstallMarker.mark(.standard)  // this install's own pairing, kept at its next launch (B2-19)
        return code
    }

    #if os(iOS)
    /// At launch, first thing (beta run 2, B2-19, choice a): an earlier install's pairing, left in the Keychain when
    /// PrepareMe was deleted, is forgotten, so the phone asks to be paired again; an upgrade keeps its own
    /// (InstallMarker holds the rule, InstallMarkerTests pins it). The library's folder is the other sign of an
    /// earlier build.
    static func forgetAfterReinstall() {
        var query = keychainQuery()
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // anything but "found" or "none" (before the first unlock, the Keychain says interaction not allowed): wait
        let found: InstallMarker.Pairing = status == errSecSuccess ? .held : status == errSecItemNotFound ? .none : .locked
        InstallMarker.settle(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "com.bigmike382.prepareme",
                             earlierFolders: [PrepareMeLibrary.root], pairing: found) { unpair() }
    }
    #endif

    static func unpair() {
        SecItemDelete(keychainQuery() as CFDictionary)
        SecItemDelete(roleQuery() as CFDictionary)
        MacLookupKeys.forget()
    }

    /// Whether the Mac last said this phone may edit (an adult's) or not (a child's), kept in the Keychain beside the
    /// pairing (concept-doc plan, phase B), so it reads away from home, where the Mac can't be asked: Add from Files
    /// needs it. A reinstall forgets it with the pairing (B2-19). Nil until the Mac has answered once.
    static var canEdit: Bool? {
        var query = roleQuery()
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else {
            return nil
        }
        switch String(decoding: data, as: UTF8.self) {
        case "adult": return true
        case "child": return false
        default: return nil
        }
    }

    static func keepRole(canEdit: Bool) {
        guard MacLink.canEdit != canEdit else { return }
        SecItemDelete(roleQuery() as CFDictionary)
        var add = roleQuery()
        add[kSecValueData as String] = Data((canEdit ? "adult" : "child").utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// This phone's own id (F-095), sent with its inventory changes so the Mac knows a phone paired again for the same
    /// one: a random UUID made at the first send, kept in the Keychain on this device only, and never removed by
    /// unpairing or a new pairing. Nil when the Keychain can't be read (before the first unlock): the Mac then goes by
    /// the pairing's label, as before.
    static var device: String? {
        var query = deviceQuery()
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data { return String(decoding: data, as: UTF8.self) }
        guard status == errSecItemNotFound else { return nil }
        let made = UUID().uuidString.lowercased()
        var add = deviceQuery()
        add[kSecValueData as String] = Data(made.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? made : nil
    }

    private static func deviceQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "device"]
    }

    private static func roleQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "role"]
    }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "pairing"]
    }

    enum Problem: Error, Equatable {
        /// `newer`: the Mac wrote the file in a format this build doesn't read (audit P2h, `FileFormat`)
        case notPaired, notFound, wrongCertificate, answered(Int), unreadable, newer, cut, other(String)
        /// Unlisted plan, phase 3: a code this copy may not keep (`familyMac` to PrepareMe Dev, `testCode` to the
        /// family's PrepareMe on a real device), and the family's Mac refusing PrepareMe Dev (`refusedDev`)
        case familyMac, testCode, refusedDev

        /// Plain words for the Home Mac screen ("this iPad" on an iPad, so on the main actor with ThisDevice).
        @MainActor var words: String {
            switch self {
            case .notPaired: "Not paired with the Mac yet."
            case .notFound: HomeMacWords.notFound  // the next step too (Task 9.3, F44)
            case .wrongCertificate: "Refused: this isn't the Mac this \(ThisDevice.word) was paired with."
            case let .answered(status):
                status == 401 ? "The Mac no longer knows this \(ThisDevice.word): pair it again."
                              : "The Mac answered with an error (\(status))."
            case .unreadable: "The Mac's list of files couldn't be read."
            case .newer: FileFormat.newerFiles(device: ThisDevice.word)
            case .cut: HomeMacWords.connectionCut  // offline fixes, task 3.3
            case let .other(why): "Something went wrong (\(why))."
            case .familyMac: "This code is from the family's Mac. PrepareMe Dev pairs only with a test service."
            case .testCode: "This code is from a test service, not the family's Mac. Use the code PrepareMe on the Mac shows."
            case .refusedDev: "The family's Mac refused PrepareMe Dev, so this pairing was removed. PrepareMe Dev pairs only with a test service."
            }
        }
    }

    /// Every request to the Mac carries the pairing's token, and from PrepareMe Dev the Dev mark (DevCopy), which the
    /// family's Mac refuses (Unlisted plan, phase 3). The family's PrepareMe sends exactly what it sent before.
    static func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if AppCopy.isDev { request.setValue(DevCopy.value, forHTTPHeaderField: DevCopy.header) }
    }

    /// The bases to try: the Mac's Bonjour name, then its address at pairing time.
    static func bases(_ code: PairingCode) -> [URL] {
        ([code.host] + (code.ip.map { [$0] } ?? [])).compactMap { URL(string: "https://\($0):\(code.port)") }
    }

    /// The Mac's manifest, read whole and checked, and the base that answered.
    static func manifest() async -> Result<(Manifest, URL), Problem> {
        guard let code = pairing else { return .failure(.notPaired) }
        var last = Problem.notFound
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent("manifest.json"), timeoutInterval: 10)
            authorize(&request, token: code.token)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    // the family's Mac refusing PrepareMe Dev: no token kept for it (Unlisted plan, phase 3)
                    if AppCopy.isDev, status == 403,
                       (response as? HTTPURLResponse)?.value(forHTTPHeaderField: DevCopy.refusedHeader) == DevCopy.value {
                        unpair()
                        return .failure(.refusedDev)
                    }
                    return .failure(.answered(status))
                }
                let manifest: Manifest
                do { manifest = try Manifest.read(data) } catch Manifest.Problem.newer { return .failure(.newer) } catch {
                    return .failure(.unreadable)
                }
                return .success((manifest, base))
            } catch {
                if pin.refused { return .failure(.wrongCertificate) }
                last = problem(error)
            }
        }
        return .failure(last)
    }

    /// Plan phase 5: the counts of the phone's latest reading of the conditions feeds, to the Mac's library service
    /// (FeedCountsReport: numbers only). True when the Mac took them; any failure is let go, as the next reading
    /// sends its own.
    static func post(_ report: FeedCountsReport) async -> Bool {
        guard let code = pairing, let body = try? report.encoded() else { return false }
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent("counts"), timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpBody = body
            authorize(&request, token: code.token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            if let (_, response) = try? await session.data(for: request) {
                return (response as? HTTPURLResponse)?.statusCode == 204
            }
            if pin.refused { return false }
        }
        return false
    }

    /// Phase M: this phone's room (PhoneStorage: sizes and file names only) to the Mac's library service, for its Phones
    /// list. True when the Mac took it; a failure is let go, as the next check sends its own.
    static func post(_ report: PhoneStorage) async -> Bool {
        guard let code = pairing, let body = try? JSONEncoder().encode(report) else { return false }
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent("storage"), timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpBody = body
            authorize(&request, token: code.token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            if let (_, response) = try? await session.data(for: request) {
                return (response as? HTTPURLResponse)?.statusCode == 204
            }
            if pin.refused { return false }
        }
        return false
    }

    /// Plan phase 7, slice 5: the Mac's copy of the inventory for the phones, and whether this phone may send edits
    /// (the service's X-PrepareMe-Edits header: an adult's phone, not a read-only one).
    static func inventory() async -> Result<(PhoneInventory, Bool), Problem> {
        guard let code = pairing else { return .failure(.notPaired) }
        var last = Problem.notFound
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent("inventory.json"), timeoutInterval: 15)
            authorize(&request, token: code.token)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                let answer = response as? HTTPURLResponse
                guard answer?.statusCode == 200 else { return .failure(.answered(answer?.statusCode ?? 0)) }
                guard let copy = try? JSONDecoder().decode(PhoneInventory.self, from: data) else {
                    return .failure(.unreadable)
                }
                guard !FileFormat.isNewer(copy.format) else { return .failure(.newer) }  // the copy held stays
                let edits = answer?.value(forHTTPHeaderField: "X-PrepareMe-Edits") == "yes"
                keepRole(canEdit: edits)  // phase B: the role kept with the pairing, for Add from Files away from home
                return .success((copy, edits))
            } catch {
                if pin.refused { return .failure(.wrongCertificate) }
                last = problem(error)
            }
        }
        return .failure(last)
    }

    /// Players plan, stage 2: the Mac's player list (every paired device gets it, a child's too), checked against
    /// `PlayerList`'s limits before it is taken.
    static func players() async -> Result<PlayerList, Problem> {
        guard let code = pairing else { return .failure(.notPaired) }
        var last = Problem.notFound
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent("players.json"), timeoutInterval: 15)
            authorize(&request, token: code.token)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { return .failure(.answered(status)) }
                guard let list = PlayerList.read(data) else { return .failure(.unreadable) }
                return .success(list)
            } catch {
                if pin.refused { return .failure(.wrongCertificate) }
                last = problem(error)
            }
        }
        return .failure(last)
    }

    /// Unlisted plan, phase 4 (decision 4): the Mac app's barcode keys, for an adult's device (MacLookupKeys keeps
    /// them). A Mac from before phase 4 answers 404; a child's device gets 403.
    static func lookupKeys() async -> Result<LookupKeys, Problem> {
        guard let code = pairing else { return .failure(.notPaired) }
        var last = Problem.notFound
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent(String(LookupKeys.path.dropFirst())),
                                     timeoutInterval: 15)
            authorize(&request, token: code.token)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { return .failure(.answered(status)) }
                guard let keys = try? LookupKeys.read(data) else { return .failure(.unreadable) }
                return .success(keys)
            } catch {
                if pin.refused { return .failure(.wrongCertificate) }
                last = problem(error)
            }
        }
        return .failure(last)
    }

    /// The phone's waiting edits, to the Mac: the service's status (202: taken, to be applied by the Mac app), or how
    /// it went when nothing answered (PhoneSend, checkpoint 2): never reached the Mac (no body sent: away from home, the
    /// Mac off, a certificate refused, not paired), or unsure (the post went out and no answer came). Edits not taken
    /// stay waiting and go again at the next look (each has its own id, so the Mac never applies one twice).
    static func send(_ edits: PhoneEdits) async -> PhoneSend {
        var edits = edits
        edits.device = device  // which phone, through a new pairing (F-095)
        guard let code = pairing, let body = try? JSONEncoder().encode(edits) else { return .notReached }
        var tries: [PhoneSend] = []
        for base in bases(code) {
            var request = URLRequest(url: base.appendingPathComponent("inventory/edits"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.httpBody = body
            authorize(&request, token: code.token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let pin = PinCheck(pin: code.fp)
            let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            // the task itself, not data(for:), so its count of the body's bytes sent can be read when no answer came
            let (status, bodySent) = await withCheckedContinuation { (done: CheckedContinuation<(Int?, Int64), Never>) in
                let box = TaskBox()
                box.task = session.dataTask(with: request) { _, response, _ in
                    done.resume(returning: ((response as? HTTPURLResponse)?.statusCode, box.task?.countOfBytesSent ?? 1))
                }
                box.task?.resume()
            }
            if let status { return .answered(status) }
            tries.append(PhoneSend.unanswered(bodyBytesSent: bodySent))
            if pin.refused { break }
        }
        return PhoneSend.first(tries)
    }

    static func problem(_ error: Error) -> Problem {
        let notFound: Set<URLError.Code> = [.cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost,
                                            .notConnectedToInternet, .dnsLookupFailed]
        if let code = (error as? URLError)?.code, notFound.contains(code) { return .notFound }
        if (error as? URLError)?.code == .secureConnectionFailed { return .cut }  // a pin refusal is said before this
        return .other("code \((error as NSError).code)")
    }
}

/// Holds a data task for its own completion handler, which reads the task's count of bytes sent (MacLink.send).
private final class TaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}

/// The certificate pin for one session: trusted only when the leaf certificate's SHA-256 is the paired one.
final class PinCheck: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String
    private let lock = NSLock()
    private var refusedOnce = false
    var refused: Bool { lock.withLock { refusedOnce } }

    init(pin: String) {
        self.pin = pin
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if Pin.matches(trust, pin: pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.withLock { refusedOnce = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Asks for the home network permission while the app is in front (a background app is refused silently; Apple
/// TN3179), by looking for the Mac's services once.
@MainActor
enum LocalNetworkPermission {
    private static var browser: NWBrowser?

    static func ask() {
        guard browser == nil else { return }
        let found = NWBrowser(for: .bonjour(type: AppCopy.bonjour, domain: nil), using: .tcp)
        found.browseResultsChangedHandler = { _, _ in
            Task { @MainActor in
                browser?.cancel()
                browser = nil
            }
        }
        browser = found
        found.start(queue: DispatchQueue(label: "prepareme.browse"))
    }
}
