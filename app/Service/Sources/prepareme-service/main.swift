// The Mac's file service: the phase 1 probe's, started by hand in Terminal (plan phase 1), and from phase 4 the
// library's, which PrepareMe.app runs since phase 6 (`library --agent`; the scheduler's job for it, from phase 4, was
// removed 2026-10-15).
//
//   prepareme-service help                  the usage line; every command takes only its own options and refuses
//                                           any other (--help and -h included) with exit 2, doing nothing (F-087)
//   prepareme-service init                  make the Mac's identity and the first made-up file, once
//   prepareme-service pair [--text] [--read-only]
//                                           pair one more phone: draws its code as a QR code (or prints it as text,
//                                           for the simulator); the code holds the phone's token, shown only here.
//                                           --read-only (plan phase 7): it reads the inventory but sends no edits
//                                           (a child's phone)
//   prepareme-service phones                the paired phones and when each was paired
//   prepareme-service unpair "phone N"      that phone gets nothing from now on
//   prepareme-service serve [--loopback]    serve until Control-C; swaps in a new made-up file once a day
//                                           (--loopback: on 127.0.0.1 only, for the simulator's test)
//   prepareme-service swap [--damaged]      a new made-up file now (--damaged: its served copy is one byte off)
//   prepareme-service count-alerts FILE     the counts the phone would post for a saved api.weather.gov answer
//   prepareme-service library [--folder DIR] [--loopback]
//                                           serve the packer's local delivery folder (plan phase 4) on port 8744
//                                           until stopped: only the files its manifest names, never swapped, never
//                                           advertised; pair the PrepareMe app with `pair --port 8744`. The phones'
//                                           feed counts (plan phase 5) go to jobs/phone-feed-counts.json
//   prepareme-service bend-once NAME        the library's next download of NAME arrives one byte off (the owner's
//                                           damaged-copy check); the file itself is never changed
//   prepareme-service library --agent       the library's service as the PrepareMe Mac app runs it (plan phase 6):
//                                           macOS keeps it running from inside the app, in a sandbox of its own, and
//                                           it writes its lines to Application Support › PrepareMe › logs ›
//                                           service.log itself, since launchd may not for a sandboxed app's part.
//                                           With the library it serves the inventory (plan phase 7): the copy the Mac
//                                           app writes for the phones, and adults' phones' edits into its inbox, from
//                                           Application Support › PrepareMe › inventory (--inventory DIR for a test)
//                                           `library` also answers the Mac app's pairing (plan phase 10, PairingDesk):
//                                           every second it takes the app's requests from Application Support ›
//                                           PrepareMe › pairing (--pairing DIR for a test; beside --support when only
//                                           that is given) and keeps the folder's list of paired phones current.
//                                           Essential Documents (phase 3): adults' phones given the key get the
//                                           Mac's encrypted store, read only, and send their own encrypted changes
//                                           into its inbox, from Application Support › PrepareMe › documents
//                                           (--documents DIR for a test; beside --support when only that is given)
//   prepareme-service library --home-network --port N --support DIR --folder DIR --inventory DIR --pairing DIR
//                             --documents DIR
//                                           the test service PrepareMe Dev on a spare device reaches over home Wi-Fi
//                                           (Unlisted plan, phase 3, decision 8): made-up libraries only, every
//                                           folder a scratch folder, its own port (ServiceCommandLine refuses
//                                           anything else)
//
// Its files are in ~/Library/Application Support/PrepareMe/service (identity, phones, the served folder `files`);
// the phones' counts go to ~/Library/Application Support/PrepareMe/jobs/probe-counts.json. `--support DIR` points
// both elsewhere, for tests (the counts to DIR/jobs unless `--jobs DIR` says otherwise); `--port N` serves on another
// port than 8743 (8744 for `library`). `library` reads the identity and the phones from the same folder as the probe's
// service, so a phone is paired once for either; its folder is Application Support › PrepareMe › delivery unless
// `--folder` names another. It prints counts, labels and fixed words only. The home folder is the account's own
// (RealHome), never `$HOME` and never the one a sandbox gives it. From a Claude Code session (CLAUDECODE set) every
// command but count-alerts must be given `--support` (and `library` `--folder` and `--inventory`), none of them in
// Application Support › PrepareMe (ServiceCommandLine). A service started with its own `--support` is a test
// service (Unlisted plan, phase 3): its codes carry the test mark, and it serves PrepareMe Dev, which the family's
// Mac's service (no `--support`) refuses.
import Foundation
import PrepareMeServer
import PrepareMeShared
import Security

let defaultPort: UInt16 = 8743
let libraryPort: UInt16 = 8744  // beside the probe's service (owner, 2026-10-13)
let defaultBytes: Int64 = 1 << 30  // the plan's 1 GB
let swapEvery: TimeInterval = 86400
nonisolated(unsafe) var agentLog: LogFile?  // set once by --agent, before anything runs: the lines go there, not to the terminal

func take(_ flag: String, _ arguments: inout [String]) -> String? {
    guard let at = arguments.firstIndex(of: flag), at + 1 < arguments.count else { return nil }
    let value = arguments[at + 1]
    arguments.removeSubrange(at...(at + 1))
    return value
}

func flag(_ name: String, _ arguments: inout [String]) -> Bool {
    guard let at = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: at)
    return true
}

func fail(_ line: String, _ code: Int32 = 1) -> Never {
    agentLog?.add("\(stamp())  \(line)")
    FileHandle.standardError.write(Data((line + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var stops: [DispatchSourceSignal] = []  // kept alive while the service runs
let home = RealHome.url ?? FileManager.default.homeDirectoryForCurrentUser
// The whole line is checked before anything below reads it or touches a folder (FINDINGS F-087); a Claude Code
// session's shells carry CLAUDECODE, and from one every folder must be named and none can be a real one.
switch ServiceCommandLine.check(arguments, session: ProcessInfo.processInfo.environment["CLAUDECODE"] != nil,
                                home: home) {
case .run:
    break
case .help:
    print(ServiceCommandLine.usage)
    exit(0)
case .refused(let line):
    FileHandle.standardError.write(Data((line + "\n" + ServiceCommandLine.usage + "\n").utf8))
    exit(2)
}
let asAgent = flag("--agent", &arguments)
let given = take("--support", &arguments).map { URL(fileURLWithPath: $0) }
if asAgent {  // a test's --support keeps the log beside it, never in the real logs folder
    let logs = given?.appendingPathComponent("logs") ?? home.appendingPathComponent("Library/Application Support/PrepareMe/logs")
    agentLog = LogFile(url: logs.appendingPathComponent("service.log"))
}
let support = given ?? home.appendingPathComponent("Library/Application Support/PrepareMe/service")
// A test's --support keeps its counts beside it, never in the real jobs folder (phase 1 review, item 4).
let jobs = take("--jobs", &arguments).map { URL(fileURLWithPath: $0) }
    ?? given?.appendingPathComponent("jobs")
    ?? home.appendingPathComponent("Library/Application Support/PrepareMe/jobs")
let bytes: Int64 = take("--size-mb", &arguments).map { value in
    guard let mb = Int64(value), mb >= 0, mb <= 4096 else { fail("--size-mb takes 0 to 4096", 2) }
    return mb << 20
} ?? defaultBytes
let givenPort: UInt16? = take("--port", &arguments).map { value in
    guard let number = UInt16(value), number >= 1024 else { fail("--port takes 1024 to 65535", 2) }
    return number
}
let library = take("--folder", &arguments).map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Library/Application Support/PrepareMe/delivery")
let inventoryFolder = take("--inventory", &arguments).map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Library/Application Support/PrepareMe/inventory")
let documentsFolder = take("--documents", &arguments).map { URL(fileURLWithPath: $0) }
    ?? given?.appendingPathComponent("documents")
    ?? home.appendingPathComponent("Library/Application Support/PrepareMe/documents")
let pairingFolder = take("--pairing", &arguments).map { URL(fileURLWithPath: $0) }
    ?? given?.appendingPathComponent(PairingDesk.folderName)
    ?? home.appendingPathComponent("Library/Application Support/PrepareMe/\(PairingDesk.folderName)")
let loopback = flag("--loopback", &arguments)  // serve on 127.0.0.1 only, not advertised: the simulator's test
// on the home network, for PrepareMe Dev on a spare device (Unlisted plan, phase 3; its rules: ServiceCommandLine)
_ = flag("--home-network", &arguments)
let testService = ServiceCommandLine.isTestService(support: given, home: home)
let port = givenPort ?? (arguments.first == "library" ? libraryPort : defaultPort)  // every flag taken by now
let served = support.appendingPathComponent("files")
let tokens = TokenStore(url: support.appendingPathComponent("tokens.json"))
let counts = CountsStore(url: jobs.appendingPathComponent("probe-counts.json"))

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date())
}

func say(_ line: String) {
    if let agentLog {
        agentLog.add("\(stamp())  \(line)")
        return
    }
    print("\(stamp())  \(line)")
    fflush(stdout)
}

/// The Mac's identity, or the reason it can't be loaded, in fixed words.
func loadIdentity() -> (identity: SecIdentity, fingerprint: String) {
    do {
        return try Identity.load(from: support)
    } catch {
        fail((error as? Identity.Problem)?.line ?? "the Mac's identity couldn't be loaded")
    }
}

func swapNow(damaged: Bool) {
    do {
        let made = try ProbeFile.swap(folder: served, id: try ProbeFile.id(in: support), bytes: bytes,
                                      damaged: damaged)
        say("new made-up file: \(made.size >> 20) MB, SHA-256 starts \(made.sha256.prefix(12))"
            + (damaged ? "; its served copy is one byte off (a phone must refuse it)" : ""))
    } catch ProbeFile.SwapProblem.anotherSwapRunning {
        say("another swap is running; nothing changed")
    } catch {
        say("the made-up file couldn't be swapped: \(type(of: error))")
    }
}

guard let command = arguments.first else {
    fail(ServiceCommandLine.usage, 2)
}
arguments.removeFirst()

switch command {
case "init":
    do {
        try Identity.make(in: support)
    } catch Identity.Problem.exists {
        fail("the Mac's identity is already made; making a new one would unpair every phone, so nothing changed")
    } catch {
        fail("the identity couldn't be made: \(error)")
    }
    let (_, fingerprint) = loadIdentity()
    say("identity made; certificate SHA-256 starts \(fingerprint.prefix(12))")
    swapNow(damaged: false)

case "pair":
    let asText = flag("--text", &arguments)
    let readOnly = flag("--read-only", &arguments)
    let (_, fingerprint) = loadIdentity()
    guard let host = MacPairing.bonjourHost() else { fail("the Mac's network name couldn't be read") }
    let (label, token) = try tokens.add(now: Date(), readOnly: readOnly)
    let code = PairingCode(host: host, ip: MacPairing.privateIPv4(), port: Int(port), fp: fingerprint, token: token,
                           test: testService)
    let text = try code.text()
    if asText {
        print(text)
    } else if let picture = MacPairing.terminalQR(text) {
        print(picture)
    } else {
        fail("the QR code couldn't be drawn; try `pair --text`")
    }
    print("Scan this with the app on the phone (PrepareMe, or the probe). It is \(label). Close this window once the "
          + "phone says paired.")

case "phones":
    let phones = (try? tokens.phones()) ?? []
    if phones.isEmpty { print("no phones paired") }
    for phone in phones { print("\(phone.label), paired \(phone.added)" + (phone.readOnly == true ? ", read-only" : "")) }

case "unpair":
    guard let label = arguments.first else { fail("unpair takes a label, like \"phone 1\"", 2) }
    print(try tokens.remove(label: label) ? "\(label) unpaired" : "no phone is called \(label)")

case "swap":
    swapNow(damaged: flag("--damaged", &arguments))

case "count-alerts":
    guard let path = arguments.first, let data = FileManager.default.contents(atPath: path) else {
        fail("count-alerts takes a saved api.weather.gov answer", 2)
    }
    do {
        let found = try NWSAlerts.count(data)
        print("alerts \(found.alerts), events \(found.events), no VTEC \(found.noVTEC)")
    } catch {
        fail("couldn't read: \(error)")
    }

case "bend-once":
    guard let name = arguments.first else { fail("bend-once takes a file name from the library's manifest", 2) }
    do {
        try BendOnce(url: support.appendingPathComponent(BendOnce.name)).request(name)
    } catch {
        fail("not a file name the library could serve: nothing changed", 2)
    }
    say("the library's next download of \(name) will arrive one byte off; the file itself is unchanged")

case "library":
    /// The barcode keys for adults' devices (Unlisted plan, phase 4): the Mac app's own, from the Info.plist of the
    /// PrepareMe.app this program sits in (Contents/MacOS), where its install put them; a test service's (own
    /// --support) from a made-up `lookup-keys.json` there instead, so a session never reads the owner's. Never printed.
    func lookupKeys() -> LookupKeys? {
        if testService {
            return given.flatMap { try? Data(contentsOf: $0.appendingPathComponent("lookup-keys.json")) }
                .flatMap { try? LookupKeys.read($0) }
        }
        guard let program = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let info = program.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let found = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return LookupKeys(info: found)
    }
    let (identity, fingerprint) = loadIdentity()
    let router = Router(folder: library, tokens: tokens, counts: counts, manifestOnly: true,
                        bend: BendOnce(url: support.appendingPathComponent(BendOnce.name)),
                        feedCounts: FeedCountsStore(url: jobs.appendingPathComponent("phone-feed-counts.json")),
                        inventory: inventoryFolder,
                        backupKey: pairingFolder.appendingPathComponent(BackupSignature.publicKeyFileName),
                        pairing: pairingFolder, documents: documentsFolder, servesDev: testService,
                        lookupKeys: lookupKeys())
    let server = FileServer(router: router, identity: identity, port: port, advertise: false, loopbackOnly: loopback,
                            log: say)
    try server.start { problem in
        if let problem {
            say("couldn't start: \(problem)")
            exit(1)  // launchd starts it again
        }
        say("serving the library on port \(port), certificate SHA-256 starts \(fingerprint.prefix(12))")
    }
    // The Mac app's pairing requests (plan phase 10), on main like everything else here: one at a time
    let clerk = PairingClerk(desk: PairingDesk(folder: pairingFolder), tokens: tokens, fingerprint: fingerprint,
                             port: Int(port), test: testService, host: { MacPairing.bonjourHost() },
                             ip: { loopback ? "127.0.0.1" : MacPairing.privateIPv4() })
    do {
        try PairingDesk.makeFolder(pairingFolder)
    } catch {
        say("the pairing folder couldn't be made, so the Mac app can't pair phones: \(type(of: error))")
    }
    let desk = DispatchSource.makeTimerSource(queue: .main)
    desk.schedule(deadline: .now(), repeating: 1)
    desk.setEventHandler { clerk.tick(now: Date(), log: say) }
    desk.resume()
    for stopping in [SIGINT, SIGTERM] {  // Control-C by hand, SIGTERM from launchd
        signal(stopping, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: stopping, queue: .main)
        source.setEventHandler {
            server.stop()
            say("stopped")
            exit(0)
        }
        source.resume()
        stops.append(source)
    }
    dispatchMain()

case "serve":
    let (identity, fingerprint) = loadIdentity()
    let router = Router(folder: served, tokens: tokens, counts: counts, servesDev: testService)
    let server = FileServer(router: router, identity: identity, port: port, loopbackOnly: loopback, log: say)
    try server.start { problem in
        if let problem {
            say("couldn't start: \(problem)")
            exit(1)
        }
        say("serving on port \(port), certificate SHA-256 starts \(fingerprint.prefix(12)); Control-C stops it")
    }
    let daily = DispatchSource.makeTimerSource(queue: .main)  // main: the swap reads the command's settings
    daily.schedule(deadline: .now(), repeating: 600)
    daily.setEventHandler {
        let written = ProbeFile.writtenAt(folder: served)
        if written == nil || Date().timeIntervalSince(written!) >= swapEvery { swapNow(damaged: false) }
    }
    daily.resume()
    signal(SIGINT, SIG_IGN)
    let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    stop.setEventHandler {
        server.stop()
        say("stopped")
        exit(0)
    }
    stop.resume()
    dispatchMain()

default:
    fail("unknown command: \(command)", 2)
}
