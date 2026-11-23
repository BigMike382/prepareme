import Foundation
@testable import PrepareMeShared
import Testing

/// Unlisted plan, phase 4 (decision 2): the state's details from the library's file beside the settings, made up here
/// (the Mac's real one is packer/phone_settings.py `area_content`, held to the dashboard by the packer's tests). Keys
/// it doesn't know are ignored; a missing one, an address that isn't https or another format refuses the file.
@Suite struct ConditionsAreaTests {
    static let good = #"{"agency":"Example Emergency Office","agency_link":"https://emergency.example/","counties":["Example","New Example"],"evac_note":"From the example office's list.","evacuations":"https://feeds.example/evacuations","format":1,"outages":"https://feeds.example/outages"}"#

    func edited(_ change: (inout [String: Any]) -> Void) -> Data {
        var object = try! JSONSerialization.jsonObject(with: Data(Self.good.utf8)) as! [String: Any]
        change(&object)
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func theGoodFileReads() throws {
        let area = try ConditionsArea(Data(Self.good.utf8))
        #expect(area.outages.absoluteString == "https://feeds.example/outages")
        #expect(area.evacuations.host == "feeds.example")
        #expect(area.agency == "Example Emergency Office" && area.agencyLink == "https://emergency.example/")
        #expect(area.evacNote == "From the example office's list.")
        #expect(area.counties == ["Example", "New Example"])
        #expect(ConditionsArea.path == "household/conditions-area.json")
    }

    @Test func aKeyItDoesntKnowIsIgnored() throws {
        #expect(try ConditionsArea(edited { $0["later"] = ["anything"] }).agency == "Example Emergency Office")
    }

    @Test func refused() {
        let bad: [Data] = [Data(), Data("[]".utf8), edited { $0["format"] = 2 }, edited { $0["outages"] = nil },
                           edited { $0["outages"] = "http://feeds.example/outages" },
                           edited { $0["evacuations"] = "file:///etc/passwd" }, edited { $0["agency_link"] = "nope" },
                           edited { $0["agency"] = "" }, edited { $0["agency"] = "<b>x</b>" },
                           edited { $0["evac_note"] = "two\nlines" }, edited { $0["counties"] = [String]() },
                           edited { $0["counties"] = "Example" }]
        for data in bad {
            #expect(throws: (any Error).self) { try ConditionsArea(data) }
        }
    }
}
