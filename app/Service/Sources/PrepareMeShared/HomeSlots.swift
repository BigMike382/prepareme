import Foundation

/// What fills an Our Home page's slots (docs/plans/2026-11-16-our-home.md, Task 2.4; phase 0's proof,
/// docs/design/our-home/proving.md). The packer writes each slot with fallback words that stand alone
/// (`<p class="pm-slot" data-slot="meet">` and `<p class="pm-slot" data-slot="items" data-words="w1;w2">`); when
/// PrepareMe shows a page of the daily library it reads the page's slots (`readScript`), finds what they ask for in
/// the phones' copy of the lists only (never a Private row or a Mac-only column, on the Mac too), and runs `script`,
/// which lays the fact under each slot and hides its fallback words. With nothing to show for a slot, its fallback
/// words stay. Shown again, it replaces what it laid before, so a copy that changed fills the page again.
public enum HomeSlots {
    /// An item a slot found: its name as typed in the lists, where it's kept (its place's full path) and its manual's
    /// address in the manuals library ("" when it has none).
    public struct Kept: Equatable, Sendable, Encodable {
        public let name: String
        public let place: String
        public let manual: String
        public init(name: String, place: String, manual: String) {
            self.name = name
            self.place = place
            self.manual = manual
        }
    }

    /// The slot's fixed words, packer/steps.py's KEPT, MEET and READ_MANUAL with the boards' marks (pinned in
    /// packer/tests/test_steps.py).
    public static let keptHeading = "📍 Where it's kept", meetHeading = "🗺️ Our meeting places"
    public static let readManual = "Read the manual"

    /// Each item whose name holds one of `words` (GuideLinks.matches, as a guide's In the house), in the lists' order.
    public static func kept(words: [String], in items: [(name: String, place: String, manual: String)]) -> [Kept] {
        items.filter { GuideLinks.matches($0.name, words) }.map { Kept(name: $0.name, place: $0.place, manual: $0.manual) }
    }

    /// The copy's items as a slot finds them: name as typed, place as its full path, manual as its address.
    public static func items(_ copy: PhoneInventory) -> [(name: String, place: String, manual: String)] {
        copy.items.map { row in
            let found = kept(row, in: copy)
            return (found.name, found.place, found.manual)
        }
    }

    static func kept(_ row: PhoneInventory.Row, in copy: PhoneInventory) -> Kept {
        let place = copy.column("Location").map { column in
            row.values[column.colId]?.whole.flatMap { id in copy.places.contains { $0.id == id } ? copy.path(id) : nil }
                ?? copy.cell(row, column)
        } ?? ""
        return Kept(name: copy.itemName(row), place: place, manual: row.manual.map { "zim://\(ItemManuals.volumeID)/\($0)" } ?? "")
    }

    // The editor's picked places, manuals and things (docs/plans/2026-11-20-our-home-editor.md, Task 2). The
    // inventory never gives a deleted Locations or Inventory row's id to another (InventoryFile.numberedForGood), so a
    // picked id is followed: renamed or moved, it fills with its current path or name (owner, 2026-11-20, by click).
    // An id the copy no longer has keeps the page's own words.

    /// A picked place's current full path, or nil when the copy has no place `id`.
    public static func place(id: Int64, in copy: PhoneInventory) -> String? {
        copy.places.contains { $0.id == id } ? copy.path(id) : nil
    }

    /// A picked item (a manual or a thing) as a slot shows it, or nil when the copy has no item `id`.
    public static func item(id: Int64, in copy: PhoneInventory) -> Kept? {
        copy.items.first { $0.id == id }.map { kept($0, in: copy) }
    }

    /// What the page's picked slots (`readScript`'s rows of kind place, manual or thing) found, keyed by id, so a page
    /// that reloads between the two trips still fills each slot with its own (the review, 2026-11-20). `links`: a
    /// place's link to its screen in Lists (phone and iPad; the Mac shows plain words).
    public static func picked(_ slots: [[String]], in copy: PhoneInventory?, links: Bool)
        -> (places: [String: Place], items: [String: Kept]) {
        var places: [String: Place] = [:], items: [String: Kept] = [:]
        guard let copy else { return (places, items) }
        for slot in slots where slot.count == 3 {
            guard let id = Int64(slot[2]) else { continue }
            if slot[0] == "place", let path = place(id: id, in: copy) {
                places[slot[2]] = Place(path: path, link: links ? placeLink(id) : "")
            } else if ["manual", "thing"].contains(slot[0]), let item = item(id: id, in: copy) {
                items[slot[2]] = item
            }
        }
        return (places, items)
    }

    /// A filled place: its path, and on a phone or iPad the link that opens it in Lists ("" on the Mac).
    public struct Place: Equatable, Sendable, Encodable {
        public let path: String
        public let link: String
        public init(path: String, link: String) {
            self.path = path
            self.link = link
        }
    }

    /// The link a filled place opens on a phone or iPad: that place's screen in Lists, the bin label's own link
    /// (Barcode.placeURL; Barcode.place(in:) reads it).
    public static func placeLink(_ id: Int64) -> String { Barcode.placeURL(id).absoluteString }

    /// The meeting places' names, near home first (their role's order), never a route, a pin or the Start point.
    public static func meet(_ copy: PhoneInventory) -> [String] {
        (copy.marks ?? []).filter { $0.kind == .rally && !$0.name.isEmpty }
            .sorted { ($0.role ?? .outOfTown, $0.id) < ($1.role ?? .outOfTown, $1.id) }.map(\.name)
    }

    /// The first trip: the page's slots as [kind, words, id], or null on a page with none. The editor's picked kinds
    /// carry `pm-pick`, never `pm-slot`: an app before the editor's fresh look shows every `pm-slot` it finds, and
    /// would show a picked manual's empty slot as an empty box.
    public static let readScript = """
        (function () { var s = document.querySelectorAll('.home-page .pm-slot, .home-page .pm-pick');
          if (!s.length) return null;
          return [].map.call(s, function (e) { return [e.dataset.slot || '', e.dataset.words || '', e.dataset.id || '']; }); })();
        """

    /// The second trip: `meet`, the meeting places' names; `kept`, each items slot's words ("w1;w2") to what they
    /// found; `places` and `items`, what a picked place, manual or thing slot found, by its id (`picked`), none for an
    /// id the copy no longer has. Every value goes in as JSON and reaches the page as text only (textContent), never
    /// as markup; a place's link is built in Swift from its id.
    public static func script(meet: [String], kept: [String: [Kept]], places: [String: Place] = [:],
                              items: [String: Kept] = [:]) -> String {
        """
        (function (meet, kept, places, items, w) {
          [].forEach.call(document.querySelectorAll('.home-page .hp-filled'), function (e) { e.remove(); });
          [].forEach.call(document.querySelectorAll('.home-page .pm-slot, .home-page .pm-pick'), function (slot) {
            var kind = slot.dataset.slot, id = slot.dataset.id || '', line, a;
            if (kind === 'place' || kind === 'manual') {  // a line under the step's buttons, in place of the slot
              var p = places[id], k = items[id];
              slot.hidden = kind === 'manual';
              if (kind === 'place' ? !p : !(k && k.manual)) return;
              line = document.createElement('p');
              line.className = 'hp-place hp-filled';
              a = document.createElement(kind === 'manual' || p.link ? 'a' : 'span');
              if (kind === 'manual') { a.href = k.manual; a.className = 'hp-manual'; a.textContent = '\u{1F4D6} ' + w.manual; }
              else { if (p.link) a.href = p.link; a.textContent = '\u{1F4CD} ' + p.path; }
              line.appendChild(a);
              slot.hidden = true;
              slot.parentNode.insertBefore(line, slot.nextSibling);
              return;
            }
            var found = kind === 'meet' ? meet : kind === 'thing' ? (items[id] ? [items[id]] : []) : kept[slot.dataset.words || ''] || [];
            slot.hidden = kind === 'thing';
            if (!found.length) return;
            // a thing's row already names it: the item's current name replaces those words, and only its place and
            // manual go under it, so the name shows once (the design session's second review, 2026-11-20)
            var what = kind === 'thing' ? slot.parentNode.querySelector('.what') : null;
            if (what) { what.textContent = found[0].name; if (!found[0].place && !found[0].manual) return; }
            var box = document.createElement('div'), list = document.createElement('ul');
            var inNeed = !!slot.closest('.hp-need');
            box.className = 'hp-fact hp-filled';
            if (!inNeed) {
              var head = document.createElement('b');
              head.textContent = slot.dataset.slot === 'meet' ? w.meet : w.kept;
              box.appendChild(head);
            }
            found.forEach(function (k) {
              var li = document.createElement('li');
              if (typeof k === 'string') { li.textContent = k; } else {
                if (!what) li.appendChild(document.createTextNode(k.name));
                if (k.place) {  // an item with no place in the lists shows its name alone
                  var place = document.createElement('span');
                  place.className = 'place';
                  place.textContent = (inNeed ? '\\u{1F4CD} ' : '') + k.place;
                  if (!what) li.appendChild(document.createTextNode(': '));
                  li.appendChild(place);
                }
                if (k.manual) {
                  var a = document.createElement('a');
                  a.href = k.manual;
                  a.className = 'hp-manual';
                  a.textContent = w.manual;
                  if (li.firstChild) li.appendChild(document.createTextNode(' '));
                  li.appendChild(a);
                }
              }
              list.appendChild(li);
            });
            box.appendChild(list);
            slot.hidden = true;
            slot.parentNode.insertBefore(box, slot.nextSibling);
          });
        })(\(json(meet)), \(json(kept)), \(json(places)), \(json(items)), \(json(["kept": keptHeading, "meet": meetHeading, "manual": readManual])));
        """
    }

    /// JSON as JavaScript reads it: a "<" and the two line separators escaped too, so no value can end a script.
    public static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
        return text.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
