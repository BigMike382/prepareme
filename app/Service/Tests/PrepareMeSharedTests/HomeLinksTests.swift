import Foundation
import Testing
@testable import PrepareMeShared

/// Task 2.6 (docs/plans/2026-11-16-our-home.md): the screen kept awake on a step, and prepareme://home/<name>.
struct HomeLinksTests {
    let daily = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    func url(_ text: String) -> URL { URL(string: text)! }

    @Test func awakeOnlyOnAnOurHomeStep() {
        let page = "zim://\(daily.uuidString)/shutoffs.html"
        #expect(HomeLinks.keepsAwake(url(page + "#step-1"), dailyID: daily))
        #expect(HomeLinks.keepsAwake(url(page + "#step-12"), dailyID: daily))
        for asleep in [page, page + "#start", page + "#done", page + "#step-0", page + "#step-x", page + "#s-2"] {
            #expect(!HomeLinks.keepsAwake(url(asleep), dailyID: daily), "\(asleep)")
        }
        let other = "zim://\(UUID().uuidString)/shutoffs.html#step-2"  // another library's page
        #expect(!HomeLinks.keepsAwake(url(other), dailyID: daily))
        #expect(!HomeLinks.keepsAwake(url(page + "#step-2"), dailyID: nil))
        #expect(!HomeLinks.keepsAwake(nil, dailyID: daily))
    }

    @Test func aLinkOpensItsPageOrTheSection() {
        for name in HouseholdPage.starterNames + ["house-1a2b3c4d", "house-check"] {
            #expect(HomeLinks.page(url("prepareme://home/\(name)")) == "\(name).html", "\(name)")
        }
        for bad in ["prepareme://home/", "prepareme://home", "prepareme://home/utility-shutoff", "prepareme://home/a/b",
                    "prepareme://home/..", "prepareme://home/../shutoffs", "prepareme://home/house-", "prepareme://home/SHUTOFFS",
                    "prepareme://home/shutoffs.html", "prepareme://home/house-a%2Fb"] {
            #expect(HomeLinks.page(url(bad)) == HomeLinks.section, "\(bad)")
        }
        #expect(HomeLinks.section == "topic-our-household.html")
        #expect(HomeLinks.page(url("prepareme://streetmap/shutoffs")) == nil)  // not this link at all
        #expect(HomeLinks.page(url("https://home/shutoffs")) == nil)
    }

    @Test func anOurHomePageOnAnyScreen() {
        let base = "zim://\(daily.uuidString)/"
        #expect(HomeLinks.isHomePage(url(base + "shutoffs.html"), dailyID: daily))
        #expect(HomeLinks.isHomePage(url(base + "house-check.html#done"), dailyID: daily))
        #expect(!HomeLinks.isHomePage(url(base + "utility-shutoff.html"), dailyID: daily))
        #expect(!HomeLinks.isHomePage(url(base + "topic-our-household.html"), dailyID: daily))
        #expect(!HomeLinks.isHomePage(url("zim://\(UUID().uuidString)/shutoffs.html"), dailyID: daily))
    }
}
