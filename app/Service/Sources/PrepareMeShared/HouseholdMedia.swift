import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A household page's photos and videos, made ready and checked on the Mac before they're kept (concept-doc plan,
/// phase C). A photo is made small (1600 pixels on its long side, upright) and saved again as a JPEG with none of the
/// original's details, such as where it was taken. A video becomes 1280 pixels on its long side, H.264 at 1.2 Mbit/s
/// (about 4 MB for 30 seconds, measured 2026-10-19), with no sound and none of the original's details, its index at
/// the front so it plays inside a page (Kiwix's page loader ignores the player's byte-range asks). Every photo, and a
/// video's frame each second, is read (PhotoText) and its text checked: the ID check (refused on an ID number's shape)
/// and the owner's own words for where the household lives (kept only on this Mac); until those hold a word, nothing is
/// kept (`wordsFirst`). Refusals are fixed words, never the text read.
public enum HouseholdMedia {
    public static let photoLongSide = 1600
    public static let videoLongSide = 1280
    public static let videoBitRate = 1_200_000
    public static let longestVideo = 60.0  // seconds a step's video may run
    /// Frames a second kept: a phone's slow-motion clip runs at 120 or 240, which only spends the size on frames no
    /// one needs (seen 2026-10-19 on 240-frame test footage).
    public static let framesPerSecond = 30.0
    public static let frameEvery = 1.0  // seconds between the frames read

    // MARK: Photos

    /// The image at `url` at most `photoLongSide` pixels on its long side, upright, as a JPEG with no metadata; nil
    /// when it isn't an image.
    public static func smallPhoto(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return small(source)
    }

    public static func smallPhoto(data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return small(source)
    }

    static func small(_ source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: photoLongSide,
              ] as CFDictionary) else { return nil }
        return jpeg(image)
    }

    /// `image` as a JPEG with no metadata.
    public static func jpeg(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Videos

    public enum Problem: Error, Equatable, Sendable {
        case notAVideo, tooLong(seconds: Int), couldNotConvert
    }

    /// The video at `source` made ready for a step at `out` (an .mp4): see the type's comment. Throws `tooLong` past
    /// `longestVideo`.
    public static func convertVideo(_ source: URL, to out: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw Problem.notAVideo }
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        guard seconds.isFinite, seconds > 0 else { throw Problem.notAVideo }
        guard seconds <= longestVideo + 0.5 else { throw Problem.tooLong(seconds: Int(seconds.rounded())) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let scale = min(1, Double(videoLongSide) / Double(max(natural.width, natural.height)))
        let width = Int((natural.width * scale / 2).rounded()) * 2, height = Int((natural.height * scale / 2).rounded()) * 2
        try? FileManager.default.removeItem(at: out)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // the index first: it plays inside a page
        writer.metadata = []
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitRate]])
        input.transform = transform  // a phone held upright plays upright
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw Problem.couldNotConvert }
        writer.startSession(atSourceTime: .zero)
        let pump = Pump(reader: reader, output: output, input: input)
        await pump.run()
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw Problem.couldNotConvert
        }
    }

    /// Feeds the reader's frames to the writer's input until the reader runs out.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput
        var next = CMTime.negativeInfinity  // the earliest time the next kept frame may have (only the queue's block)
        let gap = CMTime(seconds: 1 / HouseholdMedia.framesPerSecond - 0.001, preferredTimescale: 60_000)
        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.reader = reader
            self.output = output
            self.input = input
        }

        func run() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "prepareme.household-video")
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    _ = reader.status  // keeps the reader alive while the input asks
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if time.isValid, time < next { continue }  // a frame too soon after the last kept one
                        if time.isValid { next = time + gap }
                        guard input.append(sample) else {  // the writer failed: stop, never wait forever (the review)
                            reader.cancelReading()
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    /// One frame each `every` seconds from the start, upright.
    public static func frames(of url: URL, every: Double = frameEvery) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        guard seconds.isFinite, seconds > 0 else { throw Problem.notAVideo }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: every / 2, preferredTimescale: 600)
        var found: [CGImage] = []
        var at = 0.0
        while at < seconds {
            let (image, _) = try await generator.image(at: CMTime(seconds: at, preferredTimescale: 600))
            found.append(image)
            at += every
        }
        return found
    }

    /// Whether `size` (bytes) in an MP4 at `url` has its index (moov) before its data (mdat), as packer.build checks.
    public static func indexFirst(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while let header = try? handle.read(upToCount: 8), header.count == 8 {
            let size = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            switch String(decoding: header.suffix(4), as: UTF8.self) {
            case "moov": return true
            case "mdat": return false
            default: break
            }
            guard size >= 8 else { return false }
            offset += size
            try? handle.seek(toOffset: offset)
        }
        return false
    }

    // MARK: The checks

    /// Whether `text` holds one of `words` (the owner's words for where the household lives): each a run of whole
    /// words, any case or accent; a number must match whole ("12" never matches "120"). A street word's short form
    /// matches its long one either way ("Ter" and "Terrace"): the street map spells names out, the owner may not
    /// (section 38's check, 2026-10-31).
    public static func holdsOwnWord(_ text: String, words: [String]) -> Bool {
        let held = GuideLinks.tokens(text).map { streetLong[$0] ?? $0 }
        return words.contains { word in
            let want = GuideLinks.tokens(word).map { streetLong[$0] ?? $0 }
            guard !want.isEmpty, want.count <= held.count else { return false }
            return (0...(held.count - want.count)).contains { start in
                want.indices.allSatisfy { held[start + $0] == want[$0] }
            }
        }
    }

    /// Street suffixes' and directions' short forms, from USPS Publication 28 (appendix C1, pe.usps.com/text/pub28/
    /// 28apc_002.htm, read 2026-10-31: each standard form and its common ones; directions from appendix B). A wrong
    /// match only warns more, never less.
    static let streetLong: [String: String] = {
        let forms: [String: [String]] = [
            "alley": ["aly", "ally", "allee"], "avenue": ["ave", "av", "aven", "avn"], "bend": ["bnd"],
            "boulevard": ["blvd", "boul", "boulv"], "circle": ["cir", "circ", "crcl"], "court": ["ct"], "cove": ["cv"],
            "creek": ["crk"], "crossing": ["xing", "crssng"], "drive": ["dr", "drv", "driv"], "extension": ["ext", "extn"],
            "glen": ["gln"], "grove": ["grv", "grov"], "heights": ["hts", "ht"], "highway": ["hwy", "hiway", "hiwy"],
            "hill": ["hl"], "hollow": ["holw", "hllw"], "junction": ["jct", "jctn"], "landing": ["lndg", "lndng"],
            "lane": ["ln"], "meadows": ["mdws", "mdw"], "mountain": ["mtn", "mntn"], "parkway": ["pkwy", "pky", "parkwy"],
            "place": ["pl"], "plaza": ["plz", "plza"], "point": ["pt"], "ridge": ["rdg", "rdge"], "road": ["rd"],
            "route": ["rte"], "spring": ["spg", "spng"], "square": ["sq", "sqr"], "street": ["st", "str", "strt"],
            "terrace": ["ter", "terr"], "trail": ["trl"], "turnpike": ["tpke", "turnpk"], "view": ["vw"],
            "valley": ["vly", "vlly"], "way": ["wy"],
            "north": ["n"], "south": ["s"], "east": ["e"], "west": ["w"],
            "northeast": ["ne"], "northwest": ["nw"], "southeast": ["se"], "southwest": ["sw"],
        ]
        return Dictionary(forms.flatMap { long, shorts in shorts.map { ($0, long) } }, uniquingKeysWith: { a, _ in a })
    }()

    /// The owner's choice (2026-10-20): until the owner's words for where the household lives hold a word, no photo or
    /// video is kept and no page saved, since none could be checked for them; this refusal then, else nil.
    public static func wordsFirst(_ ownWords: [String]) -> String? {
        ownWords.contains { !GuideLinks.tokens($0).isEmpty } ? nil : HouseholdWords.ownWordsFirst
    }

    /// The first refusal for texts read from a photo or a video's frames (`label`: "a photo" or "a video"), or nil when
    /// they may be kept: none until the owner's words are entered (`wordsFirst`), then the owner's words (no text
    /// leaves the app for them), then the ID check. Throws CheckUnavailable when the ID check can't answer (nothing is
    /// kept).
    public static func refusal(texts: [String], label: String, ownWords: [String],
                               checker: TextChecking) async throws -> String? {
        if let first = wordsFirst(ownWords) { return first }
        if texts.contains(where: { holdsOwnWord($0, words: ownWords) }) {
            return HouseholdWords.ownWordFound(label)
        }
        let rows = [CheckRow(place: "Our Home page, \(label)",
                             cells: texts.enumerated().map { CheckCell(label: "Text \($0.offset + 1)", text: $0.element) })]
        return try await checker.check(rows, file: nil).refusal
    }

    /// The first refusal for a page's words (its title, When to use this, every step's words, name and caution, its
    /// search words), or nil: none saved until the owner's words are entered (`wordsFirst`), then the ID check, read
    /// as a row per step, and the owner's words.
    public static func refusal(page: HouseholdPage, ownWords: [String], checker: TextChecking) async throws -> String? {
        if let first = wordsFirst(ownWords) { return first }
        var rows = [CheckRow(place: "Our Home page", cells: [
            CheckCell(label: "Title", text: page.title), CheckCell(label: "When to use this", text: page.when),
            CheckCell(label: "Search words", text: page.keywords.joined(separator: "; "))])]
        for (n, step) in page.steps.enumerated() {
            rows.append(CheckRow(place: "Our Home page, step \(n + 1)", cells: [
                CheckCell(label: "Words", text: step.words), CheckCell(label: "Name", text: step.name),
                CheckCell(label: "Caution", text: step.caution)]))
        }
        let texts = rows.flatMap { $0.cells.map(\.text) }
        if texts.contains(where: { holdsOwnWord($0, words: ownWords) }) {
            return HouseholdWords.ownWordFound("the page's words")
        }
        return try await checker.check(rows, file: nil).refusal
    }
}

/// Household pages' fixed words on the Mac (phase C).
public enum HouseholdWords {
    public static func ownWordFound(_ what: String) -> String {
        "\(what.prefix(1).uppercased() + what.dropFirst()) shows one of your words for where you live, so it wasn't kept."
    }
    public static let ownWordsFirst = "Enter your words for where you live first (Settings › Household › Your words "
        + "for where you live), so photos, videos and pages can be checked for them."  // Our Home Task 1.3
    public static let notAPhoto = "That isn't a photo PrepareMe can read, so it wasn't kept."
    public static let unreadablePhoto = "PrepareMe couldn't read the photo's text for the ID check, so it wasn't kept."
    public static let notAVideo = "That isn't a video PrepareMe can read, so it wasn't kept."
    public static func tooLong(_ seconds: Int) -> String {
        "A step's video can run a minute at most; this one runs \(seconds) seconds, so it wasn't kept."
    }
    public static let couldNotConvert = "PrepareMe couldn't make the video ready for the phones, so it wasn't kept."
    public static let lookFirst = "Look at it before it's kept: no house number, street sign, license plate, or a "
        + "meter's or account's label. Photograph the valve, not the label."
}
