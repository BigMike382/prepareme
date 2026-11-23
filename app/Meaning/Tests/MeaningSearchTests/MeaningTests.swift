import Foundation
import Testing
@testable import MeaningSearch

// Meaning search (docs/plans/2026-10-28-meaning-search.md): the splitter and Core ML against the original model's own
// output (Fixtures/meaning, written by app/Meaning/meaning.py fixtures). They need the model folder, which is never
// committed: $PREPAREME_MEANING_MODEL, else the Mac's (app/Meaning/make_model.sh). Without one they're skipped, and
// Swift Testing lists them as skipped.
struct MeaningTests {
    static let folder: URL? = {
        let given = ProcessInfo.processInfo.environment["PREPAREME_MEANING_MODEL"].map { URL(fileURLWithPath: $0) }
        let folder = given ?? MeaningModel.macFolder
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("vocab.txt").path) ? folder : nil
    }()

    static func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/meaning/\(name)")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    struct Case: Decodable {
        let text: String
        let ids: [Int32]
    }

    struct Reference: Decodable {
        let text: String
        let vector: [Float]
    }

    @Test(.enabled(if: folder != nil, "no model folder: run app/Meaning/make_model.sh"))
    func theSplitterMatchesTheOriginalOnEveryCase() throws {
        let splitter = try WordPiece(vocabFile: #require(Self.folder).appendingPathComponent("vocab.txt"))
        let cases = try Self.fixture("wordpiece.json", as: [Case].self)
        #expect(cases.count > 300)
        for item in cases {
            #expect(splitter.ids(item.text) == item.ids, "\(item.text.prefix(60))")
        }
    }

    @Test(.enabled(if: folder != nil, "no model folder: run app/Meaning/make_model.sh"))
    func aLongTextIsCutTo512WithItsEndMark() throws {
        let splitter = try WordPiece(vocabFile: #require(Self.folder).appendingPathComponent("vocab.txt"))
        let ids = splitter.ids(String(repeating: "water storage ", count: 400))
        #expect(ids.count == 512)
        #expect(ids.first == 101 && ids.last == 102)  // [CLS] … [SEP]
    }

    @Test(.enabled(if: folder != nil, "no model folder: run app/Meaning/make_model.sh"),
          arguments: MeaningModel.Precision.allCases)
    func coreMLGivesTheOriginalsNumbers(precision: MeaningModel.Precision) throws {
        let model = try MeaningModel(folder: #require(Self.folder), precision: precision)
        for reference in try Self.fixture("vectors.json", as: [Reference].self) {
            let got = try model.vector(reference.text)
            #expect(got.count == 384)
            // the trial's worst: 1.000000 at full precision, 0.999969 at half
            #expect(MeaningModel.likeness(got, reference.vector) > (precision == .full ? 0.9999 : 0.999),
                    "\(reference.text.prefix(60))")
        }
    }

    @Test(.enabled(if: folder != nil, "no model folder: run app/Meaning/make_model.sh"),
          arguments: MeaningModel.Precision.allCases)
    func aPaddedSearchGivesTheOriginalsNumbers(precision: MeaningModel.Precision) throws {
        let model = try MeaningModel(folder: #require(Self.folder), precision: precision)
        try model.warmUp()
        let references = try Self.fixture("vectors.json", as: [Reference].self)
            .filter { $0.text.hasPrefix(MeaningModel.searchPrefix) }
        #expect(references.count == 2)
        for reference in references {
            let typed = String(reference.text.dropFirst(MeaningModel.searchPrefix.count))
            #expect(MeaningModel.likeness(try model.searchVector(typed), reference.vector)
                    > (precision == .full ? 0.9999 : 0.999), "\(typed)")
        }
        // past the first length (32 pieces) to the second, and past the last, cut to it
        for typed in [String(repeating: "boil water ", count: 12), String(repeating: "boil water ", count: 40)] {
            let unpadded = try model.vector(MeaningModel.searchPrefix + typed)
            let padded = try model.searchVector(typed)
            #expect(padded.count == 384)
            if typed.count < 200 {
                #expect(MeaningModel.likeness(padded, unpadded) > (precision == .full ? 0.9999 : 0.999))
            }
        }
    }

    @Test(.enabled(if: folder != nil, "no model folder: run app/Meaning/make_model.sh"))
    func aSearchFindsTheGuideItMeansAboveAnUnrelatedOne() throws {
        let model = try MeaningModel(folder: #require(Self.folder))
        let search = try model.searchVector("my kid swallowed something and can't breathe")
        let choking = try model.vector("Choking: back blows and abdominal thrusts for a child or adult.")
        let garden = try model.vector("Saving seeds from the vegetable garden for next year.")
        #expect(MeaningModel.likeness(search, choking) > MeaningModel.likeness(search, garden))
    }
}
