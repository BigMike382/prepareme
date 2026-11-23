import Foundation
@testable import PrepareMeShared
import XCTest

/// The Mac's readers' shared cases (dashboard/tests/phone_cases.py writes them). They are recorded on the home state's
/// feeds, so they live with the dashboard, outside app/, whose source is published (Unlisted plan, phase 4): a copy of
/// app/ without the rest of the repository has none, and the tests that read them skip.
enum SharedCases {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../dashboard/tests/fixtures/phone-cases.json").standardized
    static var present: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The state's file as the Mac packs it (packer/phone_settings.py `area_content`), from the shared cases.
    static func area() throws -> ConditionsArea {
        let top = try JSONSerialization.jsonObject(with: Data(contentsOf: url.skippingWhenAbsent())) as? [String: Any]
        return try ConditionsArea(JSONSerialization.data(withJSONObject: top?["area"] ?? [:]))
    }
}

extension URL {
    /// The shared cases' address, or an XCTest skip when they aren't here.
    func skippingWhenAbsent() throws -> URL {
        guard SharedCases.present else { throw XCTSkip("no shared cases (dashboard/tests/fixtures/phone-cases.json)") }
        return self
    }
}
