import Foundation

/// prepareme-service's command line, checked whole before main.swift reads any of it or touches a folder (FINDINGS
/// F-087: the command came from the first word and options it didn't know were ignored, so `pair --help` paired a
/// phone on the real service folder). Each command takes only its own options, each at most once, and a valued option
/// needs its value; `--help` and `-h` are refused like any other unknown option, and `help` prints the usage.
///
/// From a Claude Code session (its shells carry `CLAUDECODE`) every command but `count-alerts` must name its own
/// folders, and none may be in or under Application Support › PrepareMe: the real folders are PrepareMe.app's and the
/// owner's. Outside a session (the owner's Terminal, the app's launch agent) nothing about where it works changes.
public enum ServiceCommandLine {
    public enum Verdict: Equatable, Sendable {
        case run
        case help
        /// The line to print before the usage; the command exits 2 having done nothing.
        case refused(String)
    }

    public static let usage = "usage: prepareme-service init | pair [--text] [--read-only] [--port N] | phones | "
        + "unpair LABEL | serve [--loopback] [--port N] | swap [--damaged] | count-alerts FILE | "
        + "library [--folder DIR] [--inventory DIR] [--pairing DIR] [--documents DIR] [--loopback | --home-network] "
        + "[--port N] "
        + "[--agent] | "
        + "bend-once NAME | help; each also takes --support DIR and --jobs DIR, and init, serve and swap --size-mb N"

    struct Shape {
        var flags: Set<String> = []
        var values: Set<String> = []
        var words = 0  // at most this many words after the command
        var folders: [String] = ["--support"]  // what a session must name itself
    }

    static let everywhere: Set<String> = ["--support", "--jobs"]
    static let shapes: [String: Shape] = [
        "init": Shape(values: ["--size-mb"]),
        "pair": Shape(flags: ["--text", "--read-only"], values: ["--port"]),
        "phones": Shape(),
        "unpair": Shape(words: 1),
        "serve": Shape(flags: ["--loopback"], values: ["--port", "--size-mb"]),
        "swap": Shape(flags: ["--damaged"], values: ["--size-mb"]),
        "count-alerts": Shape(words: 1, folders: []),
        "library": Shape(flags: ["--loopback", "--agent", "--home-network"],
                         values: ["--port", "--folder", "--inventory", "--pairing", "--documents"],
                         folders: ["--support", "--folder", "--inventory"]),
        "bend-once": Shape(words: 1),
    ]
    static let folderOptions = ["--support", "--jobs", "--folder", "--inventory", "--pairing", "--documents"]
    static let allValues: Set<String> = everywhere.union(["--port", "--size-mb", "--folder", "--inventory", "--pairing",
                                                          "--documents"])

    /// `session`: run from a Claude Code session. `home`: the account's own home folder (RealHome).
    public static func check(_ arguments: [String], session: Bool, home: URL) -> Verdict {
        var command: String?
        var words = 0
        var seen: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            guard word.hasPrefix("-") else {
                if command == nil { command = word } else { words += 1 }
                continue
            }
            if seen[word] != nil { return .refused("\(word) was given twice: nothing was done") }
            if allValues.contains(word) {
                guard index < arguments.count, !arguments[index].hasPrefix("-"), !arguments[index].isEmpty else {
                    return .refused("\(word) needs a value after it: nothing was done")
                }
                seen[word] = arguments[index]
                index += 1
            } else {
                seen[word] = ""
            }
        }
        guard let command else { return .refused("no command: nothing was done") }
        if command == "help" {
            return seen.isEmpty && words == 0 ? .help : .refused("help takes nothing after it: nothing was done")
        }
        guard let shape = shapes[command] else { return .refused("unknown command: nothing was done") }
        for option in seen.keys.sorted() where !shape.flags.union(shape.values).union(everywhere).contains(option) {
            return .refused("\(command) doesn't take \(option): nothing was done")
        }
        if words > shape.words { return .refused("\(command) takes fewer words after it: nothing was done") }
        if seen["--home-network"] != nil, let refusal = homeNetworkRefusal(seen) { return .refused(refusal) }
        guard session else { return .run }
        for option in shape.folders where seen[option] == nil {
            return .refused("from a Claude Code session, \(command) needs \(shape.folders.joined(separator: ", ")) "
                            + "in a scratch folder: nothing was done")
        }
        let real = folded(home.appendingPathComponent("Library/Application Support/PrepareMe"))
        for option in folderOptions {
            guard let path = seen[option] else { continue }
            let given = folded(URL(fileURLWithPath: path))
            if given == real || given.hasPrefix(real + "/") {
                return .refused("from a Claude Code session, \(option) can't be PrepareMe's real folder: "
                                + "nothing was done")
            }
        }
        return .run
    }

    /// Unlisted plan, phase 3 (decision 8): `library --home-network`, the test service a spare device reaches over home
    /// Wi-Fi, for PrepareMe Dev and made-up libraries only. From anywhere, a session or not: a port that isn't the
    /// family's, every folder named, each a scratch folder under the Mac's temporary folders (kiwix-mac/build.sh's rule
    /// for the check build), and never with --loopback. Nil when it may start.
    static func homeNetworkRefusal(_ seen: [String: String]) -> String? {
        if seen["--loopback"] != nil { return "--home-network and --loopback can't both be given: nothing was done" }
        guard let port = seen["--port"], let number = Int(port), number != 8743, number != 8744 else {
            return "--home-network needs its own --port, not 8743 or 8744 (the family's): nothing was done"
        }
        for option in ["--support", "--folder", "--inventory", "--pairing", "--documents"] {
            guard let path = seen[option] else {
                return "--home-network needs --support, --folder, --inventory, --pairing and --documents, "
                    + "each a scratch folder: nothing was done"
            }
            // links followed; Foundation may then drop "/private", so both spellings of the two folders count
            let given = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"]
                .contains(where: { given.hasPrefix($0) && given != $0 })
            else {
                return "--home-network takes scratch folders under /private/tmp or the temporary folder only, "
                    + "and \(option) isn't one: nothing was done"
            }
        }
        return nil
    }

    /// Unlisted plan, phase 3: a test service is one started with its own `--support` folder, which every session's
    /// must be; the family's Mac's service (PrepareMe.app's launch agent) never is. A test service's codes carry the
    /// test mark, version 2 (PairingCode), and it serves PrepareMe Dev (Router.servesDev).
    public static func isTestService(support: URL?, home: URL) -> Bool {
        guard let support else { return false }
        return folded(support) != folded(home.appendingPathComponent("Library/Application Support/PrepareMe/service"))
    }

    /// A path as the disk compares it: `..` and links worked out, case ignored (APFS ignores it by default).
    static func folded(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }
}
