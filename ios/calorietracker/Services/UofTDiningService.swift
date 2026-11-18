import Foundation

/// University of Toronto Food Services menus (fso.ueat.utoronto.ca).
///
/// The public "Menu Nutritional Information" site has no JSON API, but its page is
/// driven by three stateless HTML endpoints (no login, no cookies):
///
/// 1. `GET  /FSO/ServiceMenuReport/GetDate?dt=YYYYMMDD` — full page whose location tree
///    lists every dining hall / cafeteria and its meals or stations, each with a menu GUID.
///    Menu GUIDs are different for every date.
/// 2. `POST /FSO/ServiceMenuReport/GetReport/{menuID}` — an HTML table of every item on
///    that menu, grouped by station ("Deli Bar", "Grill"...), with serving size and
///    12 nutrient columns.
/// 3. `POST /FSO/ServiceMenuReport/GetLabel/{menuID}/{lineID}` — one item's nutrition
///    label, including ingredients, allergens, "may contain" and tags (Halal/Vegan/Vegetarian).
///
/// The POSTs take a form body `allergens=&tags=&maycontain=` (the site's own filters).
enum UofTDiningService {
    static let dataSourceID = "uoftFoodServices"
    static let baseURL = URL(string: "https://fso.ueat.utoronto.ca/FSO/ServiceMenuReport/")!
    /// Menus are published for today plus the next six days.
    static let daysAvailable = 7

    // MARK: - Models

    struct Location: Identifiable, Hashable, Sendable {
        /// Stable across days (the display name); menu IDs are not.
        var id: String { name }
        var name: String
        var menus: [MenuRef]

        /// True for residence dining halls (Breakfast / Lunch / Dinner), false for
        /// cafeterias whose sub-menus are food stations.
        var isDiningHall: Bool {
            !menus.isEmpty && menus.allSatisfy { MealPeriod(menuName: $0.name) != nil }
        }
    }

    struct MenuRef: Identifiable, Hashable, Sendable {
        var id: String
        var name: String

        var mealType: MealType? { MealPeriod(menuName: name)?.mealType }
    }

    struct Station: Identifiable, Hashable, Sendable {
        var id: String { name }
        var name: String
        var items: [MenuItem]
    }

    struct MenuItem: Identifiable, Hashable, Sendable {
        var id: String { lineID }
        var menuID: String
        var lineID: String
        var name: String
        var station: String
        /// As printed by the site: "100g", "Portion", "Each", "Slice" or empty.
        var servingText: String
        var nutrients: Nutrients

        /// Grams when the serving size is a weight ("100g", "250 g"); nil for "Portion" etc.
        var servingGrams: Double? { UofTDiningService.grams(fromServing: servingText) }
    }

    /// Values for one serving as listed on the menu table.
    struct Nutrients: Hashable, Sendable {
        var calories: Double?
        var fat: Double?
        var saturatedFat: Double?
        var cholesterol: Double?   // mg
        var sodium: Double?        // mg
        var carbs: Double?
        var fiber: Double?
        var sugar: Double?
        var protein: Double?
        var vitaminC: Double?      // mg
        var calcium: Double?       // mg
        var iron: Double?          // mg
    }

    /// Extra detail from the item's nutrition label popup.
    struct ItemDetails: Hashable, Sendable {
        var ingredients: String?
        var allergens: [String]
        var mayContain: [String]
        var tags: [String]
        var transFat: Double?
    }

    enum ServiceError: LocalizedError {
        case invalidResponse
        case serviceUnavailable
        case noMenus
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                String(localized: "U of T Food Services returned a page the app couldn't read.", comment: "Dining menu error")
            case .serviceUnavailable:
                String(localized: "U of T Food Services is unavailable right now. Try again later.", comment: "Dining menu error")
            case .noMenus:
                String(localized: "No menus are posted for this day yet.", comment: "Dining menu error")
            case .networkError:
                String(localized: "Couldn't load the dining menu. Check your connection and try again.", comment: "Dining menu error")
            }
        }
    }

    // MARK: - Network

    /// Every location and its menus for `date` (interpreted in Toronto time).
    static func locations(on date: Date = .now, session: URLSession = .shared) async throws -> [Location] {
        var components = URLComponents(url: baseURL.appendingPathComponent("GetDate"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "dt", value: dateParameter(for: date))]
        let request = URLRequest(url: components.url!)
        let html = try await fetchHTML(request, session: session)
        let locations = parseLocations(html)
        guard !locations.isEmpty else { throw ServiceError.noMenus }
        return locations
    }

    /// Every item on one menu, grouped by station in the site's order.
    static func stations(menuID: String, session: URLSession = .shared) async throws -> [Station] {
        let html = try await fetchHTML(postRequest(path: "GetReport/\(menuID)"), session: session)
        return parseStations(html, menuID: menuID)
    }

    /// Ingredients, allergens and tags for one item.
    static func details(for item: MenuItem, session: URLSession = .shared) async throws -> ItemDetails {
        let html = try await fetchHTML(postRequest(path: "GetLabel/\(item.menuID)/\(item.lineID)"), session: session)
        return parseDetails(html)
    }

    private static func postRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("allergens=&tags=&maycontain=".utf8)
        return request
    }

    private static func fetchHTML(_ request: URLRequest, session: URLSession) async throws -> String {
        var request = request
        request.timeoutInterval = 20
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 500..<600: throw ServiceError.serviceUnavailable
        default: throw ServiceError.invalidResponse
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ServiceError.invalidResponse
        }
        return html
    }

    static func dateParameter(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Reads the left-hand location tree (`<ul id="navUnits">`). The server sends it without
    /// element IDs (the page's script adds those), so groups are read by structure: each
    /// `<li class="dxnb-gr">` is a location whose `<li class="dxnb-item">` entries are its menus.
    /// Menu GUIDs come from the control's client state, in the same order.
    static func parseLocations(_ html: String) -> [Location] {
        guard let navStart = html.range(of: #"id="navUnits""#) else { return [] }
        let navEnd = html.range(of: "createControl(MVCxClientNavBar", range: navStart.upperBound..<html.endIndex)?.lowerBound
            ?? html.endIndex
        let markup = String(html[navStart.upperBound..<navEnd])
        let guidGroups = navUnitGUIDGroups(html)

        let groups = markup.components(separatedBy: #"<li class="dxnb-gr"#).dropFirst()
        return groups.enumerated().compactMap { index, group -> Location? in
            guard index < guidGroups.count,
                  let header = firstMatch(#"class="dxnb-ghtext"[^>]*>([^<]*)<"#, in: group)
            else { return nil }
            let names = matches(#"<li class="dxnb-item[^"]*"[^>]*>[\s\S]*?<span[^>]*>([^<]*)</span>"#, in: group)
                .map { decodeEntities($0[1]) }
            let guids = guidGroups[index]
            let menus = zip(guids, names).map { MenuRef(id: $0, name: $1) }
            return menus.isEmpty ? nil : Location(name: decodeEntities(header[1]), menus: menus)
        }
    }

    /// `'groups':[['',,,,[['<guid>',,,,],['<guid>',,,,]]],['',,,,[...]]]` inside the navUnits control.
    private static func navUnitGUIDGroups(_ html: String) -> [[String]] {
        guard let control = html.range(of: "createControl(MVCxClientNavBar,'navUnits'") else { return [] }
        let tail = html[control.upperBound...]
        guard let groupsStart = tail.range(of: "'groups':[") else { return [] }
        let groupsText = String(tail[groupsStart.upperBound...])
        return matches(#"\['',,,,\[((?:\['[0-9a-fA-F-]{36}',,,,\],?)*)\]\]"#, in: groupsText).map { group in
            matches(#"'([0-9a-fA-F-]{36})'"#, in: group[1]).map { $0[1] }
        }
    }

    static func parseStations(_ html: String, menuID: String) -> [Station] {
        // Column order comes from the header row so a reordered or extra column can't shift values.
        let columns = matches(#"class="nutVertText">([^<]*)</div>"#, in: html).map { nutrientKey(for: $0[1]) }

        var stations: [Station] = []
        var currentStation = String(localized: "Menu", comment: "Fallback dining station name")
        for row in html.components(separatedBy: "<tr") {
            if let header = firstMatch(#"class="courseHeader"[^>]*>([^<]*)<"#, in: row) {
                currentStation = decodeEntities(header[1])
                continue
            }
            guard row.contains(#"class="description""#),
                  let ids = firstMatch(#"'([0-9a-fA-F-]{36})','([0-9a-fA-F-]{36})'\)"#, in: row),
                  let nameMatch = firstMatch(#"class="description"[^>]*>\s*([\s\S]*?)\s*</td>"#, in: row)
            else { continue }
            let name = decodeEntities(stripTags(nameMatch[1]))
            guard !name.isEmpty else { continue }
            let serving = firstMatch(#"class="uom"[^>]*>([^<]*)<"#, in: row).map { decodeEntities($0[1]) } ?? ""
            let values = matches(#"class="nutCell(?:Odd|Even)"[^>]*>([^<]*)<"#, in: row).map { number($0[1]) }

            var nutrients = Nutrients()
            for (column, value) in zip(columns, values) {
                guard let column, let value else { continue }
                nutrients[keyPath: column] = value
            }
            let item = MenuItem(
                menuID: ids[1].isEmpty ? menuID : ids[1],
                lineID: ids[2],
                name: name,
                station: currentStation,
                servingText: serving,
                nutrients: nutrients
            )
            if let last = stations.indices.last, stations[last].name == currentStation {
                stations[last].items.append(item)
            } else {
                stations.append(Station(name: currentStation, items: [item]))
            }
        }
        return stations
    }

    static func parseDetails(_ html: String) -> ItemDetails {
        func field(_ label: String) -> String? {
            firstMatch(#"<b>\#(label):</b>\s*([\s\S]*?)</td>"#, in: html)
                .map { decodeEntities(stripTags($0[1])).trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        func list(_ label: String) -> [String] {
            guard let text = field(label), text.caseInsensitiveCompare("None") != .orderedSame else { return [] }
            return text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
                .filter { !$0.isEmpty }
        }
        let trans = firstMatch(#"Trans\s*/\s*trans\s*([\d.]+)\s*g"#, in: html).flatMap { number($0[1]) }
        return ItemDetails(
            ingredients: field("Ingredients"),
            allergens: list("Allergens"),
            mayContain: list("May Contain"),
            tags: list("Tags"),
            transFat: trans
        )
    }

    // MARK: - Mapping into the app

    /// Same shape the barcode lookups produce, so `FoodResultView` can review and log it.
    static func analysis(for item: MenuItem, details: ItemDetails? = nil) -> GeminiService.FoodAnalysis {
        let n = item.nutrients
        let servingSizeGrams: Double
        let servingUnitOptions: [ServingUnitOption]
        let selectedServingUnit: String
        let selectedServingQuantity: Double
        let servingSizeIsKnown: Bool
        if let grams = item.servingGrams, grams > 0 {
            // Values are for this weight; the user can still change grams on the review screen.
            servingSizeGrams = grams
            servingUnitOptions = [ServingUnitOption(unit: "serving", gramsPerUnit: grams, quantity: 1)]
            selectedServingUnit = "serving"
            selectedServingQuantity = 1
            servingSizeIsKnown = true
        } else {
            // "Portion", "Each", "Slice": nutrition is per serving with no published weight.
            // Matches FoodDataCentralService's unknown-serving path.
            servingSizeGrams = 1
            servingUnitOptions = [.loggedServing(quantity: 1)]
            selectedServingUnit = "serving"
            selectedServingQuantity = 1
            servingSizeIsKnown = false
        }

        let metadata = FoodProductMetadata(
            barcode: "",
            packageQuantity: item.servingText.isEmpty ? nil : item.servingText,
            ingredientsText: details?.ingredients,
            allergens: details?.allergens ?? [],
            traces: details?.mayContain ?? [],
            nutriScore: nil,
            novaGroup: nil,
            ecoScore: nil,
            labels: details?.tags ?? [],
            categories: item.station.isEmpty ? [] : [item.station],
            imageURL: nil,
            dataSource: dataSourceID
        )

        return GeminiService.FoodAnalysis(
            name: item.name,
            calories: Int((n.calories ?? 0).rounded()),
            protein: n.protein ?? 0,
            carbs: n.carbs ?? 0,
            fat: n.fat ?? 0,
            servingSizeGrams: servingSizeGrams,
            emoji: "🍽️",
            sugar: n.sugar,
            fiber: n.fiber,
            saturatedFat: n.saturatedFat,
            cholesterol: n.cholesterol,
            sodium: n.sodium,
            transFat: details?.transFat,
            calcium: n.calcium,
            iron: n.iron,
            vitaminC: n.vitaminC,
            servingUnitOptions: servingUnitOptions,
            selectedServingUnit: selectedServingUnit,
            selectedServingQuantity: selectedServingQuantity,
            servingSizeIsKnown: servingSizeIsKnown,
            productMetadata: metadata
        )
    }

    // MARK: - Helpers

    static func grams(fromServing text: String) -> Double? {
        guard let m = firstMatch(#"^\s*([\d.]+)\s*(g|gram|grams)\s*$"#, in: text.lowercased()) else { return nil }
        return Double(m[1])
    }

    /// Maps a column title such as "Saturated Fat (g)" or "Vitamin C (mg}" to a field.
    static func nutrientKey(for title: String) -> WritableKeyPath<Nutrients, Double?>? {
        let base = decodeEntities(title).lowercased()
            .components(separatedBy: "(").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        switch base {
        case "calories", "energy": return \.calories
        case "fat", "total fat": return \.fat
        case "saturated fat": return \.saturatedFat
        case "cholesterol": return \.cholesterol
        case "sodium": return \.sodium
        case "carbohydrate", "carbohydrates", "total carbohydrate": return \.carbs
        case "total fibre", "fibre", "total fiber", "fiber": return \.fiber
        case "sugars", "sugar": return \.sugar
        case "protein": return \.protein
        case "vitamin c": return \.vitaminC
        case "calcium": return \.calcium
        case "iron": return \.iron
        default: return nil
        }
    }

    private static func number(_ text: String) -> Double? {
        // The site prints thousands with a comma ("1,108" mg sodium).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, value) in named where entity != "&amp;" {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities such as &#233; (é)
        for m in matches(#"&#(\d+);"#, in: result).reversed() {
            if let code = UInt32(m[1]), let scalar = Unicode.Scalar(code) {
                result = result.replacingOccurrences(of: m[0], with: String(Character(scalar)))
            }
        }
        // Last, so "&amp;#39;" stays literal text.
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        matches(pattern, in: text).first
    }
}

/// Recognizes residence meal names so a dining hall's menus can default to the current meal.
enum MealPeriod: Sendable {
    case breakfast, lunch, dinner, brunch

    init?(menuName: String) {
        switch menuName.trimmingCharacters(in: .whitespaces).lowercased() {
        case "breakfast": self = .breakfast
        case "lunch": self = .lunch
        case "dinner": self = .dinner
        case "brunch": self = .brunch
        default: return nil
        }
    }

    var mealType: MealType {
        switch self {
        case .breakfast: .breakfast
        case .lunch, .brunch: .lunch
        case .dinner: .dinner
        }
    }
}
