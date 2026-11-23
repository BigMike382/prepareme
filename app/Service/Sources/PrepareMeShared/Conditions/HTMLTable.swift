import Foundation

/// The rows of a page's first `<table>` with a given id, each a list of its cells' text: the Mac's
/// `dashboard/local.py` `table_rows`, which the state's outage and evacuation feeds go through.
///
/// A cell's lines break where a block (br, p, div, li, a heading) does; a line's spaces are collapsed and empty lines
/// dropped. A table inside a cell is read as more lines of that cell. Scripts, styles and comments are skipped;
/// character references are decoded (the common named ones and every numeric one). nil when there is no such table.
/// The shared cases (Fixtures/conditions/cases.json, written by the Mac's own reader) hold the two to the same rows.
public enum HTMLTable {
    static let breaks: Set<String> = ["br", "p", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "hr"]
    static let rowParts: Set<String> = ["tr", "td", "th"]

    public static func rows(_ page: String, id wanted: String) -> [[String]]? {
        var reader = Reader(wanted: wanted)
        for token in Tokens(page) {
            switch token {
            case let .start(name, attributes): reader.start(name, attributes)
            case let .end(name): reader.end(name)
            case let .text(text): reader.text(text)
            }
        }
        return reader.finish()
    }

    struct Reader {
        let wanted: String
        var depth = 0, done = false, skipping = 0
        var rows: [[String]]?
        var cells: [String]?
        var parts: [String]?

        init(wanted: String) { self.wanted = wanted }

        mutating func start(_ tag: String, _ attributes: [String: String]) {
            if tag == "script" || tag == "style" { skipping += 1; return }
            if done { return }
            if tag == "table" {
                if depth > 0 {
                    depth += 1
                    lineBreak()
                } else if attributes["id"] == wanted {
                    depth = 1
                    rows = []
                }
                return
            }
            guard depth > 0 else { return }
            if depth > 1 {
                if HTMLTable.rowParts.contains(tag) || HTMLTable.breaks.contains(tag) { lineBreak() }
            } else if tag == "tr" {
                endRow()
                cells = []
            } else if tag == "td" || tag == "th" {
                endCell()
                parts = []
            } else if HTMLTable.breaks.contains(tag) {
                lineBreak()
            }
        }

        mutating func end(_ tag: String) {
            if tag == "script" || tag == "style" { skipping = max(0, skipping - 1); return }
            if done || depth == 0 { return }
            if tag == "table" {
                depth -= 1
                if depth == 0 {
                    endRow()
                    done = true
                } else {
                    lineBreak()
                }
            } else if depth > 1 {
                if HTMLTable.rowParts.contains(tag) || HTMLTable.breaks.contains(tag) { lineBreak() }
            } else if tag == "td" || tag == "th" {
                endCell()
            } else if tag == "tr" {
                endRow()
            } else if HTMLTable.breaks.contains(tag) {
                lineBreak()
            }
        }

        mutating func text(_ data: String) {
            guard depth > 0, skipping == 0, parts != nil else { return }
            // A line break in the source is a space on the page.
            parts!.append(String(data.map { $0.isWhitespace ? " " : $0 }))
        }

        mutating func finish() -> [[String]]? {
            if depth > 0 && !done { endRow() }  // a table never closed: what was read
            return rows
        }

        mutating func lineBreak() {
            if parts != nil { parts!.append("\n") }
        }

        mutating func endCell() {
            guard let found = parts else { return }
            let lines = found.joined().components(separatedBy: "\n").map(\.collapsed).filter { !$0.isEmpty }
            if cells == nil { cells = [] }
            cells!.append(lines.joined(separator: "\n"))
            parts = nil
        }

        mutating func endRow() {
            endCell()
            if let found = cells {
                rows?.append(found)
                cells = nil
            }
        }
    }

    enum Token: Equatable {
        case start(String, [String: String])
        case end(String)
        case text(String)
    }

    /// The page as start tags, end tags and text, as Python's HTMLParser sees them for these pages: tag and attribute
    /// names lowercased, attribute values and text with character references decoded, comments, declarations and
    /// processing instructions dropped, a script's or style's content read as raw text to its end tag.
    struct Tokens: Sequence, IteratorProtocol {
        let scalars: [Character]
        var at = 0
        var pending: [Token] = []

        init(_ page: String) { scalars = Array(page) }

        mutating func next() -> Token? {
            if !pending.isEmpty { return pending.removeFirst() }
            guard at < scalars.count else { return nil }
            if scalars[at] == "<", let token = tag() { return token }
            var text = ""
            repeat {
                text.append(scalars[at])
                at += 1
            } while at < scalars.count && !(scalars[at] == "<" && looksLikeMarkup(at))
            return .text(Entities.decode(text))
        }

        func looksLikeMarkup(_ i: Int) -> Bool {
            guard i + 1 < scalars.count else { return false }
            let next = scalars[i + 1]
            return next.isLetter || next == "/" || next == "!" || next == "?"
        }

        /// The markup at `at` (which is "<"), or nil when it isn't markup (a lone "<" is text).
        mutating func tag() -> Token? {
            guard looksLikeMarkup(at) else { return nil }
            let next = scalars[at + 1]
            if next == "!" {
                if starts(with: "<!--") {
                    at = index(of: "-->", from: at + 4).map { $0 + 3 } ?? scalars.count
                } else {
                    at = index(of: ">", from: at).map { $0 + 1 } ?? scalars.count
                }
                return self.next()
            }
            if next == "?" {
                at = index(of: ">", from: at).map { $0 + 1 } ?? scalars.count
                return self.next()
            }
            let closing = next == "/"
            var i = at + (closing ? 2 : 1)
            var name = ""
            while i < scalars.count, !scalars[i].isWhitespace, scalars[i] != ">", scalars[i] != "/" {
                name.append(scalars[i])
                i += 1
            }
            name = name.lowercased()
            guard let close = closingBracket(from: i) else {
                at = scalars.count
                return nil
            }
            let inside = String(scalars[i..<close])
            at = close + 1
            if closing { return .end(name) }
            let start = Token.start(name, Self.attributes(inside))
            if name == "script" || name == "style" {  // raw text to its end tag
                let end = index(ofCaseless: "</\(name)", from: at) ?? scalars.count
                if end > at { pending.append(.text(String(scalars[at..<end]))) }
                at = end
            }
            return start
        }

        /// The ">" that closes a tag starting before `from`, skipping quoted attribute values.
        func closingBracket(from: Int) -> Int? {
            var quote: Character?
            var i = from
            while i < scalars.count {
                let c = scalars[i]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    return i
                }
                i += 1
            }
            return nil
        }

        func starts(with text: String) -> Bool {
            let wanted = Array(text)
            return at + wanted.count <= scalars.count && Array(scalars[at..<at + wanted.count]) == wanted
        }

        func index(of text: String, from: Int) -> Int? {
            let wanted = Array(text)
            var i = from
            while i + wanted.count <= scalars.count {
                if Array(scalars[i..<i + wanted.count]) == wanted { return i }
                i += 1
            }
            return nil
        }

        func index(ofCaseless text: String, from: Int) -> Int? {
            let wanted = Array(text.lowercased())
            var i = from
            while i + wanted.count <= scalars.count {
                if String(scalars[i..<i + wanted.count]).lowercased() == String(wanted) { return i }
                i += 1
            }
            return nil
        }

        /// name="value", name='value', name=value and a bare name, names lowercased, values decoded.
        static func attributes(_ text: String) -> [String: String] {
            var found: [String: String] = [:]
            let chars = Array(text)
            var i = 0
            func skipSpace() { while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 } }
            while true {
                skipSpace()
                guard i < chars.count else { break }
                var name = ""
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" {
                    name.append(chars[i])
                    i += 1
                }
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                var value = ""
                if i < chars.count, chars[i] == "=" {
                    i += 1
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                        let quote = chars[i]
                        i += 1
                        while i < chars.count, chars[i] != quote {
                            value.append(chars[i])
                            i += 1
                        }
                        i += 1
                    } else {
                        while i < chars.count, !chars[i].isWhitespace {
                            value.append(chars[i])
                            i += 1
                        }
                    }
                }
                if !name.isEmpty, found[name.lowercased()] == nil { found[name.lowercased()] = Entities.decode(value) }
            }
            return found
        }
    }
}

/// Character references, decoded as Python's html.unescape does for the Mac's readers (the shared cases hold the two
/// together): `&` then a numeric reference (decimal or hex, its ";" optional) or up to 32 name characters (";"
/// optional); a numeric one Python remaps or drops is remapped or dropped, a surrogate or one past U+10FFFF is U+FFFD;
/// a name is the whole of it when HTML5 names it, else its longest leading legacy name (one with no ";"), the rest kept;
/// anything else is left as written.
public enum Entities {
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "&", let (replacement, length) = reference(scalars, at: i + 1) else {
                out.append(scalars[i])
                i += 1
                continue
            }
            out.append(contentsOf: replacement.unicodeScalars)
            i += 1 + length
        }
        return String(out)
    }

    /// The reference starting at `at` (just after "&"): its replacement and how many scalars it took; nil when the
    /// pattern doesn't match there.
    static func reference(_ s: [Unicode.Scalar], at: Int) -> (String, Int)? {
        guard at < s.count else { return nil }
        if s[at] == "#" {
            let hex = at + 1 < s.count && (s[at + 1] == "x" || s[at + 1] == "X")
            var j = at + (hex ? 2 : 1)
            var digits = ""
            while j < s.count, hex ? s[j].properties.isASCIIHexDigit : ("0"..."9").contains(s[j]) {
                digits.unicodeScalars.append(s[j])
                j += 1
            }
            guard !digits.isEmpty else { return nil }
            if j < s.count, s[j] == ";" { j += 1 }
            let number = UInt32(digits, radix: hex ? 16 : 10) ?? UInt32.max
            let replacement: String
            if let remapped = HTMLEntityTable.remapped[number] {
                replacement = remapped
            } else if (0xD800...0xDFFF).contains(number) || number > 0x10FFFF {
                replacement = "\u{FFFD}"
            } else if HTMLEntityTable.dropped.contains(number) {
                replacement = ""
            } else {
                replacement = Unicode.Scalar(number).map { String(Character($0)) } ?? "\u{FFFD}"
            }
            return (replacement, j - at)
        }
        let stops: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", " ", "<", "&", "#", ";"]
        var j = at
        while j < s.count, j - at < 32, !stops.contains(s[j]) { j += 1 }
        guard j > at else { return nil }
        if j < s.count, s[j] == ";" { j += 1 }
        let name = String(String.UnicodeScalarView(s[at..<j]))
        if let whole = HTMLEntityTable.named[name] { return (whole, j - at) }
        let scalars = Array(name.unicodeScalars)
        for x in stride(from: scalars.count - 1, to: 1, by: -1) {
            let lead = String(String.UnicodeScalarView(scalars[0..<x]))
            if let found = HTMLEntityTable.named[lead] {
                return (found + String(String.UnicodeScalarView(scalars[x...])), j - at)
            }
        }
        return nil
    }
}
