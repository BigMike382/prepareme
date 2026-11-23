import Foundation

/// An Our Home page as a phone shows it, for the Mac editor's preview (docs/plans/2026-11-16-our-home.md, Task 2.5;
/// the owner's click, 2026-11-16: the Mac draws it itself, test-matched). `body` is packer/steps.py's body() line for
/// line; its styles, script and fixed words come from Resources/our-home-page.json, which packer/tests/test_steps.py
/// writes from steps.app_assets() and pins, and HomePageTests holds `body` to the packer's bytes on the shared cases
/// (Fixtures/our-home-previews.json). Change the layout in both, then write the fixtures again.
public enum HomePage {
    struct Assets: Decodable {
        let style, script: String
        let words, calculators, calls: [String: String]
        let call_number: String
    }

    static let assets: Assets? = Bundle.module.url(forResource: "our-home-page", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Assets.self, from: $0) }

    /// The calculators a step can name: page id (calc-…) to its name, packer/calculator_links.toml's [names].
    public static var calculators: [String: String] { assets?.calculators ?? [:] }

    /// The editor's preview never takes the keyboard from the box being typed in (the owner, 2026-11-18: each refresh,
    /// 0.3 s after a key, took it and the next keys beeped). A jump to a screen (`location.hash = …`) and the page's
    /// own `focus()` on that screen each moved WebKit's focus into the preview, so the preview shows a screen with
    /// `previewShow` (a quiet address change, then the page's own hashchange) and runs `previewNoFocus` first; a click
    /// in the preview still moves into it.
    public static func previewShow(_ hash: String) -> String {
        "history.replaceState(null, '', \(HomeSlots.json(hash))); dispatchEvent(new HashChangeEvent('hashchange'))"
    }

    /// A script for the preview's page start: `focus()` does nothing there.
    public static let previewNoFocus = "HTMLElement.prototype.focus = function () {};"

    /// The whole page for a web view: the packer's head, styles and body class, without its search words or footer.
    public static func document(_ page: HouseholdPage, guideTitles: [String: String]) -> String {
        "<!doctype html><html lang=\"en\"><head><meta charset='utf-8'>"
            + "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            + "<title>\(escape(page.title))</title><style>\(assets?.style ?? "")</style></head>"
            + "<body class='steps-page home-page'>\(body(page, mediaID: "", guideTitles: guideTitles))</body></html>"
    }

    /// packer.steps.body: `guideTitles` is packed path ("id.html") to title; `backHome` nil is the Our Home section's
    /// page, "" leaves Back to Our Home out.
    public static func body(_ page: HouseholdPage, mediaID: String, guideTitles: [String: String],
                            backHome: String? = nil) -> String {
        let esc = escape
        let n = page.steps.count
        let titleOf = { (i: Int) -> String in
            guard i >= 1, i <= n else { return "" }  // a Yes or No the editor hasn't fixed yet
            let step = page.steps[i - 1]
            // packer.steps._blanks_plain: a blank as its answer or its question, never "[Fill in: …]"
            return step.name.isEmpty ? HomeCard.parts(step.words).map(\.text).joined() : step.name
        }

        func warn(_ kind: String, _ text: String) -> String {
            let (mark, word) = kind == "danger" ? ("⚠️", w("DANGER")) : ("🟠", w("CAUTION"))
            return "<div class=\"hp-warn hp-\(kind)\"><b><span aria-hidden=\"true\">\(mark)</span> \(word)</b>"
                + "<p>\(markCalls(blanksShown(text)))</p></div>"
        }

        let chips = (0..<n).map { i in
            "<li><a class=\"hp-go-step\" href=\"#step-\(i + 1)\"><span class=\"k\">\(i + 1)</span>\(esc(titleOf(i + 1)))</a></li>"
        }.joined()
        let left = page.blanksLeft
        var start = ["<div class=\"hp-resume\" id=\"hp-resume\" hidden><p></p><div class=\"hp-answer\">"
            + "<a class=\"hp-btn\" href=\"#start\" id=\"hp-over\">\(esc(w("START_OVER")))</a>"
            + "<a class=\"hp-btn go\" href=\"#step-1\">\(esc(w("GO_ON")))</a></div></div>"]
        if !page.when.isEmpty {
            start.append("<div class=\"hp-when\"><span>\(esc(w("USE_WHEN")))</span><p>\(blanksShown(page.when))</p></div>")
        }
        if !page.danger.isEmpty { start.append(warn("danger", page.danger)) }
        if !page.need.isEmpty || !page.things.isEmpty {
            start.append("<h2>\(esc(w("NEED")))</h2><ul class=\"hp-need\">" + page.need.map {
                "<li><span class=\"what\">\(esc($0))</span>\(slot("items", [$0]))</li>"
            }.joined() + page.things.map {
                "<li><span class=\"what\">\(esc($0.words))</span>\(pickedSlot("thing", $0))</li>"
            }.joined() + "</ul>")
        }
        start.append("<h2>\(esc(w("STEPS_LIST")))</h2><ol class=\"hp-list\">\(chips)</ol>"
            + "<div class=\"hp-answer\"><a class=\"hp-btn go\" href=\"#step-1\">\(esc(w("START")))</a></div>")
        if !page.sources.isEmpty && !page.checked.isEmpty {
            let marked = page.steps.filter { !$0.checked.isEmpty }
            let k = marked.filter { HouseholdPage.checkedHash($0.words) == $0.checked }.count
            start.append("<p class=\"hp-small hp-checked\">"
                + esc(format(w("CHECKED_LINE"), ["sources": page.sources, "date": page.checked]))
                + (k < marked.count ? " " + esc(format(w("CHECKED_COUNT"), ["k": "\(k)", "n": "\(marked.count)"])) : "")
                + "</p>")
        } else {
            start.append("<p class=\"hp-small hp-checked\">\(esc(w("HOUSE_LINE")))</p>")
        }
        var screens = ["<section class=\"hp-screen hp-start\" id=\"start\" tabindex=\"-1\">\(start.joined())</section>"]
        for (index, step) in page.steps.enumerated() {
            let i = index + 1
            var parts: [String] = []
            if !step.danger.isEmpty { parts.append(warn("danger", step.danger)) }
            if !step.caution.isEmpty { parts.append(warn("caution", step.caution)) }
            if !step.name.isEmpty { parts.append("<span class=\"hp-label\">\(esc(step.name))</span>") }
            if !step.checked.isEmpty && HouseholdPage.checkedHash(step.words) != step.checked {
                parts.append("<p class=\"hp-changed\">\(esc(w("STEP_CHANGED")))</p>")
            }
            parts.append("<p class=\"hp-words\">\(markCalls(blanksShown(step.words)))</p>")
            if !step.video.isEmpty && !mediaID.isEmpty {
                let poster = step.photo.isEmpty ? "" : " poster=\"\(esc(step.photo))\""
                parts.append("<div class=\"hp-photo hp-video\"><video controls playsinline preload=\"metadata\"\(poster) "
                    + "src=\"zim://\(esc(mediaID))/\(esc(step.video))\"></video></div>"
                    + "<p class=\"note no-video\" hidden>\(esc(w("NO_VIDEO")))</p>")
            } else if !step.photo.isEmpty {
                let src = esc(step.photo)
                parts.append("<div class=\"hp-photo\"><img src=\"\(src)\" alt=\"\(esc(format(w("PHOTO_ALT"), ["i": "\(i)"])))\">"
                    + "<a class=\"hp-open\" href=\"\(src)\"><span aria-hidden=\"true\">⤢</span> \(esc(w("OPEN_PHOTO")))</a></div>")
            }
            if !step.ticks.isEmpty {
                parts.append("<ul class=\"hp-ticks\">" + step.ticks.map {
                    "<li><label><input type=\"checkbox\" autocomplete=\"off\"><span>\(esc($0))</span></label></li>"
                }.joined() + "</ul><p class=\"hp-small hp-ticked\">"
                    + esc(format(w("TICKED"), ["k": "0", "n": "\(step.ticks.count)"])) + "</p>")
            }
            if let call = step.call {
                parts.append("<p class=\"hp-call\"><span class=\"tel\" data-tel=\"\(call.number)\"><span class=\"hp-call-em\" "
                    + "aria-hidden=\"true\">📞</span><b>\(esc(format(w("CALL"), ["label": call.label])))</b>"
                    + "<small>\(shownNumber(call.number))</small></span></p>")
            }
            let answer: String
            if let yes = step.yes {
                answer = [(w("YES"), yes), (w("NO"), step.no ?? 0)].map { word, to in
                    "<a class=\"hp-btn yn\" href=\"#step-\(to)\">\(word)<small>"
                        + esc(format(w("ANSWER_TO"), ["n": "\(to)", "name": titleOf(to)])) + "</small></a>"
                }.joined()
            } else {
                let back = i > 1 ? "#step-\(i - 1)" : "#start"
                let ahead = i < n
                    ? "<a class=\"hp-btn go\" href=\"#step-\(i + 1)\">\(esc(w("HOME_NEXT")))<small>\(esc(titleOf(i + 1)))</small></a>"
                    : "<a class=\"hp-btn go\" href=\"#done\">\(esc(w("HOME_NEXT")))</a>"
                answer = "<a class=\"hp-btn\" href=\"\(back)\">\(esc(w("BACK")))</a>\(ahead)"
            }
            parts.append("<div class=\"hp-answer\">\(answer)</div>")
            if step.meet { parts.append(slot("meet")) }
            if !step.items.isEmpty { parts.append(slot("items", step.items)) }
            if let place = step.place { parts.append(placeLine(place)) }
            if let manual = step.manual { parts.append(pickedSlot("manual", manual)) }
            var links = foot(page.title, map: step.map, words: step.items,
                             calculators: calculators[step.calculator].map { [("\(step.calculator).html", $0)] } ?? [])
            if !step.guide.isEmpty, let title = guideTitles["\(step.guide).html"] {
                links += "<p class=\"hp-guide\"><a href=\"\(esc(step.guide)).html\">\(esc(title))</a></p>"
            }
            parts.append(links)
            screens.append("<section class=\"hp-screen\" id=\"step-\(i)\" tabindex=\"-1\" data-name=\"\(esc(titleOf(i)))\">"
                + "<div class=\"hp-step\">\(parts.joined())</div></section>")
        }
        var end = ["<div class=\"hp-done\"><span class=\"mark\" aria-hidden=\"true\">✓</span><div><h2>\(esc(w("DONE")))</h2>"
            + "<p>\(esc(format(w("END_COUNT"), ["n": "\(n)"])))</p></div></div>"]
        let links = page.guides.compactMap { g in guideTitles["\(g).html"].map { (g, $0) } }
        if !page.next.isEmpty || !links.isEmpty {
            end.append("<div class=\"hp-next\"><b>\(esc(w("WHAT_NEXT")))</b>"
                + (page.next.isEmpty ? "" : "<p>\(markCalls(esc(page.next)))</p>")
                + links.map { "<p><a href=\"\(esc($0.0)).html\">\(esc($0.1))</a></p>" }.joined() + "</div>")
        }
        if !page.walked.isEmpty {
            end.append("<p class=\"hp-small\">\(esc(format(w("WALKED"), ["date": shownDate(page.walked)])))</p>")
        }
        let home = backHome ?? w("BACK_HOME_PAGE")
        let homeButton = home.isEmpty ? "" : "<a class=\"hp-btn go\" href=\"\(esc(home))\">\(esc(w("BACK_HOME")))</a>"
        end.append("<div class=\"hp-answer\"><a class=\"hp-btn\" href=\"#start\">\(esc(w("START_OVER")))</a>\(homeButton)</div>")
        screens.append("<section class=\"hp-screen hp-end\" id=\"done\" tabindex=\"-1\">\(end.joined())</section>")
        let unfinished = left == 0 ? "" : "<p class=\"hp-unfinished\">"
            + esc(left == 1 ? w("BLANK_LEFT") : format(w("BLANKS_LEFT"), ["n": "\(left)"])) + "</p>"
        return "<div class=\"hp-strip\"><div class=\"hp-home\"><span><span aria-hidden=\"true\">\(w("HOUSE_EMOJI"))</span> "
            + "\(esc(w("HOME_NAME")))</span><span class=\"n\" id=\"hp-count\" aria-live=\"polite\"></span></div>"
            + "<h1>\(esc(page.title))</h1></div>\(unfinished)"
            + "<details class=\"hp-jump\"><summary>\(esc(w("ALL_STEPS_FOLD")))</summary><ol>\(chips)</ol></details>"
            + "<div class=\"hp-layout\"><ol class=\"hp-side\">\(chips)</ol><div class=\"hp-screens\">\(screens.joined())</div>"
            + "</div>\(assets?.script ?? "")"
    }

    static func w(_ name: String) -> String { assets?.words[name] ?? "" }
    /// One of the page's fixed words by its packer/steps.py name, for the editor (STEP_CHANGED)
    public static func word(_ name: String) -> String { w(name) }

    /// Python's html.escape: &, <, >, " and ' (as &#x27;).
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    /// Python's str.format with named fields, in one pass, so a value holding "{date}" stays as typed.
    static func format(_ template: String, _ values: [String: String]) -> String {
        let field = try! NSRegularExpression(pattern: #"\{(\w+)\}"#)
        let text = template as NSString
        var out = "", at = 0
        for m in field.matches(in: template, range: NSRange(location: 0, length: text.length)) {
            out += text.substring(with: NSRange(location: at, length: m.range.location - at))
            let key = text.substring(with: m.range(at: 1))
            out += values[key] ?? text.substring(with: m.range)
            at = m.range.location + m.range.length
        }
        return out + text.substring(from: at)
    }

    /// steps._blanks_shown: escaped, an unfilled blank as BLANK_Q in its dashed mark, a filled one as its answer.
    static func blanksShown(_ text: String) -> String {
        let ns = text as NSString
        var out = "", at = 0
        for m in HouseholdPage.blank.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += escape(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            if m.range(at: 2).location != NSNotFound {
                out += escape(ns.substring(with: m.range(at: 2)))
            } else {
                out += "<span class=\"hp-blank\">\(escape(format(w("BLANK_Q"), ["question": ns.substring(with: m.range(at: 1))])))</span>"
            }
            at = m.range.location + m.range.length
        }
        return out + escape(ns.substring(from: at))
    }

    /// packer.pages.mark_calls: 911 and Poison Control in the text (never in a link, heading, script, style, title or a
    /// tag) wrapped in <span class="tel" data-tel="NUMBER">, by the packer's own pattern and table.
    static func markCalls(_ markup: String) -> String {
        guard let assets, let number = try? NSRegularExpression(pattern: assets.call_number) else { return markup }
        func wrap(_ text: String) -> String {
            let ns = text as NSString
            var out = "", at = 0
            for m in number.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let group = assets.calls.keys.sorted().first { m.range(withName: $0).location != NSNotFound } ?? ""
                out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
                out += "<span class=\"tel\" data-tel=\"\(assets.calls[group] ?? "")\">\(ns.substring(with: m.range))</span>"
                at = m.range.location + m.range.length
            }
            return out + ns.substring(from: at)
        }
        let tags = try! NSRegularExpression(pattern: "<[^>]*>")
        let opens = try! NSRegularExpression(pattern: #"^<(a|h[1-6]|script|style|title)\b"#, options: .caseInsensitive)
        let ns = markup as NSString
        var out = "", skip: String?, at = 0
        for tag in tags.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: NSRange(location: at, length: tag.range.location - at))
            let t = ns.substring(with: tag.range)
            out += skip == nil ? wrap(text) : text
            out += t
            at = tag.range.location + tag.range.length
            if let open = skip {
                if t.range(of: "^</\(open)\\s*>$", options: [.regularExpression, .caseInsensitive]) != nil { skip = nil }
            } else if let m = opens.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)),
                      !t.hasSuffix("/>") {
                skip = (t as NSString).substring(with: m.range(at: 1))
            }
        }
        let rest = ns.substring(from: at)
        return out + (skip == nil ? wrap(rest) : rest)
    }

    static func shownDate(_ iso: String) -> String {
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                      "November", "December"]
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
        return "\(months[parts[1] - 1]) \(parts[2]), \(parts[0])"
    }

    /// packer.steps._shown_number: ten digits as (202) 555-0123, eleven starting with 1 as 1 (202) 555-0123, any
    /// other its digits; the editor tidies a number to this look when its box loses the keyboard.
    public static func shownNumber(_ digits: String) -> String {
        if digits.count == 11, digits.hasPrefix("1") { return "1 " + shownNumber(String(digits.dropFirst())) }
        let d = Array(digits)
        guard d.count == 10 else { return escape(digits) }
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6...]))"
    }

    /// packer.steps._picked_slot: a picked manual's or thing's empty slot, "" for a typed thing.
    static func pickedSlot(_ kind: String, _ picked: HouseholdPage.Picked) -> String {
        guard let id = picked.id else { return "" }
        return "<p class=\"pm-pick\" data-slot=\"\(kind)\" data-id=\"\(id)\" hidden></p>"
    }

    /// packer.steps._place: typed, plain words; picked, its path as picked in a slot PrepareMe fills by its id.
    static func placeLine(_ place: HouseholdPage.Picked) -> String {
        guard let id = place.id else { return "<p class=\"hp-place\">📍 \(escape(place.words))</p>" }
        return "<p class=\"hp-place pm-pick\" data-slot=\"place\" data-id=\"\(id)\">📍 \(escape(place.words))</p>"
    }

    static func slot(_ kind: String, _ words: [String] = []) -> String {
        if kind == "meet" { return "<p class=\"pm-slot\" data-slot=\"meet\">\(escape(w("MEET_FALLBACK")))</p>" }
        return "<p class=\"pm-slot\" data-slot=\"items\" data-words=\"\(escape(words.joined(separator: ";")))\">"
            + "\(escape(w("ITEMS_FALLBACK")))</p>"
    }

    /// guide_links.foot: the map and house links, then the calculators.
    static func foot(_ title: String, map: Bool, words: [String], calculators: [(String, String)]) -> String {
        func row(_ href: String, _ emoji: String, _ words: String) -> String {
            let said = escape(words)
            return "<p><a href=\"\(escape(href))\" aria-label=\"\(said)\"><span class=\"em\" aria-hidden=\"true\">"
                + "\(emoji)</span><span class=\"pm-label\" data-label=\"\(said)\"></span></a></p>"
        }
        var rows: [String] = []
        if map { rows.append(row(w("STREET_MAP_URL"), w("MAP_EMOJI"), w("MAP_LINK"))) }
        if !words.isEmpty {
            let url = "\(w("HOUSE_URL"))?for=\(quote(title))&words=\(words.map(quote).joined(separator: ","))"
            rows.append(row(url, w("HOUSE_EMOJI"), w("HOUSE_LINK")))
        }
        var out = rows.isEmpty ? "" : "<nav class=\"pm-links\">\(rows.joined())</nav>"
        if !calculators.isEmpty {
            out += "<nav class=\"calc-links\">" + calculators.map { page, name in
                "<p><a href=\"\(escape(page))\">\(escape(format(w("CALCULATOR_LINK"), ["name": name])))</a></p>"
            }.joined() + "</nav>"
        }
        return out
    }

    /// Python's quote(text, safe=''): every byte but ASCII letters, digits and _.-~ percent-encoded.
    static func quote(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~")
        return text.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
    }
}
