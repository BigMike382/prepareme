// The Mac's way to meaning search's numbers, from the same Swift code as the phones (packer/meaning.py runs it).
//
//   prepareme-meaning pages IN OUT [--model DIR]      a page's numbers for each text in IN, a JSON list of strings
//   prepareme-meaning searches IN OUT [--model DIR]   a search's numbers for each (bge's instruction in front, padded as
//                                                     on the phones)
//   prepareme-meaning nearest QUERIES CANDIDATES OUT [--k 5] [--floor 0.70]
//                                                     News's grouping (news/group.py): QUERIES and CANDIDATES are raw
//                                                     little-endian float32 rows of 384, unit length; OUT is
//                                                     {"model": MeaningModel.revision, "nearest": [[[index, likeness],
//                                                     …], …]}, each query's best k at or above floor, best first
//
// OUT for pages and searches is {"model": MeaningModel.revision, "vectors": [[384 numbers], …]}, in IN's order. The model
// folder defaults to the Mac's (app/Meaning/make_model.sh), at full precision, the phones' choice (phase 1). Exit 2: a
// usage error, or a nearest file that isn't whole rows of 384; 1: the model or a file couldn't be read.
import Foundation
import MeaningNearest
import MeaningSearch

struct Output: Encodable {
    let model: String
    let vectors: [[Float]]
}

struct NearestOutput: Encodable {
    let model: String
    let nearest: [[[Double]]]
}

func usage() -> Never {
    FileHandle.standardError.write(Data(("usage: prepareme-meaning pages|searches IN OUT [--model DIR]\n"
        + "       prepareme-meaning nearest QUERIES CANDIDATES OUT [--k N] [--floor F]\n").utf8))
    exit(2)
}

func option(_ name: String, in words: inout [String]) -> String? {
    guard let at = words.firstIndex(of: name) else { return nil }
    guard at + 1 < words.count else { usage() }
    let value = words[at + 1]
    words.removeSubrange(at...at + 1)
    return value
}

var words = Array(CommandLine.arguments.dropFirst())
if words.first == "nearest" {
    guard let k = Int(option("--k", in: &words) ?? "5"), k > 0,
          let floor = Float(option("--floor", in: &words) ?? "0.70"), words.count == 4 else { usage() }
    do {
        let queries = try Nearest.rows(Data(contentsOf: URL(fileURLWithPath: words[1])))
        let candidates = try Nearest.rows(Data(contentsOf: URL(fileURLWithPath: words[2])))
        let found = Nearest.search(queries: queries, candidates: candidates, k: k, floor: floor)
        try JSONEncoder().encode(NearestOutput(model: MeaningModel.revision,
                                               nearest: found.map { $0.map { [Double($0.0), Double($0.1)] } }))
            .write(to: URL(fileURLWithPath: words[3]), options: .atomic)
    } catch Nearest.Problem.notWholeRows {
        FileHandle.standardError.write(Data("prepareme-meaning: a file isn't whole rows of 384 numbers\n".utf8))
        exit(2)
    } catch {
        FileHandle.standardError.write(Data("prepareme-meaning: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
var folder = MeaningModel.macFolder
if let given = option("--model", in: &words) {
    folder = URL(fileURLWithPath: given)
}
guard words.count == 3, ["pages", "searches"].contains(words[0]) else { usage() }
do {
    let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: words[1])))
    let model = try MeaningModel(folder: folder, precision: .full)
    let vectors = try texts.map { words[0] == "pages" ? try model.vector($0) : try model.searchVector($0) }
    try JSONEncoder().encode(Output(model: MeaningModel.revision, vectors: vectors))
        .write(to: URL(fileURLWithPath: words[2]), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("prepareme-meaning: \(error)\n".utf8))
    exit(1)
}
