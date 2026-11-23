import Foundation

/// A Weather Service alert's tier and its full text tidied for reading (the Today redesign's rulings 1 and 2; plan
/// phase 2), as the Mac's page does them (dashboard/weather.py `tier` and `tidy`), held to them by the shared cases'
/// `tiers` and `tidy` (dashboard/tests/phone_cases.py). Neither changes what is stored: the tier is read from the item's
/// code, and the tidy is done only when the page is written.
public enum NWSTidy {
    public static let warn = "warn", look = "look"
    /// The shortest line the Weather Service is taken to have wrapped (weather.py TIDY_WRAP).
    static let wrap = 50

    /// `warn` for a code whose significance is W (a warning, the critical one: F10 and the owner's choice 1 of phase L,
    /// 2026-10-20; a watch was too from fix 6, 2026-10-16), for "" (no line in force, or no VTEC at all) and for any code
    /// not of the PP.S shape; `look` (worth a look, amber) for every other significance letter, a watch's included.
    public static func tier(_ code: String) -> String {
        guard let dot = code.firstIndex(of: ".") else { return warn }
        let significance = code[code.index(after: dot)...]
        guard significance.count == 1, let letter = significance.first, letter.isASCII, letter.isUppercase,
              letter != "W" else { return warn }
        return look
    }

    /// The band's share of the iPhone SE's first screen (weather.py INSTRUCTION_CHARS; beta run 2, R9.1).
    public static let instructionChars = 120
    static let blankLine = try! NSRegularExpression(pattern: "\n\\s*\n")
    /// weather.py `_ABBREVIATION` (R9.1 fix round 1), and `_ACTION` and `_governed` (the lead's ruling on checkpoint 4's
    /// re-review: an action word counts anywhere unless a future or likelihood word governs it).
    static let abbreviation = try! NSRegularExpression(
        pattern: "^(?:(?:[A-Z]\\.)+|(?:[a-z]\\.){2,}|(?i:hwy|st|rd|mt|co|ave|blvd|rte|rt|ft|dr|ln|no|hwys)\\.)$")
    static let action = try! NSRegularExpression(
        pattern: "(?i)\\b(?:take cover|move|go to|go inside|go indoors|get to|get out|get inside|head to|evacuate|"
            + "turn around|do not|don't|don’t|stay|leave|seek|shelter|avoid|climb)\\b(?!\\s+tuned\\b)")
    static let future: Set = ["will", "would", "may", "might", "could", "can"]
    static let likely = try! NSRegularExpression(pattern: "^(?:expected|likely|forecast|continues?|continuing)$")
    static let wordEdges = CharacterSet(charactersIn: ".,;:!?\"'“”‘’()")

    /// weather.py `_governed`: will, would, may, might, could or can among the two words before the action word in its
    /// clause, or "expected/likely/forecast/continue to" ending there; "and" and "or" not counted.
    static func governed(_ before: String) -> Bool {
        let clause = before.split(omittingEmptySubsequences: false) { ",;:".contains($0) }.last.map(String.init) ?? ""
        let words = Array(clause.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: wordEdges).lowercased() }
            .filter { !$0.isEmpty && $0 != "and" && $0 != "or" }.suffix(3))
        if words.suffix(2).contains(where: future.contains) { return true }
        return (max(1, words.count - 2)..<max(1, words.count)).contains { words[$0] == "to" && hits(likely, in: words[$0 - 1]) }
    }

    /// weather.py `says_what_to_do`: an action word no future or likelihood word governs.
    static func saysWhatToDo(_ sentence: String) -> Bool {
        action.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)).contains { found in
            guard let at = Range(found.range, in: sentence) else { return false }
            return !governed(String(sentence[..<at.lowerBound]))
        }
    }

    static func hits(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// weather.py `_sentences`: each ends at a word ending in . ! or ?, never at an abbreviation.
    static func sentences(_ words: [Substring]) -> [String] {
        var found: [String] = [], current: [Substring] = []
        for word in words {
            current.append(word)
            guard let last = word.last, ".!?".contains(last) else { continue }
            let bare = String(word.drop { "(\"'“‘".contains($0) })
            if last == "." && hits(abbreviation, in: bare) { continue }
            found.append(current.joined(separator: " "))
            current = []
        }
        return found + (current.isEmpty ? [] : [current.joined(separator: " ")])
    }

    /// An alert's own instruction as the band shows it, and whether any of it was left out (weather.py
    /// `instruction_words`): its first paragraph, its line breaks and runs of spaces as one space, whole sentences
    /// through the first that says what to do (the first when none does), then as many more as fit in
    /// `instructionChars` (counted as Python counts, by code point); when the sentences before that first one don't
    /// fit with it, it shows alone (checkpoint 4's hard budget); ("", false) for none.
    public static func instruction(_ text: String) -> (said: String, cut: Bool) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let ns = normalized as NSString
        var parts: [String] = [], at = 0
        for found in blankLine.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: at, length: found.range.location - at)))
            at = found.range.location + found.range.length
        }
        parts.append(ns.substring(from: at))
        let paragraphs = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = paragraphs.first else { return ("", false) }
        let all = sentences(first.split(whereSeparator: \.isWhitespace))
        let act = all.firstIndex { saysWhatToDo($0) } ?? 0
        var kept = Array(all.prefix(act + 1))
        if kept.joined(separator: " ").unicodeScalars.count > instructionChars { kept = [all[act]] }
        for sentence in all.dropFirst(act + 1) {
            guard (kept + [sentence]).joined(separator: " ").unicodeScalars.count <= instructionChars else { break }
            kept.append(sentence)
        }
        return (kept.joined(separator: " "), kept.count < all.count || paragraphs.count > 1)
    }

    static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: "^(?:\(pattern))$") }

    static let ugc = regex("[A-Z]{2}[CZ](?:[0-9]{3}|ALL)(?:[->](?:[A-Z]{2}[CZ])?[0-9]{3})*-(?:[0-9]{3}[->])*(?:[0-9]{6}-)?")
    static let ugcMore = regex("(?:(?:[A-Z]{2}[CZ])?[0-9]{3}[->])+(?:[0-9]{6}-)?|[0-9]{6}-")
    static let ugcEnd = try! NSRegularExpression(pattern: "(?:^|[->])[0-9]{6}-$")
    static let pVTEC = regex("/[OTEX]\\.[A-Z]{3}\\.[A-Z]{4}\\.[A-Z]{2}\\.[A-Z]\\.[0-9]{4}\\.[0-9]{6}T[0-9]{4}Z-[0-9]{6}T[0-9]{4}Z/")
    static let hVTEC = regex("/[0-9A-Z]{5}\\.[0-9NU]\\.[A-Z]{2}\\.[0-9]{6}T[0-9]{4}Z\\.[0-9]{6}T[0-9]{4}Z\\.[0-9]{6}T[0-9]{4}Z\\.[A-Z]{2}/")
    static let wmoSequence = regex("[0-9]{3}")
    static let wmoHeading = regex("[A-Z]{4}[0-9]{2} [A-Z]{4} [0-9]{6}(?: [A-Z]{3})?")
    static let awipsID = regex("[A-Z0-9]{4,6}")
    static let signature = regex("Forecaster:? [A-Za-z][A-Za-z.'/ -]{0,38}|[A-Za-z][A-Za-z'/-]*(?: [A-Za-z][A-Za-z'/-]*)?"
                                 + "|[A-Z](?:\\.[A-Z])+\\.?")  // weather.py _SIGNATURE
    static let signatureLongest = 20  // weather.py SIGNATURE_LONGEST

    /// Whether a line after a product's last $$ is the forecaster's mark (weather.py `_signature`).
    static func isSignature(_ line: String) -> Bool {
        matches(signature, line) && (line.hasPrefix("Forecaster") || line.count <= signatureLongest)
    }

    static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `text`, an alert's full text, tidied: its WMO header, UGC and VTEC lines and "$$" and "&&" gone; paragraphs
    /// joined by a blank line; inside one, a line joined to the one before with one space only where the Weather
    /// Service wrapped it; each line's own spaces at its ends gone; no word or digit changed.
    public static func tidy(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = lines.lastIndex(of: "$$") {  // a forecaster's name or initials after the last $$ (Task 8.1, F09)
            let tail = lines[(last + 1)...].filter { !$0.isEmpty }
            if tail.count <= 3 && tail.allSatisfy(isSignature) { lines = Array(lines[...last]) }
        }
        var start = 0
        if lines.count > 1 && matches(wmoSequence, lines[0]) && matches(wmoHeading, lines[1]) {
            start = 2
        } else if let first = lines.first, matches(wmoHeading, first) {
            start = 1
        }
        if start > 0 && start < lines.count && matches(awipsID, lines[start]) { start += 1 }
        var kept: [String] = [], inUGC = false
        for line in lines.dropFirst(start) {
            if matches(ugc, line) || (inUGC && matches(ugcMore, line)) {
                inUGC = !matches(ugcEnd, line)  // a group runs on until its expiry
                continue
            }
            inUGC = false
            if matches(pVTEC, line) || matches(hVTEC, line) || line == "$$" || line == "&&" { continue }
            kept.append(line)
        }
        var paragraphs: [String] = [], current: [String] = []
        for line in kept + [""] {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
                current = []
            } else if let before = current.last, wrapped(before, line) {
                current[current.count - 1] = before + " " + line
            } else {
                current.append(line)
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Whether `line` continues `before` where the Weather Service wrapped it (weather.py `_wrapped`).
    static func wrapped(_ before: String, _ line: String) -> Bool {
        if line.hasPrefix("* ") || line.hasPrefix("...") || before.contains("  ") || line.contains("  ") { return false }
        if before.hasPrefix("...") && !before.hasSuffix("...") { return true }  // a headline runs on to its "..."
        return before.unicodeScalars.count >= wrap && !before.hasSuffix(".") && !before.hasSuffix(":")  // Python's len
    }

    // MARK: Plain headlines (remaining-findings plan, Task 8.1; F09, owner 2026-10-18; weather.py's, held to it by the
    // shared cases' `plain`)

    static let phenomena = ["BZ": "Blizzard", "CF": "Coastal Flood", "DS": "Dust Storm", "DU": "Blowing Dust",
                            "EC": "Extreme Cold", "EH": "Excessive Heat", "XH": "Extreme Heat", "FF": "Flash Flood",
                            "FG": "Dense Fog", "FL": "Flood", "FR": "Frost", "FZ": "Freeze", "HT": "Heat",
                            "HU": "Hurricane", "HW": "High Wind", "HZ": "Hard Freeze", "IS": "Ice Storm",
                            "RP": "Rip Current", "SM": "Dense Smoke", "SQ": "Snow Squall", "SS": "Storm Surge",
                            "SU": "High Surf", "SV": "Severe Thunderstorm", "TO": "Tornado", "TR": "Tropical Storm",
                            "TS": "Tsunami", "WC": "Wind Chill", "WI": "Wind", "WS": "Winter Storm",
                            "WW": "Winter Weather", "ZR": "Freezing Rain", "BH": "Beach Hazards",
                            "AS": "Air Stagnation", "LW": "Lake Wind", "FA": "Flood",
                            "EW": "Extreme Wind", "CW": "Cold Weather", "LE": "Lake Effect Snow",
                            "ZF": "Freezing Fog", "AF": "Ashfall", "DF": "Debris Flow", "LS": "Lakeshore Flood",
                            "TY": "Typhoon", "LO": "Low Water", "SC": "Small Craft", "BW": "Brisk Wind",
                            "GL": "Gale", "SE": "Hazardous Seas", "SR": "Storm", "HF": "Hurricane Force Wind",
                            "ZY": "Freezing Spray", "UP": "Heavy Freezing Spray", "MF": "Dense Fog",
                            "MS": "Dense Smoke", "MH": "Ashfall"]
    static let significance = ["W": "Warning", "A": "Watch", "Y": "Advisory", "S": "Statement"]
    static let namedCodes = ["FW.W": "Red Flag Warning", "FW.A": "Fire Weather Watch", "MA.W": "Special Marine Warning",
                             "MA.S": "Marine Weather Statement", "HY.Y": "Hydrologic Advisory",
                             "HY.S": "Hydrologic Statement", "BH.S": "Beach Hazards Statement"]
    /// Time words, and every state's and territory's two letters but the six that are English words in a headline in
    /// capitals (IN effect, OR, ME, OK, HI, OH; American Samoa's AS is left out too), so the list singles out no state
    /// (Unlisted plan, phase 4): the Mac's `_KEEP_CAPS`, pinned by the shared cases' copy
    static let keepCaps: Set<String> = Set(["AM", "PM", "EDT", "EST", "CDT", "CST", "MDT", "MST", "PDT", "PST", "UTC",
                                            "NWS", "US"])
        .union(Set(TravelMaps.stateNames.keys).union(["PR", "GU", "VI", "MP"])
               .subtracting(["IN", "OR", "ME", "OK", "HI", "OH"]))
    /// Days, months, and every ocean or sea a weather text names, not one (the Mac's `_PROPER`)
    static let proper: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                      "january", "february", "march", "april", "june", "july", "august", "september",
                                      "october", "november", "december", "atlantic", "pacific", "arctic", "caribbean",
                                      "gulf"]
    public static let tropicalQuiet = "No Atlantic storms expected in the next 7 days."
    public static let tropicalChance = "A storm could form in the Atlantic in the next 7 days."
    public static let tropicalActive = "A storm is active in the Atlantic."
    public static let tropicalActiveChance = "A storm is active in the Atlantic, and another could form in the next 7 days."
    public static let tropicalLow = "A low chance a storm forms in the Atlantic in the next 7 days."
    public static let tropicalSee = "Atlantic outlook: read the full text."
    /// A line cancelled, expired or upgraded, never named (weather.py _ENDED)
    static let ended: Set<String> = ["CAN", "EXP", "UPG"]
    static let emergency = try! NSRegularExpression(pattern: "\\b((?:TORNADO|FLASH FLOOD|FLOOD|STORM SURGE|HURRICANE"
                                                    + "|EXTREME WIND) EMERGENCY|PARTICULARLY DANGEROUS SITUATION)\\b")
    static let lowChance = try! NSRegularExpression(pattern: "Formation chance through 7 days\\.\\.\\.low")
    static let advisories = try! NSRegularExpression(
        pattern: "issuing (?:advisories|public advisories)|advisories are being issued", options: [.caseInsensitive])
    static let notExpected = try! NSRegularExpression(pattern: "formation is not expected", options: [.caseInsensitive])
    static let clock = try! NSRegularExpression(pattern: "\\b([0-9]{1,2})([0-5][0-9]) (AM|PM)\\b")
    static let clockWord = regex("[0-9]{1,4}")
    static let chance = try! NSRegularExpression(pattern: "Formation chance through 7 days\\.\\.\\.(?:medium|high)")
    /// Every product name, longest first, each with its whole-word pattern, case folded (sentenceCase restores them)
    static let names: [(String, NSRegularExpression)] = {
        var all = Set(namedCodes.values)
        for p in phenomena.values { for g in significance.values { all.insert("\(p) \(g)") } }
        return all.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.map {
            ($0, try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b",
                                          options: [.caseInsensitive]))
        }
    }()

    /// A VTEC code's product name ("TO.W" -> "Tornado Warning"), or "" when it isn't listed (weather.py `code_name`).
    public static func codeName(_ code: String) -> String {
        if let named = namedCodes[code] { return named }
        let parts = code.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let p = phenomena[parts[0]], let g = significance[parts[1]] else { return "" }
        return "\(p) \(g)"
    }

    /// A headline as a person writes it (weather.py `sentence_case`).
    public static func sentenceCase(_ raw: String) -> String {
        var text = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).replacingOccurrences(of: "...", with: ", ")
        if text.isEmpty || text.contains(where: \.isLowercase) { return text }
        let originals = text.components(separatedBy: " ")
        let words = text.lowercased().components(separatedBy: " ")
        let punctuation = CharacterSet(charactersIn: ",.;:")
        func bare(_ word: String) -> String { word.trimmingCharacters(in: punctuation) }
        var out: [String] = []
        for (n, word) in words.enumerated() {
            let b = bare(word)
            var shown = word
            if b.contains(where: \.isNumber) && !matches(clockWord, b) {
                shown = originals[n]
            } else if keepCaps.contains(b.uppercased()) {
                shown = b.isEmpty ? word : word.replacingOccurrences(of: b, with: b.uppercased())
            } else if proper.contains(b) || b == "county" || b == "counties"
                        || (n + 1 < words.count && ["county", "counties"].contains(bare(words[n + 1]))) {
                shown = b.isEmpty ? word : word.replacingOccurrences(of: b, with: b.prefix(1).uppercased() + b.dropFirst())
            }
            out.append(shown)
        }
        if let first = out.first { out[0] = first.prefix(1).uppercased() + first.dropFirst() }
        var said = out.joined(separator: " ")
        for (name, pattern) in names {
            said = pattern.stringByReplacingMatches(in: said, range: NSRange(said.startIndex..., in: said),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: name))
        }
        return clock.stringByReplacingMatches(in: said, range: NSRange(said.startIndex..., in: said),
                                              withTemplate: "$1:$2 $3")
    }

    /// An NWS product's plain headline: its hazards not cancelled, expired or upgraded by name, joined with commas;
    /// else its own headline in sentence case; an emergency or a particularly dangerous situation leads (weather.py
    /// `alert_headline`).
    public static func alertHeadline(_ text: String, vtec: [String], detail: String = "") -> String {
        var names: [String] = []
        for event in vtec {
            let parts = event.components(separatedBy: ".")
            guard parts.count >= 4, !ended.contains(parts[0]) else { continue }
            let name = codeName("\(parts[2]).\(parts[3])")
            if name.isEmpty { names = []; break }
            if !names.contains(name) { names.append(name) }
        }
        let base = names.isEmpty ? sentenceCase(text) : names.joined(separator: ", ")
        let both = text + "\n" + detail
        guard let found = emergency.firstMatch(in: both, range: NSRange(both.startIndex..., in: both)),
              let range = Range(found.range(at: 1), in: both) else { return base }
        let said = both[range].capitalized
        if !names.isEmpty { return "\(said) (\(base))" }
        return base.lowercased().contains(said.lowercased()) ? base : "\(said): \(base)"
    }

    /// NHC's Atlantic outlook in one plain line (weather.py `tropical_headline`): an active storm first, never quiet
    /// without NHC's own "not expected".
    public static func tropicalHeadline(_ text: String) -> String {
        if found(advisories, text) { return found(chance, text) ? tropicalActiveChance : tropicalActive }
        if found(chance, text) { return tropicalChance }
        if found(notExpected, text) { return tropicalQuiet }
        return found(lowChance, text) ? tropicalLow : tropicalSee
    }

    static func found(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
