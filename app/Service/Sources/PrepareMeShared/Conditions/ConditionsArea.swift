import Foundation

/// The home state's details for the phone's own reading (Unlisted plan, phase 4, decision 2), packed by the Mac into the
/// daily library as `household/conditions-area.json` beside the settings (packer/phone_settings.py `area_content`), so
/// this code, which is published, names no state: the power outage and evacuation feeds' addresses, the agency's name
/// and page shown with them, the evacuations note, and the state's county names the outage table is checked against.
/// Unlike the settings file, a key it doesn't know is ignored (a later key needs no new format); a missing one, an
/// address that isn't https, or a format other than `format` refuses the file. With none, the phone reads neither feed
/// and says so; nothing is built in to fall back on.
public struct ConditionsArea: Equatable, Sendable {
    public static let path = "household/conditions-area.json"
    public static let format = 1

    public let outages: URL, evacuations: URL
    public let agency: String, agencyLink: String, evacNote: String
    public let counties: [String]
    /// Each county name folded as the outage reader compares them.
    let folded: Set<String>

    public init(_ data: Data) throws {
        struct Raw: Decodable {
            let format: Int
            let outages, evacuations, agency, agency_link, evac_note: String
            let counties: [String]
        }
        guard data.count <= 64_000, let raw = try? JSONDecoder().decode(Raw.self, from: data),
              raw.format == Self.format,
              let outages = Self.https(raw.outages), let evacuations = Self.https(raw.evacuations),
              Self.https(raw.agency_link) != nil,
              Self.plain(raw.agency), Self.plain(raw.evac_note),
              (1...400).contains(raw.counties.count), raw.counties.allSatisfy({ $0.count <= 40 && Self.plain($0) })
        else { throw ConditionsSettings.Problem.notTheShape }
        self.outages = outages
        self.evacuations = evacuations
        agency = raw.agency
        agencyLink = raw.agency_link
        evacNote = raw.evac_note
        counties = raw.counties
        folded = Set(raw.counties.map(\.folded))
    }

    static func https(_ text: String) -> URL? {
        guard text.count <= 300, let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// One line of ordinary text, under 300 characters.
    static func plain(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 300 && !text.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" })
    }
}
