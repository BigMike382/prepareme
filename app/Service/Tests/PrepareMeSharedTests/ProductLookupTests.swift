import Foundation
@testable import PrepareMeShared
import XCTest

/// Barcode lookup (owner, 2026-10-14): the two services' answers read, in the shapes their APIs gave on 2026-10-14
/// (made-up products here), and the pacer keeping inside their limits.
final class ProductLookupTests: XCTestCase {
    func testTheAddresses() {
        XCTAssertEqual(ProductLookup.url(.food, code: "0012345678905")?.absoluteString,
                       "https://world.openfoodfacts.org/api/v2/product/0012345678905?fields=product_name,brands,quantity,"
                       + "product_quantity,product_quantity_unit,serving_size,serving_quantity,serving_quantity_unit,"
                       + "nutriments")
        XCTAssertEqual(ProductLookup.url(.goods, code: "0012345678905")?.absoluteString,
                       "https://api.upcitemdb.com/prod/trial/lookup?upc=0012345678905")
        XCTAssertEqual(ProductLookup.url(.usda, code: "0012345678905")?.absoluteString,
                       "https://api.nal.usda.gov/fdc/v1/foods/search?query=gtinUpc:00012345678905&dataType=Branded"
                       + "&pageSize=10", "the 14-digit GTIN; the key goes in a header, never the address")
        XCTAssertEqual(ProductLookup.url(.usda, code: "12345670")?.absoluteString.contains("gtinUpc:00000012345670"),
                       true)
        XCTAssertNil(ProductLookup.url(.usda, code: "123456789012345"), "longer than a GTIN")
        XCTAssertNil(ProductLookup.url(.food, code: "12a"), "digits only")
        XCTAssertNil(ProductLookup.url(.goods, code: ""))
        XCTAssertEqual(ProductLookup.url(.beauty, code: "0012345678905")?.absoluteString,
                       "https://world.openbeautyfacts.org/api/v2/product/0012345678905?fields=product_name,brands,quantity")
        XCTAssertEqual(ProductLookup.url(.products, code: "0012345678905")?.host, "world.openproductsfacts.org")
        XCTAssertTrue(ProductLookup.hosts.isSuperset(of: ["world.openbeautyfacts.org", "world.openproductsfacts.org"]))
    }

    /// openFDA for a medicine whose barcode carries its drug code, in its three layouts; any other barcode never asks it.
    /// UPC Database only with a key built in. (owner, 2026-10-23, in chat)
    func testTheFDAsListAndUPCDatabase() {
        let code = "0" + ["3", "8264", "5913", "16", "4"].joined()  // a made-up check digit: the address only
        XCTAssertEqual(ProductLookup.ndcForms(code), ["8264-5913-16", "82645-913-16", "82645-9131-6"])
        XCTAssertNil(ProductLookup.ndcForms("0" + ["0", "1234", "5678", "90", "5"].joined()), "not a 3: no drug code")
        XCTAssertNil(ProductLookup.url(.fda, code: "0" + ["0", "1234", "5678", "90", "5"].joined()))
        XCTAssertEqual(ProductLookup.url(.fda, code: code)?.absoluteString,
                       "https://api.fda.gov/drug/ndc.json?search=packaging.package_ndc:%228264-5913-16%22"
                       + "+packaging.package_ndc:%2282645-913-16%22+packaging.package_ndc:%2282645-9131-6%22&limit=1")
        XCTAssertEqual(ProductLookup.url(.upcdb, code: "0012345678905")?.absoluteString,
                       "https://api.upcdatabase.org/product/0012345678905")
        let drug = #"{"results":[{"brand_name":"Isopropyl Rubbing Alcohol 70 Percent","generic_name":"Isopropyl alcohol","labeler_name":"Made Up Labs, LLC"}]}"#
        XCTAssertEqual(ProductLookup.answer(.fda, status: 200, data: Data(drug.utf8), code: code),
                       .found(ProductInfo(name: "Isopropyl Rubbing Alcohol 70 Percent", brand: "Made Up Labs, LLC",
                                          source: "the FDA's drug list")))
        XCTAssertEqual(ProductLookup.answer(.fda, status: 404, data: Data(), code: code), .notFound)
        let generic = #"{"results":[{"brand_name":"","generic_name":"Isopropyl alcohol"}]}"#
        XCTAssertEqual(ProductLookup.readFDA(Data(generic.utf8)),
                       .found(ProductInfo(name: "Isopropyl alcohol", source: "the FDA's drug list")))
        let item = #"{"success":true,"barcode":"0012345678905","title":"Zorvex 9V batteries","brand":"Zorvex"}"#
        XCTAssertEqual(ProductLookup.readUPCDB(Data(item.utf8)),
                       .found(ProductInfo(name: "Zorvex 9V batteries", brand: "Zorvex", source: "UPC Database")))
        XCTAssertEqual(ProductLookup.readUPCDB(Data(#"{"success":false}"#.utf8)), .notFound)
        XCTAssertEqual(ProductLookup.answer(.upcdb, status: 404, data: Data(), code: "1"), .notFound)
        XCTAssertNil(ProductLookup.upcdbKey(nil))
        XCTAssertNil(ProductLookup.upcdbKey(""), "no key built in: never asked")
        XCTAssertNil(ProductLookup.upcdbKey("$(PREPAREME_UPCDB_KEY)"))
        XCTAssertEqual(ProductLookup.upcdbKey(" abc123 "), "abc123")
    }

    /// The bug at the phase 2 gate (2026-10-23): Open Food Facts answers 404 for a product its sister sites hold, and
    /// that was read as no answer, so the scan said "Couldn't look it up now". 404 is "not here"; only other statuses
    /// are no answer. A sister site's product has no food figures.
    func testA404IsNotHereAndTheSisterSitesAnswer() {
        XCTAssertEqual(ProductLookup.answer(.food, status: 404, data: Data(), code: "1"), .notFound)
        XCTAssertNil(ProductLookup.answer(.goods, status: 429, data: Data(), code: "1"), "a limit: asked again later")
        XCTAssertNil(ProductLookup.answer(.food, status: 503, data: Data(), code: "1"))
        let found = #"{"code":"0012345678905","product":{"brands":"Zorvex","product_name":"70% isopropyl alcohol","quantity":"16 fl oz"},"status":1}"#
        XCTAssertEqual(ProductLookup.answer(.beauty, status: 200, data: Data(found.utf8), code: "1"),
                       .found(ProductInfo(name: "70% isopropyl alcohol", brand: "Zorvex", size: "16 fl oz",
                                          source: "Open Beauty Facts")))
        guard case .found(let info) = ProductLookup.answer(.products, status: 200, data: Data(found.utf8), code: "1")
        else { return XCTFail("found") }
        XCTAssertEqual(info.source, "Open Products Facts")
        XCTAssertFalse(ProductLookup.isFood(info.source), "no servings boxes for it")
        XCTAssertEqual(ProductLookup.answer(.beauty, status: 200, data: Data(#"{"status":0}"#.utf8), code: "1"),
                       .notFound)
    }

    func testTheFoodSitesAnswer() {
        let found = #"{"code":"0012345678905","product":{"brands":"Made Up Farms, Other Co","product_name":"Rolled oats","quantity":"1.13 kg"},"status":1,"status_verbose":"product found"}"#
        XCTAssertEqual(ProductLookup.readFood(Data(found.utf8)),
                       .found(ProductInfo(name: "Rolled oats", brand: "Made Up Farms", size: "1.13 kg",
                                          source: "Open Food Facts", figures: FoodFigures(packageWords: "1.13 kg"))))
        let none = #"{"code":"00000000","status":0,"status_verbose":"no code or invalid code"}"#
        XCTAssertEqual(ProductLookup.readFood(Data(none.utf8)), .notFound)
        let nameless = #"{"code":"1","product":{"product_name":""},"status":1}"#
        XCTAssertEqual(ProductLookup.readFood(Data(nameless.utf8)), .notFound)
        XCTAssertEqual(ProductLookup.readFood(Data("<html>".utf8)), .unreadable)
    }

    // MARK: Calories from a scan (step 8a, owner 2026-10-19, by click: days of food filled in by scanning)

    /// A made-up product in Open Food Facts' shape (its API, read 2026-10-19): the package's net quantity, a serving,
    /// and the energy figures in `nutriments`.
    func food(_ fields: String) -> Data {
        Data((#"{"code":"0012345678905","status":1,"product":{"product_name":"Made up beans""#
              + (fields.isEmpty ? "" : "," + fields) + "}}").utf8)
    }

    func calories(_ fields: String) -> Int? {
        guard case .found(let info) = ProductLookup.readFood(food(fields)) else { return -1 }
        return info.calories
    }

    func testCaloriesPer100GramsTimesTheNetQuantity() {
        XCTAssertEqual(calories(#""product_quantity":400,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":460}"#),
                       1840)
        XCTAssertEqual(calories(#""product_quantity":"400","product_quantity_unit":"g","nutriments":{"energy-kcal_100g":"460"}"#),
                       1840, "a number written as text reads the same")
        XCTAssertEqual(calories(#""product_quantity":1000,"product_quantity_unit":"ml","nutriments":{"energy-kcal_100g":45}"#),
                       450, "a drink: per 100 ml with millilitres")
    }

    func testCaloriesPerServingTimesTheServingsInThePackage() {
        XCTAssertEqual(calories(#""product_quantity":480,"product_quantity_unit":"g","serving_quantity":40,"serving_quantity_unit":"g","nutriments":{"energy-kcal_serving":150}"#),
                       1800, "12 servings of 150")
        XCTAssertNil(calories(#""product_quantity":480,"product_quantity_unit":"g","serving_quantity":250,"serving_quantity_unit":"ml","nutriments":{"energy-kcal_serving":150}"#),
                     "a serving in another unit than the package: never guessed")
        XCTAssertEqual(calories(#""product_quantity":480,"product_quantity_unit":"g","serving_quantity":40,"serving_quantity_unit":"g","nutriments":{"energy-kcal_100g":375,"energy-kcal_serving":999}"#),
                       1800, "per 100 g wins over a serving's figure")
    }

    func testKilojoulesAreTurnedIntoCalories() {
        XCTAssertEqual(calories(#""product_quantity":500,"product_quantity_unit":"g","nutriments":{"energy-kj_100g":1925}"#),
                       2300, "1925 kJ is 460.1 kcal; 5 of them")
        XCTAssertEqual(calories(#""product_quantity":480,"product_quantity_unit":"g","serving_quantity":40,"serving_quantity_unit":"g","nutriments":{"energy-kj_serving":627.6}"#),
                       1800)
        XCTAssertEqual(calories(#""product_quantity":400,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":460,"energy-kj_100g":9999}"#),
                       1840, "the label's kcal first")
    }

    func testAFigureThatCantBeWorkedOutIsLeftBlank() {
        XCTAssertNil(calories(#""product_quantity":400,"product_quantity_unit":"g""#), "no energy")
        XCTAssertNil(calories(#""nutriments":{"energy-kcal_100g":460}"#), "no net quantity")
        XCTAssertNil(calories(#""product_quantity":14,"product_quantity_unit":"oz","nutriments":{"energy-kcal_100g":460}"#),
                     "a unit it doesn't read")
        XCTAssertNil(calories(#""product_quantity":400,"nutriments":{"energy-kcal_100g":460}"#), "no unit")
        XCTAssertNil(calories(#""product_quantity":400,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":2400}"#),
                     "over 900 per 100 g (pure fat's) is a wrong figure")
        XCTAssertNil(calories(#""product_quantity":400,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":-5}"#))
        XCTAssertNil(calories(#""product_quantity":0,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":460}"#))
        XCTAssertNil(calories(#""product_quantity":"about 400","product_quantity_unit":"g","nutriments":{"energy-kcal_100g":460}"#))
        XCTAssertNil(calories(#""product_quantity":400,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":true}"#))
        XCTAssertNil(calories(#""product_quantity":480,"product_quantity_unit":"g","nutriments":{"energy-kcal_serving":150}"#),
                     "a serving's figure with no serving size")
        XCTAssertNil(calories(#""product_quantity":400,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":0}"#),
                     "0 is no figure: a blank Calories each says so")
        XCTAssertEqual(calories(""), nil)
    }

    func testTheOfferSaysAboutAndWhereItCameFrom() {
        XCTAssertEqual(ProductLookup.caloriesOffer(1840, source: ProductLookup.foodName),
                       "About 1,840 calories for the whole package (from Open Food Facts)")
        XCTAssertEqual(ProductLookup.caloriesOffer(450, source: ProductLookup.usdaName),
                       "About 450 calories for the whole package (from USDA)")
        XCTAssertEqual(ProductLookup.caloriesLabel, "Calories each")
        XCTAssertEqual(ProductLookup.wholeLabel, "Calories, whole package")
    }

    /// The Mac's item form (step 8a; owner, 2026-10-19, by click): a code scanned with a USB scanner, or typed, is
    /// looked up as on the phone, and what was found is offered, kept only with Fill in the blanks.
    func testTheMacsOfferWords() {
        XCTAssertEqual(ProductLookup.lookingUp, "Looking it up…")
        XCTAssertEqual(ProductLookup.found(ProductInfo(name: "Rolled oats", brand: "Made Up Farms", source: "Open Food Facts")),
                       "From Open Food Facts: Rolled oats, Made Up Farms")
        XCTAssertEqual(ProductLookup.found(ProductInfo(name: "Lantern", source: "UPCitemdb")), "From UPCitemdb: Lantern")
        XCTAssertEqual(ProductLookup.notFoundOnline, "Not found online: type its name.")
        XCTAssertEqual(ProductLookup.notNow, "Couldn't look it up now. Add the code again later to try again, or type "
                       + "its name.")
        XCTAssertEqual(ProductLookup.fillBlanks, "Fill in the blanks")
        XCTAssertEqual(ProductLookup.fillBlanksHelp, "Puts what was found into this item's blank cells; nothing "
                       + "already typed is changed")
    }

    /// Step 8a review: a whole package's calories go into Calories each only when the row counts packages (Unit
    /// blank, each, or a package word), since the lists count Quantity × Calories each; a 400 g bag's 1,840 kept on a
    /// row in pounds would overstate days of food. Otherwise the figure is only a note, and the cell stays blank.
    func testCaloriesGoInOnlyForAPackageUnit() {
        for unit in ["", " ", "each", "Each", "can", "cans", " Cans ", "bag", "bags", "box", "boxes", "jar", "jars",
                     "pack", "packs", "package", "packages", "bottle", "bottles", "carton", "cartons", "pouch",
                     "pouches"] {
            XCTAssertTrue(ProductLookup.isPackageUnit(unit), unit)
            XCTAssertEqual(ProductLookup.caloriesToFill(1840, unit: unit), 1840, unit)
        }
        for unit in ["pounds", "lb", "ounces", "oz", "gallons", "liters", "rolls", "feet", "calories", "g"] {
            XCTAssertFalse(ProductLookup.isPackageUnit(unit), unit)
            XCTAssertNil(ProductLookup.caloriesToFill(1840, unit: unit), unit)
        }
        XCTAssertNil(ProductLookup.caloriesToFill(nil, unit: "each"))
        XCTAssertEqual(ProductLookup.caloriesNotFilled(1840, source: ProductLookup.foodName, unit: "pounds"),
                       "About 1,840 calories for the whole package (from Open Food Facts). Unit is pounds, so "
                       + "Calories each wasn't filled in.")
    }

    func testAPackageOver100000CaloriesIsAWrongFigure() {
        XCTAssertEqual(calories(#""product_quantity":25000,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":400}"#),
                       100_000)
        XCTAssertNil(calories(#""product_quantity":25001,"product_quantity_unit":"g","nutriments":{"energy-kcal_100g":400}"#))
    }

    /// A food answer kept with no whole package's calories, before the serving figures were read (owner, 2026-10-22),
    /// is asked of Open Food Facts once more, so its serving figures show.
    func testAFoodAnswerKeptBeforeTheServingFiguresIsAskedAgainOnce() {
        XCTAssertTrue(ProductLookup.asksAgain(source: ProductLookup.foodName, version: 0))
        XCTAssertTrue(ProductLookup.asksAgain(source: ProductLookup.foodName, version: 1))
        XCTAssertTrue(ProductLookup.asksAgain(source: ProductLookup.usdaName, version: 1))
        XCTAssertFalse(ProductLookup.asksAgain(source: ProductLookup.foodName, version: ProductLookup.answersVersion))
        XCTAssertFalse(ProductLookup.asksAgain(source: ProductLookup.goodsName, version: 0))
    }

    // MARK: The serving figures (owner, 2026-10-22, by click: a scan shows what the database has)

    func info(_ fields: String) -> ProductInfo? {
        guard case .found(let info) = ProductLookup.readFood(food(fields)) else { return nil }
        return info
    }

    /// The shape Open Food Facts gave on 2026-10-22 for a US can of soup with no package size: a serving and its
    /// calories, nothing to work out the whole can from.
    func testAServingsFiguresAreReadWhenThePackagesSizeIsMissing() throws {
        let soup = try XCTUnwrap(info(#""serving_size":"Amount per Serving (120 ml)","serving_quantity":120,"serving_quantity_unit":"ml","nutriments":{"energy-kcal_100g":20.3,"energy-kcal_serving":24.4}"#))
        XCTAssertNil(soup.calories, "no package size: the whole can is never guessed")
        XCTAssertEqual(soup.serving, "120 ml")
        XCTAssertEqual(soup.perServing, 24)
        XCTAssertEqual(ProductLookup.figures(soup),
                       "No package size listed. Serving: 120 ml, about 24 calories (from Open Food Facts).")
        XCTAssertTrue(ProductLookup.showsServings(soup))
    }

    func testAServingsFiguresWithAPackagesSize() throws {
        let can = try XCTUnwrap(info(#""quantity":"10.5 oz (298 g)","product_quantity":297.67,"product_quantity_unit":"g","serving_size":"120.0g","serving_quantity":120,"serving_quantity_unit":"g","nutriments":{"energy-kcal_100g":83.33,"energy-kcal_serving":100}"#))
        XCTAssertEqual(can.servings, 2.5, "297.67 ÷ 120, to a tenth")
        XCTAssertEqual(can.calories, 250, "100 a serving × 2.5, as the boxes multiply them")
        XCTAssertEqual(can.serving, "120.0g")
        XCTAssertEqual(can.perServing, 100)
        XCTAssertEqual(ProductLookup.figures(can),
                       "Package: 10.5 oz (298 g). Serving: 120.0g, about 100 calories (from Open Food Facts).")
        XCTAssertTrue(ProductLookup.showsServings(can), "the boxes, filled in")
    }

    func testAServingsCaloriesFromKilojoulesOrNotAtAll() throws {
        XCTAssertEqual(info(#""nutriments":{"energy-kj_serving":627.6}"#)?.perServing, 150)
        XCTAssertNil(info(#""serving_quantity":40,"serving_quantity_unit":"g","nutriments":{"energy-kcal_serving":999}"#)?.perServing,
                     "over pure fat's 9 a gram: a wrong figure")
        XCTAssertNil(info(#""nutriments":{"energy-kcal_serving":0}"#)?.perServing)
        XCTAssertNil(info(#""nutriments":{"energy-kcal_serving":true}"#)?.perServing)
        let bare = try XCTUnwrap(info(""))
        XCTAssertEqual(bare.serving, "")
        XCTAssertNil(bare.perServing)
        XCTAssertEqual(ProductLookup.figures(bare), "No package size listed.")
        XCTAssertTrue(ProductLookup.showsServings(bare), "the boxes are there to type both from the label")
        XCTAssertNil(ProductLookup.figures(ProductInfo(name: "Lantern", size: "12 oz", source: ProductLookup.goodsName)),
                     "only a food's figures")
        XCTAssertFalse(ProductLookup.showsServings(ProductInfo(name: "Lantern", source: ProductLookup.goodsName)))
        XCTAssertEqual(ProductLookup.servingWords("1/2 cup dry (40 g)"), "1/2 cup dry (40 g)")
        XCTAssertEqual(ProductLookup.servingWords("amount per serving"), "")
    }

    /// The two boxes: calories a serving times the servings, both from the label, into Calories each.
    func testCaloriesEachFromTheServingsBoxes() {
        XCTAssertEqual(ProductLookup.caloriesFromServings(perServing: "60", servings: "2.5"), 150)
        XCTAssertEqual(ProductLookup.caloriesFromServings(perServing: " 140 ", servings: "13"), 1820)
        XCTAssertEqual(ProductLookup.caloriesFromServings(perServing: "190", servings: "1"), 190)
        XCTAssertNil(ProductLookup.caloriesFromServings(perServing: "60", servings: ""))
        XCTAssertNil(ProductLookup.caloriesFromServings(perServing: "", servings: "2.5"))
        XCTAssertNil(ProductLookup.caloriesFromServings(perServing: "60", servings: "about 2"))
        XCTAssertNil(ProductLookup.caloriesFromServings(perServing: "60", servings: "0"))
        XCTAssertNil(ProductLookup.caloriesFromServings(perServing: "1000", servings: "101"), "over 100,000")
        XCTAssertEqual(ProductLookup.servingsNote(perServing: "60", servings: "2.5"), "2.5 servings of 60 calories")
        XCTAssertEqual(ProductLookup.servingsNote(perServing: "1200", servings: "1"), "1 serving of 1,200 calories")
        XCTAssertEqual(ProductLookup.servingsNote(perServing: "60", servings: "3.0"), "3 servings of 60 calories")
        XCTAssertNil(ProductLookup.servingsNote(perServing: "60", servings: "x"))
        XCTAssertEqual(ProductLookup.servingsNote(perServing: "60", servings: "2.4", from: "USDA"),
                       "About 2.4 servings of 60 calories, from USDA")
        XCTAssertEqual(ProductLookup.servingsNote(perServing: "60", servings: "2.4", from: ""),
                       "2.4 servings of 60 calories")
        XCTAssertEqual(ProductLookup.number(2.4), "2.4")
        XCTAssertEqual(ProductLookup.number(12), "12")
        XCTAssertEqual(ProductLookup.number(1200), "1200")
        XCTAssertEqual(ProductLookup.servingsNotFilled(150, unit: "pounds"),
                       "150 calories for the whole package. Unit is pounds, so Calories each wasn't filled in.")
        XCTAssertEqual(ProductLookup.perServingLabel, "Calories a serving")
        XCTAssertEqual(ProductLookup.servingsLabel, "Servings")
        XCTAssertEqual(ProductLookup.servingsHint, "Check both against the label: its calories per serving and its "
                       + "servings per container.")
    }

    // MARK: USDA FoodData Central (owner, 2026-10-22, by click)

    /// A made-up branded food in USDA's search shape (read 2026-10-22), as the soup was: a 10.75 oz can, a 126 g
    /// serving, 48 kcal a 100 g.
    func usda(_ food: String, gtin: String = "00012345678905") -> Data {
        Data((#"{"totalHits":1,"foods":[{"gtinUpc":""# + gtin + #"","description":"Made up chicken soup, 10.75 oz Can","brandName":"MADE UP","brandOwner":"Made Up Co.","publishedDate":"2026-07-23""#
              + (food.isEmpty ? "" : "," + food) + "}]}").utf8)
    }

    func testUSDAsAnswer() throws {
        let soup = #""servingSize":126.0,"servingSizeUnit":"GRM","householdServingFullText":"1/2 cup (120mL) condensed soup","packageWeight":"10.75 ONZ","foodNutrients":[{"nutrientNumber":"203","value":2.4},{"nutrientNumber":"208","nutrientName":"Energy","unitName":"KCAL","value":48}]"#
        guard case .found(let info) = ProductLookup.readUSDA(usda(soup), code: "0012345678905") else {
            return XCTFail("found")
        }
        XCTAssertEqual(info.name, "Made up chicken soup, 10.75 oz Can")
        XCTAssertEqual(info.brand, "MADE UP")
        XCTAssertEqual(info.source, "USDA")
        XCTAssertEqual(info.size, "10.75 oz")
        XCTAssertEqual(info.serving, "1/2 cup (120mL) condensed soup")
        XCTAssertEqual(info.perServing, 60, "48 a 100 g × 126 g")
        XCTAssertEqual(info.servings, 2.4, "304.8 g ÷ 126 g")
        XCTAssertEqual(info.calories, 144, "60 × 2.4")
        XCTAssertEqual(ProductLookup.figures(info),
                       "Package: 10.75 oz. Serving: 1/2 cup (120mL) condensed soup, about 60 calories (from USDA).")
        XCTAssertEqual(ProductLookup.readUSDA(usda(soup, gtin: "00099999999999"), code: "0012345678905"), .notFound,
                       "a search can find another food: only the code's own counts")
        XCTAssertEqual(ProductLookup.readUSDA(Data(#"{"totalHits":0,"foods":[]}"#.utf8), code: "1"), .notFound)
        XCTAssertEqual(ProductLookup.readUSDA(Data(#"{"error":{"code":"OVER_RATE_LIMIT"}}"#.utf8), code: "1"),
                       .unreadable, "a limit reached: asked again later")
        guard case .found(let kj) = ProductLookup.readUSDA(usda(#""servingSize":40,"servingSizeUnit":"g","foodNutrients":[{"nutrientNumber":"268","value":1569}]"#), code: "12345678905") else {
            return XCTFail("found")
        }
        XCTAssertEqual(kj.perServing, 150, "kJ ÷ 4.184; the code without its leading zeros is the same GTIN")
        XCTAssertNil(kj.servings, "no package size")
    }

    func testUSDAsPackageWords() {
        XCTAssertEqual(ProductLookup.packageAmount("10.75 ONZ", unit: "g")?.value ?? 0, 304.757, accuracy: 0.001)
        XCTAssertEqual(ProductLookup.packageAmount("12 oz/340 g", unit: "g"), Amount(340, "g"), "the label's own grams")
        XCTAssertEqual(ProductLookup.packageAmount("2.87 oz/81 g", unit: "g"), Amount(81, "g"))
        XCTAssertEqual(ProductLookup.packageAmount("1 LBR", unit: "g"), Amount(453.59237, "g"))
        XCTAssertEqual(ProductLookup.packageAmount("1.5 kg", unit: "g"), Amount(1500, "g"))
        XCTAssertEqual(ProductLookup.packageAmount("16.9 FL OZ", unit: "ml")?.value ?? 0, 499.79, accuracy: 0.01)
        XCTAssertEqual(ProductLookup.packageAmount("1 L", unit: "ml"), Amount(1000, "ml"))
        XCTAssertNil(ProductLookup.packageAmount("16.9 FL OZ", unit: "g"), "a volume for a serving in grams")
        XCTAssertNil(ProductLookup.packageAmount("10.75 ONZ", unit: "ml"), "a weight for a serving in ml")
        XCTAssertNil(ProductLookup.packageAmount("6 x 12 FL OZ", unit: "ml"), "a multipack: never guessed")
        XCTAssertNil(ProductLookup.packageAmount("12 CT", unit: "g"))
        XCTAssertNil(ProductLookup.packageAmount("", unit: "g"))
        XCTAssertNil(ProductLookup.packageAmount("10.75 ONZ", unit: nil))
        XCTAssertEqual(ProductLookup.packageWords("10.75 ONZ"), "10.75 oz")
        XCTAssertEqual(ProductLookup.packageWords("12 oz/340 g"), "12 oz/340 g")
    }

    /// The soup as it was on 2026-10-22: Open Food Facts with no package size and a wrong 24 a serving, USDA with the
    /// label's. USDA's figures win; the name stays Open Food Facts'.
    func testBothFoodServicesMerged() throws {
        let food = ProductInfo(name: "Made up chicken noodle soup", brand: "Made Up Kitchens", source: "Open Food Facts",
                               figures: FoodFigures(serving: Amount(120, "ml"), servingWords: "120 ml", per100: 20.3,
                                                    perServing: 24.4), figuresFrom: "Open Food Facts")
        let usda = ProductInfo(name: "Made up chicken soup, 10.75 oz Can", brand: "MADE UP", size: "10.75 oz",
                               source: "USDA",
                               figures: FoodFigures(package: Amount(304.757, "g"), packageWords: "10.75 oz",
                                                    serving: Amount(126, "g"), servingWords: "1/2 cup", per100: 48),
                               figuresFrom: "USDA")
        let both = try XCTUnwrap(ProductLookup.merge(usda: usda, food: food))
        XCTAssertEqual(both.name, "Made up chicken noodle soup")
        XCTAssertEqual(both.brand, "Made Up Kitchens")
        XCTAssertEqual(both.source, "Open Food Facts")
        XCTAssertEqual(both.size, "10.75 oz")
        XCTAssertEqual(both.perServing, 60, "USDA's, not Open Food Facts' 24")
        XCTAssertEqual(both.servings, 2.4)
        XCTAssertEqual(both.calories, 144)
        XCTAssertEqual(both.figuresFrom, "USDA")
        XCTAssertEqual(ProductLookup.merge(usda: nil, food: food), food, "one service alone: its own figures")
        XCTAssertEqual(ProductLookup.merge(usda: usda, food: nil)?.source, "USDA")
        XCTAssertNil(ProductLookup.merge(usda: nil, food: nil))
        // a package size from one and a serving from the other still give the servings
        let sized = ProductInfo(name: "Made up oats", size: "400 g", source: "Open Food Facts",
                                figures: FoodFigures(package: Amount(400, "g"), packageWords: "400 g"),
                                figuresFrom: "Open Food Facts")
        let served = ProductInfo(name: "MADE UP OATS", source: "USDA",
                                 figures: FoodFigures(serving: Amount(40, "g"), servingWords: "1/2 cup", per100: 375),
                                 figuresFrom: "USDA")
        let oats = try XCTUnwrap(ProductLookup.merge(usda: served, food: sized))
        XCTAssertEqual(oats.servings, 10)
        XCTAssertEqual(oats.perServing, 150)
        XCTAssertEqual(oats.calories, 1500)
        XCTAssertEqual(oats.figuresFrom, "USDA and Open Food Facts")
        XCTAssertEqual(oats.name, "Made up oats")
    }

    func testTheKeySentToUSDA() {
        XCTAssertEqual(ProductLookup.usdaKey(nil), "DEMO_KEY")
        XCTAssertEqual(ProductLookup.usdaKey(""), "DEMO_KEY")
        XCTAssertEqual(ProductLookup.usdaKey("$(PREPAREME_USDA_KEY)"), "DEMO_KEY", "a build that never set it")
        XCTAssertEqual(ProductLookup.usdaKey(" madeUpKey123 \n"), "madeUpKey123")
        XCTAssertEqual(ProductLookup.usdaKey("made up key"), "DEMO_KEY", "not a key's shape")
        XCTAssertEqual(ProductLookup.keyEntry, "PrepareMeUSDAKey")
    }

    func testTheGoodsSitesAnswer() {
        let found = #"{"code":"OK","total":1,"offset":0,"items":[{"ean":"0012345678905","title":"Made Up 2-Pack LED Lantern &amp; Radio","brand":"Zorvex","model":"ZX-2","size":"","category":"Lighting"}]}"#
        XCTAssertEqual(ProductLookup.readGoods(Data(found.utf8)),
                       .found(ProductInfo(name: "Made Up 2-Pack LED Lantern & Radio", brand: "Zorvex", model: "ZX-2",
                                          source: "UPCitemdb")))
        XCTAssertEqual(ProductLookup.readGoods(Data(#"{"code":"OK","total":0,"offset":0,"items":[]}"#.utf8)), .notFound)
        XCTAssertEqual(ProductLookup.readGoods(Data(#"{"code":"INVALID_UPC","message":"x"}"#.utf8)), .notFound)
        XCTAssertEqual(ProductLookup.readGoods(Data(#"{"code":"TOO_FAST"}"#.utf8)), .unreadable, "asked again later")
    }

    func testWebTextIsMadePlainAndShort() {
        XCTAssertEqual(ProductLookup.clean("  Water\n\tjugs\u{0007}  ", limit: 80), "Water jugs")
        let long = String(repeating: "word ", count: 40)
        let cut = ProductLookup.clean(long, limit: 80)
        XCTAssertLessThanOrEqual(cut.count, 80)
        XCTAssertFalse(cut.hasSuffix(" "))
        XCTAssertEqual(ProductLookup.clean(nil, limit: 10), "")
        XCTAssertEqual(ProductLookup.clean("W?sthof", limit: 40), "", "a lost character: typed by the owner")
        XCTAssertEqual(ProductLookup.clean("Caf\u{FFFD} beans", limit: 40), "")
        XCTAssertEqual(ProductLookup.clean("Is it waterproof? Yes", limit: 40), "Is it waterproof? Yes")
    }

    func testThePacerKeepsInsideEachLimit() throws {
        var pacer = LookupPacer()
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-14T23:59:00Z"))
        for n in 0..<6 { pacer.asked(.goods, now: start.addingTimeInterval(Double(n))) }
        XCTAssertFalse(pacer.may(.goods, now: start.addingTimeInterval(10)), "6 a minute")
        XCTAssertTrue(pacer.may(.goods, now: start.addingTimeInterval(61)))
        XCTAssertEqual(pacer.order(now: start.addingTimeInterval(10)), [.usda, .food, .beauty, .products, .fda, .upcdb])
        for n in 0..<15 { pacer.asked(.usda, now: start.addingTimeInterval(Double(n))) }
        XCTAssertEqual(pacer.order(now: start.addingTimeInterval(20)), [.food, .beauty, .products, .fda, .upcdb],
                       "USDA: 15 a minute")
        var upcdb = LookupPacer()
        for n in 0..<100 { upcdb.asked(.upcdb, now: start.addingTimeInterval(-86_000 + Double(n) * 61)) }
        XCTAssertFalse(upcdb.may(.upcdb, now: start), "UPC Database: 100 a day")
        XCTAssertTrue(upcdb.may(.upcdb, now: start.addingTimeInterval(120)), "a new day (UTC)")
        upcdb.asked(.upcdb, now: start.addingTimeInterval(120))
        XCTAssertEqual(upcdb.daily, ["upcdb 2026-10-15": 1], "only today's count is kept")
        var day = LookupPacer()
        for n in 0..<100 { day.asked(.goods, now: start.addingTimeInterval(-86_000 + Double(n) * 61)) }
        XCTAssertEqual(day.goodsDay, "2026-10-14")
        XCTAssertFalse(day.may(.goods, now: start), "100 a day")
        XCTAssertTrue(day.may(.goods, now: start.addingTimeInterval(120)), "a new day (UTC)")
        let saved = try JSONDecoder().decode(LookupPacer.self, from: JSONEncoder().encode(day))
        XCTAssertEqual(saved, day, "kept across launches")
        // a pacer kept before the sister sites: its "nobody knows it" codes are asked again, once
        var old = try JSONDecoder().decode(LookupPacer.self, from: Data(#"{"notFound":["1"],"goodsDay":"","goodsToday":0,"recent":[]}"#.utf8))
        old.newSources()
        XCTAssertEqual(old.notFound, [])
        old.notFound.insert("2")
        old.newSources()
        XCTAssertEqual(old.notFound, ["2"], "only once")
    }
}
