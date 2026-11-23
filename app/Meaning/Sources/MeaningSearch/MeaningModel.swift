import CoreML
import Foundation

/// Meaning search (docs/plans/2026-10-28-meaning-search.md): bge-small-en-v1.5 on Core ML turns a text into 384 numbers,
/// close together for texts that mean the same thing. It only puts guides in order; it never writes anything.
///
/// The model folder is made once by app/Meaning/make_model.sh from the pinned revision, never committed: `vocab.txt`
/// and the compiled model at half and at full precision. On the Mac it lives in Application Support › PrepareMe ›
/// tools › meaning; an app carries it in its bundle.
public final class MeaningModel {
    public enum Precision: String, CaseIterable, Sendable {
        case half = "fp16", full = "fp32"
    }

    public enum Problem: Error {
        case badVocab, noEmbedding
    }

    /// The model's name and pinned revision; a library's numbers made by another are never compared with these
    public static let revision = "bge-small-en-v1.5@5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
    public static let folderName = "bge-small-en-v1.5-5c38ec7"
    /// bge's instruction for a search (never for a page): its model card's retrieval prefix
    public static let searchPrefix = "Represent this sentence for searching relevant passages: "

    #if os(macOS)
    /// The Mac's model folder, as make_model.sh writes it by default
    public static var macFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PrepareMe/tools/meaning/\(folderName)")
    }
    #endif

    public let precision: Precision
    private let splitter: WordPiece
    private let model: MLModel

    public init(folder: URL, precision: Precision = .half, units: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = units
        self.precision = precision
        splitter = try WordPiece(vocabFile: folder.appendingPathComponent("vocab.txt"))
        model = try MLModel(contentsOf: folder.appendingPathComponent("bge-small-\(precision.rawValue).mlmodelc"),
                            configuration: config)
    }

    /// The lengths a search is padded to (in word pieces), so a phone prepares the model for these shapes once, at
    /// `warmUp`, instead of for each new length mid-search (the owner's phone check, 2026-10-28: single searches took
    /// up to 2.2 s while the average was 0.04 to 0.09 s). A longer search is cut to the last.
    public static let searchLengths = [32, 64]

    /// A page's numbers (on the Mac, at its own length)
    public func vector(_ text: String) throws -> [Float] {
        try numbers(splitter.ids(text), length: nil)
    }

    /// A search's numbers: what was typed, after bge's search instruction, padded to one of `searchLengths`
    public func searchVector(_ typed: String) throws -> [Float] {
        let ids = splitter.ids(Self.searchPrefix + typed, maxLength: Self.searchLengths[Self.searchLengths.count - 1])
        return try numbers(ids, length: Self.searchLengths.first { $0 >= ids.count })
    }

    /// Prepares the model for every search length, so no search waits for it: once, before the first search
    public func warmUp() throws {
        for length in Self.searchLengths {
            _ = try numbers(splitter.ids(""), length: length)
        }
    }

    /// The model's numbers for `ids`, padded with [PAD] (0), which the mask hides, to `length` when given
    private func numbers(_ ids: [Int32], length: Int?) throws -> [Float] {
        let count = max(ids.count, length ?? 0)
        let shape = [1, NSNumber(value: count)]
        let input = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        for place in 0..<count {
            input[place] = NSNumber(value: place < ids.count ? ids[place] : 0)
            mask[place] = place < ids.count ? 1 : 0
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["input_ids": input, "attention_mask": mask]))
        guard let numbers = out.featureValue(for: "embedding")?.multiArrayValue else { throw Problem.noEmbedding }
        return (0..<numbers.count).map { Float(truncating: numbers[$0]) }
    }

    /// How alike two texts are, -1 to 1 (the numbers come out at length 1, so this is their cosine)
    public static func likeness(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
