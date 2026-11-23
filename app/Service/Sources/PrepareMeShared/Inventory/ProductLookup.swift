import Foundation

/// A product's name from its barcode, looked up on the web while scanning (owner, 2026-10-14, by click: Open Food Facts
/// first, then UPCitemdb's free plan; 2026-10-22, by click: USDA FoodData Central too, for a food's servings and
/// calories; 2026-10-23, at the entry fixes' phase 2 gate, in chat: Open Beauty Facts and Open Products Facts, for the
/// medicine cabinet and the household's goods; same day, in chat: the FDA's drug list, openFDA, for a medicine whose
/// barcode carries its drug code, and UPC Database, with the owner's free key). Only the barcode number is sent. Each service's own API page sets its limits (read 2026-10-14 and
/// 2026-10-22): Open Food Facts, 15 product reads a minute, no account, a User-Agent naming the app; UPCitemdb's free
/// plan, 100 requests a day and 6 a minute, no key; USDA, 1,000 requests an hour with the owner's api.data.gov key, 30
/// an hour and 50 a day with its public DEMO_KEY (`LookupPacer` keeps under each). Their answers are web text: trimmed
/// and shown in the form for the owner to keep or change, and through the same ID check as anything typed before
/// anything is kept. A code none knows is the owner's to name.
public struct ProductInfo: Equatable, Sendable {
    public let name: String
    public let brand: String
    public let model: String
    public let size: String  // "400 g", "16.9 fl oz": the package's own words, for the Notes or the name
    public let source: String  // the name's service, shown under the name
    /// A food's figures, from one food service or both (`ProductLookup.merge`), and which gave them ("USDA", "USDA and
    /// Open Food Facts"); empty for anything else.
    public let figures: FoodFigures
    public let figuresFrom: String

    public init(name: String, brand: String = "", model: String = "", size: String = "", source: String,
                figures: FoodFigures = FoodFigures(), figuresFrom: String = "") {
        self.name = name
        self.brand = brand
        self.model = model
        self.size = size
        self.source = source
        self.figures = figures
        self.figuresFrom = figuresFrom
    }

    /// The whole package's calories (step 8a), offered as the item's Calories each, never kept unless the person saves.
    public var calories: Int? { figures.wholeCalories }
    /// A serving's calories, rounded, and the servings in the package to a tenth (owner, 2026-10-22): the form's boxes.
    public var perServing: Int? { figures.servingCalories.map { Int($0.rounded()) } }
    public var servings: Double? { figures.servings }
    /// The serving as the service words it ("120 ml", "1/2 cup (120mL) condensed soup").
    public var serving: String { figures.servingWords }
}

/// An amount in grams or millilitres, the two units the calorie figures are per 100 of.
public struct Amount: Codable, Equatable, Sendable {
    public let value: Double
    public let unit: String  // "g" or "ml"

    public init(_ value: Double, _ unit: String) {
        self.value = value
        self.unit = unit
    }
}

/// A food's figures as one service gives them, or as two merged: the package, a serving, the energy per 100 g (per
/// 100 ml for a drink) and a serving's own energy, in kilocalories. What the card shows is worked out from them.
public struct FoodFigures: Codable, Equatable, Sendable {
    public var package: Amount?
    public var packageWords = ""
    public var serving: Amount?
    public var servingWords = ""
    public var per100: Double?
    public var perServing: Double?

    public init(package: Amount? = nil, packageWords: String = "", serving: Amount? = nil, servingWords: String = "",
                per100: Double? = nil, perServing: Double? = nil) {
        self.package = package
        self.packageWords = packageWords
        self.serving = serving
        self.servingWords = servingWords
        self.per100 = per100
        self.perServing = perServing
    }

    /// Whether it holds any figure at all.
    public var isEmpty: Bool { package == nil && serving == nil && per100 == nil && perServing == nil }

    /// A serving's calories: its own figure, else the energy per 100 times its size. Nil when neither, under half a
    /// calorie, over a package's most, or over pure fat's 9 a gram of the serving's size (a wrong figure).
    public var servingCalories: Double? {
        let found: Double
        if let perServing {
            found = perServing
        } else if let per100, let serving {
            found = per100 * serving.value / 100
        } else {
            return nil
        }
        if let serving, found / serving.value * 100 > ProductLookup.mostPer100 { return nil }
        guard found >= 0.5, found <= ProductLookup.mostPerPackage else { return nil }
        return found
    }

    /// The servings in the package, to a tenth: its size over a serving's, both in the same unit; never across units.
    public var servings: Double? {
        guard let package, let serving, package.unit == serving.unit else { return nil }
        let found = (package.value / serving.value * 10).rounded() / 10
        guard found >= 0.1, found <= 10_000 else { return nil }
        return found
    }

    /// The whole package's calories: a serving's (rounded) times the servings, as the card's boxes multiply them, else
    /// the energy per 100 times the package. Nil when neither, or outside 1 to a package's most.
    public var wholeCalories: Int? {
        let total: Double
        if let each = servingCalories, let count = servings {
            total = each.rounded() * count
        } else if let per100, let package {
            total = per100 * package.value / 100
        } else {
            return nil
        }
        guard total >= 1, total <= ProductLookup.mostPerPackage else { return nil }
        return Int(total.rounded())
    }
}

public enum ProductLookup {
    public static let foodHost = "world.openfoodfacts.org"
    public static let goodsHost = "api.upcitemdb.com"
    public static let usdaHost = "api.nal.usda.gov"
    public static let beautyHost = "world.openbeautyfacts.org", productsHost = "world.openproductsfacts.org"
    public static let fdaHost = "api.fda.gov", upcdbHost = "api.upcdatabase.org"
    public static let hosts: Set<String> = [foodHost, goodsHost, usdaHost, beautyHost, productsHost, fdaHost, upcdbHost]
    public static let foodName = "Open Food Facts", goodsName = "UPCitemdb", usdaName = "USDA"
    public static let beautyName = "Open Beauty Facts", productsName = "Open Products Facts"
    public static let fdaName = "the FDA's drug list", upcdbName = "UPC Database"
    /// The Info.plist entry the owner's UPC Database key is built into at install (kiwix-mac/build.sh, from Household
    /// Private › Keys › upcdatabase-key.txt); without it that source is never asked.
    public static let upcdbKeyEntry = "PrepareMeUPCDBKey"
    public static let userAgent = "PrepareMe/1.0 (one household's preparedness inventory)"
    public static let nameLimit = 80, brandLimit = 40, sizeLimit = 30
    /// USDA's public key, for a build without the owner's (a session's test builds, or before the owner saved one):
    /// 30 lookups an hour and 50 a day.
    public static let demoKey = "DEMO_KEY"
    /// The Info.plist entry the owner's key is built into at install (kiwix-mac/build.sh, from Household Private ›
    /// Keys › usda-key.txt); a build without it has the project's DEMO_KEY.
    public static let keyEntry = "PrepareMeUSDAKey"

    public enum Service: String, Codable, Sendable { case food, goods, usda, beauty, products, fda, upcdb }

    /// The UPC Database key built in, or nil when none is (an empty or unfilled setting).
    public static func upcdbKey(_ built: String?) -> String? {
        let key = (built ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key.hasPrefix("$(") || !key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            ? nil : key
    }

    /// A medicine's drug code (NDC) in its barcode: a UPC-A of 3, the 10-digit code and a check digit (13 digits
    /// with a leading 0 as Barcode.valid keeps them). The barcode drops the code's hyphens, so all three layouts are
    /// asked (4-4-2, 5-3-2, 5-4-1). Nil for any other barcode: the FDA's list isn't asked for it.
    public static func ndcForms(_ code: String) -> [String]? {
        let digits = code.count == 13 && code.hasPrefix("0") ? String(code.dropFirst()) : code
        guard digits.count == 12, digits.hasPrefix("3"), digits.allSatisfy(\.isNumber) else { return nil }
        let ndc = Array(digits.dropFirst().prefix(10)).map(String.init)
        func split(_ a: Int, _ b: Int) -> String {
            ndc[0..<a].joined() + "-" + ndc[a..<(a + b)].joined() + "-" + ndc[(a + b)...].joined()
        }
        return [split(4, 4), split(5, 3), split(5, 4)]
    }

    /// The services that answer for a food.
    public static func isFood(_ source: String) -> Bool { source == foodName || source == usdaName }

    /// The key to send USDA: the one built in, else its public one.
    public static func usdaKey(_ built: String?) -> String {
        let key = (built ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key.hasPrefix("$(") || !key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            ? demoKey : key
    }

    /// The address to ask, for a code Barcode.valid kept (digits only). USDA's key goes in the X-Api-Key header,
    /// never the address; it finds a branded food by its 14-digit GTIN (`gtinUpc:`, checked 2026-10-22: the 12- and
    /// 13-digit forms find nothing).
    public static func url(_ service: Service, code: String) -> URL? {
        guard !code.isEmpty, code.count <= 14, code.allSatisfy(\.isASCII), code.allSatisfy(\.isNumber) else {
            return nil
        }
        switch service {
        case .food:
            return URL(string: "https://\(foodHost)/api/v2/product/\(code)?fields=product_name,brands,quantity,"
                       + "product_quantity,product_quantity_unit,serving_size,serving_quantity,serving_quantity_unit,"
                       + "nutriments")
        case .goods:
            return URL(string: "https://\(goodsHost)/prod/trial/lookup?upc=\(code)")
        case .fda:  // the package's drug code in any of its layouts (checked 2026-10-23: 200 found, 404 none)
            guard let forms = ndcForms(code) else { return nil }
            let search = forms.map { "packaging.package_ndc:%22\($0)%22" }.joined(separator: "+")
            return URL(string: "https://\(fdaHost)/drug/ndc.json?search=\(search)&limit=1")
        case .upcdb:  // the key goes in the Authorization header, never the address
            return URL(string: "https://\(upcdbHost)/product/\(code)")
        case .beauty, .products:  // Open Food Facts' sister sites, its API: a name, a brand and the package's words
            return URL(string: "https://\(service == .beauty ? beautyHost : productsHost)/api/v2/product/\(code)"
                       + "?fields=product_name,brands,quantity")
        case .usda:
            let gtin = String(repeating: "0", count: 14 - code.count) + code
            return URL(string: "https://\(usdaHost)/fdc/v1/foods/search?query=gtinUpc:\(gtin)&dataType=Branded"
                       + "&pageSize=10")
        }
    }

    public enum Answer: Equatable, Sendable {
        case found(ProductInfo)
        case notFound
        case unreadable  // not the service's shape: tried again later, never guessed from
    }

    /// A service's answer by its HTTP status: 200 read as that service's shape; 404 "not here" (Open Food Facts gives
    /// it for a product its sister sites hold, checked 2026-10-23 with a bottle of rubbing alcohol: read as no answer,
    /// it made every such scan "Couldn't look it up now"); nil for anything else (a limit, the service down), asked
    /// again later.
    public static func answer(_ service: Service, status: Int, data: Data, code: String) -> Answer? {
        switch status {
        case 200:
            switch service {
            case .food: return readFood(data)
            case .usda: return readUSDA(data, code: code)
            case .goods: return readGoods(data)
            case .beauty: return readFood(data, source: beautyName)
            case .products: return readFood(data, source: productsName)
            case .fda: return readFDA(data)
            case .upcdb: return readUPCDB(data)
            }
        case 404: return .notFound
        default: return nil
        }
    }

    /// openFDA's answer: {"results": [{"brand_name", "generic_name", "labeler_name"}]}; its 404 is "none".
    public static func readFDA(_ data: Data) -> Answer {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = top["results"] as? [[String: Any]] else { return .unreadable }
        guard let drug = results.first else { return .notFound }
        var name = clean(drug["brand_name"] as? String, limit: nameLimit)
        if name.isEmpty { name = clean(drug["generic_name"] as? String, limit: nameLimit) }
        guard !name.isEmpty else { return .notFound }
        return .found(ProductInfo(name: name, brand: clean(drug["labeler_name"] as? String, limit: brandLimit),
                                  source: fdaName))
    }

    /// UPC Database's answer: {"success", "title", "brand"}; no product is a 404, or `success` false.
    public static func readUPCDB(_ data: Data) -> Answer {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard top["success"] as? Bool != false else { return .notFound }
        let name = clean(top["title"] as? String, limit: nameLimit)
        guard !name.isEmpty else { return .notFound }
        return .found(ProductInfo(name: name, brand: clean(top["brand"] as? String, limit: brandLimit),
                                  source: upcdbName))
    }

    /// Open Food Facts' answer: {"code", "status": 1 (found) or 0, "product": {"product_name", "brands", "quantity",
    /// "product_quantity" and its unit, "serving_size", "serving_quantity" and its unit, "nutriments"}}. Its sister
    /// sites (`source`) answer the same way; their products have no food figures.
    public static func readFood(_ data: Data, source: String = foodName) -> Answer {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = top["status"] as? NSNumber else { return .unreadable }
        guard status.intValue == 1, let product = top["product"] as? [String: Any] else { return .notFound }
        let name = clean(product["product_name"] as? String, limit: nameLimit)
        guard !name.isEmpty else { return .notFound }
        let brand = clean((product["brands"] as? String)?.split(separator: ",").first.map(String.init), limit: brandLimit)
        let size = clean(product["quantity"] as? String, limit: sizeLimit)
        guard source == foodName else { return .found(ProductInfo(name: name, brand: brand, size: size, source: source)) }
        let figures = foodFigures(product, size: size)
        return .found(ProductInfo(name: name, brand: brand, size: size, source: foodName, figures: figures,
                                  figuresFrom: figures.isEmpty ? "" : foodName))
    }

    /// Open Food Facts' figures (its API, read 2026-10-19): the net quantity and a serving in "g" or "ml" only (oz
    /// or a count is left out, never guessed), the label's kcal per 100 and per serving, else its kJ ÷ 4.184; a
    /// figure over pure fat's 900 a 100 is a wrong one, left out.
    static func foodFigures(_ product: [String: Any], size: String) -> FoodFigures {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        func energy(_ per: String) -> Double? {
            if let kcal = positive(nutriments["energy-kcal_\(per)"]) { return kcal }
            return positive(nutriments["energy-kj_\(per)"]).map { $0 / kilojoulesPerCalorie }
        }
        func amount(_ value: String, _ unit: String) -> Amount? {
            guard let found = positive(product[value]),
                  let unit = (product[unit] as? String)?.lowercased(), units.contains(unit) else { return nil }
            return Amount(found, unit)
        }
        return FoodFigures(package: amount("product_quantity", "product_quantity_unit"), packageWords: size,
                           serving: amount("serving_quantity", "serving_quantity_unit"),
                           servingWords: servingWords(product["serving_size"] as? String),
                           per100: energy("100g").flatMap { $0 <= mostPer100 ? $0 : nil },
                           perServing: energy("serving"))
    }

    /// USDA FoodData Central's search answer (read 2026-10-22): {"totalHits", "foods": [{"gtinUpc", "description",
    /// "brandName", "brandOwner", "servingSize", "servingSizeUnit" (GRM, MLT), "householdServingFullText",
    /// "packageWeight" (free text: "10.75 ONZ", "12 oz/340 g"), "publishedDate", "foodNutrients": [{"nutrientNumber"
    /// "208" kcal or "268" kJ, "value" per 100 g or ml}]}]}. Only a food whose GTIN is the code's counts (a search can
    /// find others); the latest published first.
    public static func readUSDA(_ data: Data, code: String) -> Answer {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let foods = top["foods"] as? [[String: Any]] else { return .unreadable }
        func digits(_ text: String) -> Substring { text.drop { $0 == "0" } }
        let same = foods.filter { ($0["gtinUpc"] as? String).map { digits($0) == digits(code) } ?? false }
            .sorted { ($0["publishedDate"] as? String ?? "") > ($1["publishedDate"] as? String ?? "") }
        guard let food = same.first else { return .notFound }
        let name = clean(food["description"] as? String, limit: nameLimit)
        guard !name.isEmpty else { return .notFound }
        let brand = clean(food["brandName"] as? String ?? food["brandOwner"] as? String, limit: brandLimit)
        let nutrients = food["foodNutrients"] as? [[String: Any]] ?? []
        func nutrient(_ number: String) -> Double? {
            positive(nutrients.first { "\($0["nutrientNumber"] ?? "")" == number }?["value"])
        }
        let per100 = nutrient("208") ?? nutrient("268").map { $0 / kilojoulesPerCalorie }
        let servingUnit: String? = switch (food["servingSizeUnit"] as? String)?.lowercased() {
        case "g", "grm": "g"
        case "ml", "mlt": "ml"
        default: nil
        }
        let serving = servingUnit.flatMap { unit in positive(food["servingSize"]).map { Amount($0, unit) } }
        let weight = food["packageWeight"] as? String ?? ""
        let size = packageWords(weight)
        let figures = FoodFigures(package: packageAmount(weight, unit: servingUnit), packageWords: size,
                                  serving: serving,
                                  servingWords: clean(food["householdServingFullText"] as? String, limit: sizeLimit),
                                  per100: per100.flatMap { $0 <= mostPer100 ? $0 : nil })
        return .found(ProductInfo(name: name, brand: brand, size: size, source: usdaName, figures: figures,
                                  figuresFrom: figures.isEmpty ? "" : usdaName))
    }

    /// A package size from USDA's free text, in the serving's unit: "10.75 ONZ" (GS1's code for an ounce of weight)
    /// as 304.8 g, "12 oz/340 g" as its own 340 g, "16.9 FL OZ" as ml. A count or a multipack ("6 x 12 FL OZ",
    /// "12 CT") is left out, never guessed, and so is a weight for a serving in ml or a volume for one in g.
    static func packageAmount(_ text: String, unit: String?) -> Amount? {
        let lower = text.lowercased()
        guard let unit, lower.range(of: #"\d\s*(x|ct|count|pk|pack)\b"#, options: .regularExpression) == nil else {
            return nil
        }
        let pattern = #"(\d+(?:\.\d+)?)\s*(fl\.?\s?oz|oza|onz|oz|lbr|lbs|lb|kgm|kg|grm|g|mlt|ml|ltr|l)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        var metric: [Amount] = [], other: [Amount] = []
        for match in expression.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let number = Range(match.range(at: 1), in: lower).flatMap({ Double(lower[$0]) }),
                  let word = Range(match.range(at: 2), in: lower).map({ String(lower[$0]) }) else { continue }
            switch word.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "") {
            case "g", "grm": metric.append(Amount(number, "g"))
            case "kg", "kgm": metric.append(Amount(number * 1000, "g"))
            case "ml", "mlt": metric.append(Amount(number, "ml"))
            case "l", "ltr": metric.append(Amount(number * 1000, "ml"))
            case "oz", "onz": other.append(Amount(number * 28.349523125, "g"))
            case "lb", "lbs", "lbr": other.append(Amount(number * 453.59237, "g"))
            case "floz", "oza": other.append(Amount(number * 29.5735295625, "ml"))
            default: continue
            }
        }
        return (metric + other).first { $0.unit == unit && $0.value > 0 }
    }

    /// USDA's package words for a person: GS1's unit codes as the label's ("10.75 ONZ" as "10.75 oz").
    static func packageWords(_ text: String) -> String {
        var found = clean(text, limit: sizeLimit)
        for (code, word) in [("ONZ", "oz"), ("OZA", "fl oz"), ("LBR", "lb"), ("GRM", "g"), ("KGM", "kg"),
                             ("MLT", "ml"), ("LTR", "l")] {
            found = found.replacingOccurrences(of: #"\b\#(code)\b"#, with: word, options: .regularExpression)
        }
        return found
    }

    /// One food answer from both food services (owner, 2026-10-22, by click: whichever has each figure, USDA first,
    /// its figures from the makers' labels): the name and brand Open Food Facts' when it has them, else USDA's; each
    /// figure USDA's, else Open Food Facts', so a package size from one and a serving from the other still give the
    /// servings. Nil when neither found it.
    public static func merge(usda: ProductInfo?, food: ProductInfo?) -> ProductInfo? {
        guard let named = food ?? usda else { return nil }
        let first = usda?.figures ?? FoodFigures(), second = food?.figures ?? FoodFigures()
        var merged = FoodFigures()
        var from: Set<String> = []
        if let package = first.package {
            (merged.package, merged.packageWords) = (package, first.packageWords)
            from.insert(usdaName)
        } else if let package = second.package {
            (merged.package, merged.packageWords) = (package, second.packageWords)
            from.insert(foodName)
        }
        if let serving = first.serving {
            (merged.serving, merged.servingWords) = (serving, first.servingWords)
            from.insert(usdaName)
        } else if let serving = second.serving {
            (merged.serving, merged.servingWords) = (serving, second.servingWords)
            from.insert(foodName)
        } else {
            merged.servingWords = first.servingWords.isEmpty ? second.servingWords : first.servingWords
        }
        if let per100 = first.per100 {
            merged.per100 = per100
            from.insert(usdaName)
        } else if let per100 = second.per100 {
            merged.per100 = per100
            from.insert(foodName)
        }
        if let each = first.servingCalories {
            merged.perServing = each
            from.insert(usdaName)
        } else if let each = second.servingCalories {
            merged.perServing = each
            from.insert(foodName)
        }
        let size = merged.packageWords.isEmpty ? (food?.size ?? usda?.size ?? "") : merged.packageWords
        return ProductInfo(name: named.name, brand: named.brand.isEmpty ? usda?.brand ?? "" : named.brand,
                           size: size, source: named.source, figures: merged,
                           figuresFrom: [usdaName, foodName].filter(from.contains).joined(separator: " and "))
    }

    // MARK: Calories from a scan (step 8a)

    /// The words a person reads: the item's field, and the offer under it in the form.
    public static let caloriesLabel = "Calories each"
    /// The phone form's box for it (owner, 2026-10-22, by click, on Quick add's card then): the whole package, as the
    /// column holds it.
    public static let wholeLabel = "Calories, whole package"

    /// "About 1,840 calories for the whole package (from Open Food Facts)": "about", since the services' figures are
    /// typed in by volunteers or makers, and where it came from, so the person can change it before saving.
    public static func caloriesOffer(_ calories: Int, source: String) -> String {
        "About \(grouped(calories)) calories for the whole package (from \(source))"
    }

    /// 1840 as "1,840".
    static func grouped(_ number: Int) -> String {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .decimal
        return format.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// 2.4 as "2.4", 12.0 as "12", 1200 as "1,200": a box's number, as it's typed.
    public static func number(_ value: Double) -> String {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .decimal
        format.maximumFractionDigits = 2
        format.usesGroupingSeparator = false
        return format.string(from: NSNumber(value: value)) ?? String(value)
    }

    // The Mac's item form (step 8a; owner, 2026-10-19, by click: the same lookup on the Mac's USB-scanner path): its
    // words while looking and after, and its one button, which keeps what was found in the item's blank cells only.
    public static let lookingUp = "Looking it up…"
    public static let notFoundOnline = "Not found online: type its name."
    public static let notNow = "Couldn't look it up now. Add the code again later to try again, or type its name."
    public static let fillBlanks = "Fill in the blanks"
    public static let fillBlanksHelp = "Puts what was found into this item's blank cells; nothing already typed is "
        + "changed"

    /// The Unit words a whole package's calories fit (step 8a review): a row counted in packages, so Quantity ×
    /// Calories each is packages × the package's calories (readiness/supply.py `food_share`). Blank and "each" too;
    /// the inventory's own Unit choices (inventory/make_grist.py) hold each, cans, packs and boxes. Any other unit
    /// (pounds, ounces, gallons) would make a package's figure read per pound.
    public static let packageUnits: Set<String> = ["", "each", "can", "cans", "bag", "bags", "box", "boxes", "jar", "jars",
                                                   "pack", "packs", "package", "packages", "bottle", "bottles",
                                                   "carton", "cartons", "pouch", "pouches"]

    public static func isPackageUnit(_ unit: String) -> Bool {
        packageUnits.contains(unit.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// A whole package's calories to put in Calories each on a row in `unit`, or nil when they don't fit it.
    public static func caloriesToFill(_ calories: Int?, unit: String) -> Int? {
        isPackageUnit(unit) ? calories : nil
    }

    /// The note in place of the offer when the row's Unit isn't a package's.
    public static func caloriesNotFilled(_ calories: Int, source: String, unit: String) -> String {
        "About \(grouped(calories)) calories for the whole package (from \(source)). Unit is "
            + "\(unit.trimmingCharacters(in: .whitespaces)), so Calories each wasn't filled in."
    }

    /// The kept answers' version: a food answer kept before this one is asked of the food services once more, so its
    /// servings show (step 8a review; owner, 2026-10-22: the serving figures, then USDA).
    public static let answersVersion = 2

    public static func asksAgain(source: String, version: Int) -> Bool {
        isFood(source) && version < answersVersion
    }

    /// "From Open Food Facts: Rolled oats, Made Up Farms".
    public static func found(_ info: ProductInfo) -> String {
        "From \(info.source): " + ([info.name, info.brand].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// A kilocalorie in kilojoules (the thermochemical calorie, 4.184 J, as food labels use it).
    static let kilojoulesPerCalorie = 4.184
    /// More than any one package holds (a 50 lb sack of rice is about 82,000): a figure above is a wrong one (step 8a
    /// review), never offered.
    static let mostPerPackage = 100_000.0
    /// Pure fat is 9 calories a gram: a food listed above 900 a 100 g (or 100 ml) has a wrong figure, never used.
    static let mostPer100 = 900.0
    /// The units the figures are read in ("g" for a solid, "ml" for a drink, whose "per 100 g" figures are per 100
    /// ml): anything else (oz, a count) from Open Food Facts is left out, never guessed.
    static let units: Set<String> = ["g", "ml"]

    // MARK: The serving figures (owner, 2026-10-22, by click: a scan shows what the databases have)

    /// The servings boxes' words, on the phone's and the Mac's item forms.
    public static let perServingLabel = "Calories a serving", servingsLabel = "Servings"
    public static let servingsHint = "Check both against the label: its calories per serving and its servings per "
        + "container."

    /// The serving's words made plain, without the "Amount per serving" some entries start with: "120 ml".
    public static func servingWords(_ text: String?) -> String {
        var found = clean(text, limit: sizeLimit + 20)
        if let lead = found.range(of: "amount per serving", options: [.caseInsensitive, .anchored]) {
            found = found[lead.upperBound...].trimmingCharacters(in: .whitespaces)
            if found.hasPrefix("("), found.hasSuffix(")") { found = String(found.dropFirst().dropLast()) }
        }
        return clean(found, limit: sizeLimit)
    }

    /// What the services have for a food, under its name: "Package: 10.75 oz. Serving: 1/2 cup (120mL) condensed soup,
    /// about 60 calories (from USDA)." Nil for anything but a food.
    public static func figures(_ info: ProductInfo) -> String? {
        guard isFood(info.source) else { return nil }
        let package = info.size.isEmpty ? "No package size listed." : "Package: \(info.size)."
        let calories = info.perServing.map { "about \(grouped($0)) calories" }
        var line: String
        switch (info.serving.isEmpty, calories) {
        case (false, let calories?): line = package + " Serving: \(info.serving), \(calories)"
        case (false, nil): line = package + " Serving: \(info.serving)"
        case (true, let calories?): line = package + " A serving: \(calories)"
        case (true, nil): line = String(package.dropLast())
        }
        return line + (info.figuresFrom.isEmpty ? "." : " (from \(info.figuresFrom)).")
    }

    /// Whether the item form shows the servings boxes: any food (owner, 2026-10-22), filled in with what was found.
    public static func showsServings(_ info: ProductInfo) -> Bool { isFood(info.source) }

    /// Calories each from the two boxes: calories a serving times the servings, both numbers above 0, rounded; nil
    /// when either isn't, or the package would hold more than any one does.
    public static func caloriesFromServings(perServing: String, servings: String) -> Int? {
        guard let each = positive(perServing), let count = positive(servings) else { return nil }
        let found = each * count
        guard found >= 1, found <= mostPerPackage else { return nil }
        return Int(found.rounded())
    }

    /// How Calories each was reached, under its box and in Notes: "About 2.4 servings of 60 calories, from USDA" while
    /// the boxes hold what a service gave (`from`), "2.5 servings of 60 calories" once they hold what was typed.
    public static func servingsNote(perServing: String, servings: String, from: String? = nil) -> String? {
        guard caloriesFromServings(perServing: perServing, servings: servings) != nil,
              let each = positive(perServing), let count = positive(servings) else { return nil }
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US")
        format.numberStyle = .decimal
        format.maximumFractionDigits = 2
        let shown = { (number: Double) in format.string(from: NSNumber(value: number)) ?? String(number) }
        let words = "\(shown(count)) serving\(count == 1 ? "" : "s") of \(shown(each)) calories"
        guard let from, !from.isEmpty else { return words }
        return "About \(words), from \(from)"
    }

    /// The note in place of that when the row's Unit isn't a package's.
    public static func servingsNotFilled(_ calories: Int, unit: String) -> String {
        "\(grouped(calories)) calories for the whole package. Unit is \(unit.trimmingCharacters(in: .whitespaces)), "
            + "so Calories each wasn't filled in."
    }

    /// A figure above 0, written as a number or as a number's text ("400"); never a true/false.
    static func positive(_ value: Any?) -> Double? {
        let found: Double?
        switch value {
        case let number as NSNumber:
            found = CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let text as String:
            found = Double(text.trimmingCharacters(in: .whitespaces))
        default:
            found = nil
        }
        guard let found, found.isFinite, found > 0 else { return nil }
        return found
    }

    /// UPCitemdb's answer: {"code": "OK", "total", "items": [{"title", "brand", "model", "size", …}]}.
    public static func readGoods(_ data: Data) -> Answer {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = top["code"] as? String else { return .unreadable }
        guard code == "OK" else { return code == "INVALID_UPC" ? .notFound : .unreadable }
        guard let item = (top["items"] as? [[String: Any]])?.first else { return .notFound }
        let name = clean(item["title"] as? String, limit: nameLimit)
        guard !name.isEmpty else { return .notFound }
        return .found(ProductInfo(name: name, brand: clean(item["brand"] as? String, limit: brandLimit),
                                  model: clean(item["model"] as? String, limit: brandLimit),
                                  size: clean(item["size"] as? String, limit: sizeLimit), source: goodsName))
    }

    /// Web text made plain: no control characters or markup's entities, runs of spaces made one, cut at a word
    /// within `limit` characters; "" when a character in it was lost at the source.
    public static func clean(_ text: String?, limit: Int) -> String {
        guard var found = text else { return "" }
        for (entity, plain) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"),
                                ("&gt;", ">"), ("&nbsp;", " ")] {
            found = found.replacingOccurrences(of: entity, with: plain)
        }
        found = String(found.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        found = found.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A "?" inside a word is a character the service's data lost ("W?sthof"): left blank for the owner to type
        if found.range(of: #"\p{L}\?\p{L}|\u{FFFD}"#, options: .regularExpression) != nil { return "" }
        guard found.count > limit else { return found }
        let cut = String(found.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space])
        }
        return cut
    }
}

/// Keeps the phone's lookups inside each service's limits (ProductLookup), across launches: at most `perMinute` in any
/// minute for each, and for UPCitemdb at most `goodsPerDay` a day (its day counted in UTC). Answers already had are
/// kept by code, so a code is never asked twice.
public struct LookupPacer: Codable, Equatable, Sendable {
    // the sister sites: Open Food Facts' own 15 a minute, as they run its server (their own pages give none)
    // openFDA: 240 a minute and 1,000 a day without a key (open.fda.gov/apis/authentication); UPC Database's free plan:
    // 100 a day, throttled (upcdatabase.org/api-pricing), kept to UPCitemdb's 6 a minute
    public static let perMinute: [ProductLookup.Service: Int] = [.food: 15, .goods: 6, .usda: 15, .beauty: 15,
                                                                  .products: 15, .fda: 60, .upcdb: 6]
    /// A day's most for the services that set one (UPCitemdb's own count is `goodsToday`).
    public static let perDay: [ProductLookup.Service: Int] = [.fda: 1000, .upcdb: 100]
    /// Raised when a source is added: a code every source said it didn't know is asked again once (2026-10-23: 3).
    public static let sources = 3
    public static let goodsPerDay = 100

    public var recent: [ProductLookup.Service: [Date]] = [:]
    public var goodsDay = ""
    public var goodsToday = 0
    public var notFound: Set<String> = []  // codes every service asked said it doesn't know
    public var askedOf: Int?  // `sources` when `notFound` was last kept; nil in a pacer kept before 2026-10-23
    public var daily: [String: Int]?  // "service day": the requests that day, for `perDay`; nil before 2026-10-23

    /// A source was added since `notFound` was kept: its codes are asked again.
    public mutating func newSources() {
        guard askedOf != Self.sources else { return }
        notFound = []
        askedOf = Self.sources
    }

    public init() {}

    static func day(_ now: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: now)
    }

    /// Whether `service` may be asked now.
    public func may(_ service: ProductLookup.Service, now: Date = Date()) -> Bool {
        let minute = (recent[service] ?? []).filter { now.timeIntervalSince($0) < 60 && $0 <= now }
        guard minute.count < Self.perMinute[service, default: 1] else { return false }
        if service == .goods, goodsDay == Self.day(now), goodsToday >= Self.goodsPerDay { return false }
        if let most = Self.perDay[service], (daily?["\(service.rawValue) \(Self.day(now))"] ?? 0) >= most { return false }
        return true
    }

    /// Count one request to `service`.
    public mutating func asked(_ service: ProductLookup.Service, now: Date = Date()) {
        recent[service] = (recent[service] ?? []).filter { now.timeIntervalSince($0) < 60 && $0 <= now } + [now]
        if service == .goods {
            let today = Self.day(now)
            if goodsDay != today {
                goodsDay = today
                goodsToday = 0
            }
            goodsToday += 1
        }
        if Self.perDay[service] != nil {
            let key = "\(service.rawValue) \(Self.day(now))"
            var counts = (daily ?? [:]).filter { $0.key.hasSuffix(" " + Self.day(now)) }  // only today's are kept
            counts[key, default: 0] += 1
            daily = counts
        }
    }

    /// The services to ask for a code, in order, that may be asked now: the two food services first, UPCitemdb (100 a
    /// day) last.
    public func order(now: Date = Date()) -> [ProductLookup.Service] {
        Self.asked.filter { may($0, now: now) }
    }

    public static let asked: [ProductLookup.Service] = [.usda, .food, .beauty, .products, .fda, .goods, .upcdb]
}
