import Foundation

/// Meaning search (docs/plans/2026-10-28-meaning-search.md): BERT's uncased WordPiece splitter, as Hugging Face's
/// tokenizers runs it for bge-small-en-v1.5 (BertNormalizer with clean_text, Chinese characters spaced, accents
/// stripped, lowercased; BertPreTokenizer; WordPiece with "##" and a 100-character word limit; [CLS] … [SEP], cut to
/// 512). The Core ML trial's own copy (docs/research/2026-10-28-search-trial/coreml/), pinned by MeaningTests against
/// tokenizers' output. Its vocabulary is the model folder's vocab.txt (MeaningModel), never committed.
public struct WordPiece: Sendable {
    let vocab: [String: Int32]
    let cls: Int32, sep: Int32, unk: Int32

    public init(vocabFile: URL) throws {
        let lines = try String(contentsOf: vocabFile, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        var v = [String: Int32]()
        for (i, line) in lines.enumerated() where !line.isEmpty || i < lines.count - 1 { v[String(line)] = Int32(i) }
        guard let cls = v["[CLS]"], let sep = v["[SEP]"], let unk = v["[UNK]"] else { throw MeaningModel.Problem.badVocab }
        vocab = v; self.cls = cls; self.sep = sep; self.unk = unk
    }

    public func ids(_ text: String, maxLength: Int = 512) -> [Int32] {
        var out = [cls]
        for word in words(normalized(text)) {
            out += pieces(word)
            if out.count >= maxLength - 1 { break }
        }
        return Array(out.prefix(maxLength - 1)) + [sep]
    }

    private func normalized(_ text: String) -> String {
        var s = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if c.value == 0 || c.value == 0xFFFD || isControl(c) { continue }
            if isWhitespace(c) { s.append(" ") }
            else if isChinese(c) { s.append(" "); s.append(c); s.append(" ") }
            else { s.append(c) }
        }
        let stripped = String(s).decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }
        return String(String.UnicodeScalarView(stripped)).lowercased()
    }

    private func words(_ text: String) -> [String] {
        var out = [String](), cur = String.UnicodeScalarView()
        func flush() { if !cur.isEmpty { out.append(String(cur)); cur = .init() } }
        for c in text.unicodeScalars {
            if isWhitespace(c) { flush() }
            else if isPunctuation(c) { flush(); out.append(String(c)) }
            else { cur.append(c) }
        }
        flush()
        return out
    }

    private func pieces(_ word: String) -> [Int32] {
        let chars = Array(word.unicodeScalars)
        if chars.count > 100 { return [unk] }
        var out = [Int32](), start = 0
        while start < chars.count {
            var end = chars.count, found: Int32?
            while start < end {
                let sub = (start > 0 ? "##" : "") + String(String.UnicodeScalarView(chars[start..<end]))
                if let id = vocab[sub] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            out.append(id); start = end
        }
        return out
    }

    private func isWhitespace(_ c: Unicode.Scalar) -> Bool { c == "\t" || c == "\n" || c == "\r" || c.properties.isWhitespace }
    private func isControl(_ c: Unicode.Scalar) -> Bool {
        if c == "\t" || c == "\n" || c == "\r" { return false }
        switch c.properties.generalCategory { case .control, .format, .unassigned, .privateUse: return true; default: return false }
    }
    private func isPunctuation(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
    private func isChinese(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
