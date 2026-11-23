import Testing
@testable import PrepareMeShared

// The first test file here written with Swift Testing (docs/app.md, "Tests"): pure functions, no shared state.
struct HTMLTextTests {
    @Test func everyEntityAPageCarriesReadsPlain() {
        #expect(HTMLText.unescaped("&lt;b&gt; &quot;Tom&#x27;s&quot; &#39;x&apos; a&nbsp;b Q&amp;A")
                == "<b> \"Tom's\" 'x' a b Q&A")
    }

    @Test func ampersandGoesLastSoAnEscapedEntityStaysOne() {
        #expect(HTMLText.unescaped("&amp;lt;") == "&lt;")
        #expect(HTMLText.unescaped("plain") == "plain")
    }

    @Test func theMissingPagesLineReadsWithIt() {
        let page = "<p class=\"missing\">Not in the library yet: Water &amp; food, Tom&apos;s list.</p>"
        #expect(MissingPages.names(inPage: page) == ["Water & food", "Tom's list"])
    }
}
