import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import PrepareMeShared
import XCTest

/// A household page's photos and videos (phase C): made small with no details, a video converted with its index first
/// and no sound, frames read once a second, and the texts refused for the owner's words or the ID check. Made-up
/// pictures and clips made here; no real photo or video.
final class HouseholdMediaTests: XCTestCase {
    var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("prepareme-household-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// A picture of `text` in large black type on white.
    static func picture(_ text: String, width: Int = 1920, height: Int = 1080) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 120, nil)
        let line = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 100, y: height / 2)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        return context.makeImage()!
    }

    /// The clip maker stopped: what it was doing and the writer's own state.
    struct ClipStuck: Error, CustomStringConvertible {
        let description: String
        init(_ what: String, _ writer: AVAssetWriter) {
            description = "making the test clip: \(what); writer status \(writer.status.rawValue), "
                + "error \(writer.error.map { String(describing: $0) } ?? "none")"
        }
    }

    /// A made-up clip of `seconds` at 10 frames a second showing `text`, its index at the end (AVAssetWriter's default).
    /// `withSound`: a silent sound track and a made-up place and date in its metadata, as a phone's clip carries.
    static func clip(_ text: String, seconds: Int, at url: URL, withSound: Bool = false, fps: Int = 10) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        var sound: AVAssetWriterInput?
        if withSound {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            writer.add(audio)
            sound = audio
            let place = AVMutableMetadataItem()
            place.identifier = .quickTimeMetadataLocationISO6709
            place.value = "+38.8895-077.0353/" as NSString  // made up: Washington, DC
            let made = AVMutableMetadataItem()
            made.identifier = .quickTimeMetadataCreationDate
            made.value = "2026-10-19T09:00:00-0400" as NSString
            writer.metadata = [place, made]
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frame = picture(text)
        var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        // Whichever track will take more gets more, and each is closed the moment it runs out. The writer keeps the two
        // side by side: waiting on the frames alone, with sound still to give, never ended on a busy Mac (2026-11-19).
        let total = seconds * fps, chunk = 44_100 / fps
        var framesIn = 0, soundIn = sound == nil ? total : 0, waiting = Date()
        while framesIn < total || soundIn < total {
            var fed = false
            if let sound, soundIn < total, sound.isReadyForMoreMediaData {
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 2,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: chunk * 2, flags: 0, blockBufferOut: &block)
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
                                           dataLength: chunk * 2)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: chunk,
                    presentationTimeStamp: CMTime(value: CMTimeValue(soundIn * chunk), timescale: 44_100),
                    packetDescriptions: nil, sampleBufferOut: &sample)
                guard sound.append(sample!) else { throw ClipStuck("sound \(soundIn) refused", writer) }
                soundIn += 1
                if soundIn == total { sound.markAsFinished() }
                fed = true
            }
            if framesIn < total, input.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32ARGB, nil, &buffer)
                CVPixelBufferLockBaseAddress(buffer!, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: 1920, height: 1080,
                                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!),
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
                context.draw(frame, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                CVPixelBufferUnlockBaseAddress(buffer!, [])
                let time = CMTime(value: CMTimeValue(framesIn), timescale: CMTimeScale(fps))
                guard adaptor.append(buffer!, withPresentationTime: time)
                else { throw ClipStuck("frame \(framesIn) refused", writer) }
                framesIn += 1
                if framesIn == total { input.markAsFinished() }
                fed = true
            }
            if fed { waiting = Date(); continue }
            // Nothing taken: fail with the writer's own words in place of waiting (a full run once stalled 80 minutes
            // here).
            guard writer.status == .writing, Date().timeIntervalSince(waiting) < 30
            else { throw ClipStuck("stopped at frame \(framesIn) and sound \(soundIn) of \(total)", writer) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await writer.finishWriting()
    }

    func testAPhotoIsMadeSmallWithNoDetails() throws {
        let source = base.appendingPathComponent("big.jpg")
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, Self.picture("SAMPLE", width: 4000, height: 3000), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.8895,
                                            kCGImagePropertyGPSLongitude: 77.0353]] as CFDictionary)
        CGImageDestinationFinalize(destination)
        try (data as Data).write(to: source)
        let small = try XCTUnwrap(HouseholdMedia.smallPhoto(source))
        let read = try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(read, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no location")
        XCTAssertNil(HouseholdMedia.smallPhoto(data: Data("not a photo".utf8)))
    }

    func testAVideoIsConvertedWithItsIndexFirstAndNoSound() async throws {
        let source = base.appendingPathComponent("made-up.mov"), out = base.appendingPathComponent("step.mp4")
        try await Self.clip("SAMPLE", seconds: 3, at: source, withSound: true)
        XCTAssertFalse(HouseholdMedia.indexFirst(source), "AVAssetWriter's default: the index at the end")
        let original = AVURLAsset(url: source)
        let originalSound = try await original.loadTracks(withMediaType: .audio)
        let originalMetadata = try await original.load(.metadata)
        XCTAssertEqual(originalSound.count, 1, "the source has a sound track, so its removal is proved")
        XCTAssertFalse(originalMetadata.isEmpty, "and a place and a date")
        try await HouseholdMedia.convertVideo(source, to: out)
        XCTAssertTrue(HouseholdMedia.indexFirst(out), "it plays inside a page")
        let asset = AVURLAsset(url: out)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(max(size.width, size.height), 1280)
        let audio = try await asset.loadTracks(withMediaType: .audio), duration = try await asset.load(.duration)
        let metadata = try await asset.load(.metadata)
        XCTAssertEqual(audio.count, 0)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3, accuracy: 0.2)
        XCTAssertTrue(metadata.isEmpty)
    }

    /// A slow-motion clip keeps 30 frames a second, not its 60 or 240 (2026-10-19).
    func testASlowMotionClipKeepsThirtyFramesASecond() async throws {
        let source = base.appendingPathComponent("fast.mov"), out = base.appendingPathComponent("fast.mp4")
        try await Self.clip("SAMPLE", seconds: 2, at: source, fps: 60)
        try await HouseholdMedia.convertVideo(source, to: out)
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(Double(rate), 30, accuracy: 1)
    }

    func testALongVideoIsRefused() async throws {
        let source = base.appendingPathComponent("long.mov")
        try await Self.clip("SAMPLE", seconds: 62, at: source)
        do {
            try await HouseholdMedia.convertVideo(source, to: base.appendingPathComponent("out.mp4"))
            XCTFail("a 62-second video was kept")
        } catch HouseholdMedia.Problem.tooLong(let seconds) {
            XCTAssertEqual(seconds, 62)
            XCTAssertEqual(HouseholdWords.tooLong(62),
                           "A step's video can run a minute at most; this one runs 62 seconds, so it wasn't kept.")
        }
    }

    func testFramesAreReadOnceASecond() async throws {
        let source = base.appendingPathComponent("frames.mov")
        try await Self.clip("SAMPLE 4417 MAPLE", seconds: 3, at: source)
        let frames = try await HouseholdMedia.frames(of: source)
        XCTAssertEqual(frames.count, 3)
        let text = try await XCTUnwrapAsync(await PhotoText.read(image: frames[1]))
        XCTAssertTrue(HouseholdMedia.holdsOwnWord(text, words: ["4417 maple"]), text)
    }

    func testTheOwnersWords() {
        XCTAssertTrue(HouseholdMedia.holdsOwnWord("SAMPLE 4417 Maple Lane", words: ["maple lane"]))
        XCTAssertTrue(HouseholdMedia.holdsOwnWord("No. 4417", words: ["4417"]))
        XCTAssertFalse(HouseholdMedia.holdsOwnWord("No. 44170", words: ["4417"]), "a number matches whole")
        XCTAssertFalse(HouseholdMedia.holdsOwnWord("Maplewood", words: ["maple"]))
        XCTAssertFalse(HouseholdMedia.holdsOwnWord("anything", words: []))
        XCTAssertTrue(HouseholdMedia.holdsOwnWord("Turn right onto Maple Terrace.", words: ["Maple Ter"]),
                      "the map spells out what the owner shortened")
        XCTAssertTrue(HouseholdMedia.holdsOwnWord("SAMPLE 4417 N Maple Rd", words: ["North Maple Road"]))
        XCTAssertFalse(HouseholdMedia.holdsOwnWord("Turn onto Maple Road.", words: ["Maple Ter"]))
        XCTAssertEqual(HouseholdWords.ownWordFound("a photo"),
                       "A photo shows one of your words for where you live, so it wasn't kept.")
    }

    func testTheChecksRefuseInFixedWords() async throws {
        let check = FakeCheck()
        let mine = try await HouseholdMedia.refusal(texts: ["SAMPLE 4417 Maple"], label: "a photo", ownWords: ["4417"],
                                                    checker: check)
        XCTAssertEqual(mine, HouseholdWords.ownWordFound("a photo"))
        XCTAssertEqual(check.calls, 0, "the owner's words are checked in the app; no text leaves it for them")
        let id = try await HouseholdMedia.refusal(texts: ["REFUSE"], label: "a video", ownWords: ["4417"],
                                                  checker: check)
        XCTAssertEqual(id, "Our Home page, a video, Text 1: refused")
        var page = HouseholdMediaTests.page
        let fine = try await HouseholdMedia.refusal(page: page, ownWords: ["4417"], checker: check)
        XCTAssertNil(fine)
        page.steps[0].caution = "SAMPLE REFUSE"
        let refused = try await HouseholdMedia.refusal(page: page, ownWords: ["4417"], checker: check)
        XCTAssertEqual(refused, "Our Home page, step 1, Caution: refused")
        page.steps[0].caution = "By 4417."
        let own = try await HouseholdMedia.refusal(page: page, ownWords: ["4417"], checker: check)
        XCTAssertEqual(own, HouseholdWords.ownWordFound("the page's words"))
        check.broken = true
        do {
            _ = try await HouseholdMedia.refusal(texts: ["x"], label: "a photo", ownWords: ["4417"], checker: check)
            XCTFail("kept with no check")
        } catch is CheckUnavailable {}
    }

    /// The owner's choice (2026-10-20, phase K finding 2): until "Your words for where you live" holds a word, no
    /// photo or video is kept and no page saved, with one line saying where to enter them; a list of only blanks or
    /// marks holds no word. Pages already saved still open and list.
    func testNothingIsKeptOrSavedUntilTheOwnersWordsAreEntered() async throws {
        let words = "Enter your words for where you live first (Settings › Household › Your words for where you "
            + "live), so photos, videos and pages can be checked for them."  // Our Home Task 1.3
        XCTAssertEqual(HouseholdWords.ownWordsFirst, words)
        let check = FakeCheck()
        for none in [[], [""], ["  "], ["-", "\u{2026}"]] as [[String]] {
            XCTAssertEqual(HouseholdMedia.wordsFirst(none), words, "\(none)")
            let photo = try await HouseholdMedia.refusal(texts: ["SAMPLE a valve"], label: "a photo", ownWords: none,
                                                         checker: check)
            XCTAssertEqual(photo, words)
            let page = try await HouseholdMedia.refusal(page: Self.page, ownWords: none, checker: check)
            XCTAssertEqual(page, words)
        }
        XCTAssertEqual(check.calls, 0, "refused before any check")
        XCTAssertNil(HouseholdMedia.wordsFirst(["4417"]))
        let fine = try await HouseholdMedia.refusal(page: Self.page, ownWords: ["4417"], checker: check)
        XCTAssertNil(fine)

        // pages saved before still list and open
        let folder = HouseholdPagesFolder(home: base)
        try folder.save(Self.page, as: "house-sample")
        XCTAssertTrue(folder.list().contains { $0.name == "house-sample" && $0.kind == .page })
        XCTAssertEqual(try folder.read("house-sample"), Self.page)
    }

    static let page = HouseholdPage(title: "SAMPLE", steps: [.init(words: "SAMPLE turn it.")])
}

/// XCTUnwrap for an async expression.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
    let found = try await value()
    return try XCTUnwrap(found, file: file, line: line)
}
