import Foundation
import Observation

// MARK: - dorm_menu.json

/// Contents of `dorm_menu.json`: a flat list of menu items, each tagged with its date and meal.
///
/// The app ships `Resources/dorm_menu.json` as a starting point and saves a fresh copy in
/// Application Support whenever it reaches U of T Food Services. Keys are snake_case on disk.
nonisolated struct DormMenu: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var location: String
    var source: String?
    var generatedAt: Date
    var note: String?
    var items: [DormMenuItem]

    static let currentSchemaVersion = 1
}

nonisolated struct DormMenuItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    /// Toronto calendar day, `yyyy-MM-dd`.
    var date: String
    /// "Breakfast", "Lunch", "Dinner" (or a cafeteria station name).
    var mealPeriod: String
    var station: String
    var name: String
    /// As the dining hall prints it: "100g", "Portion", "Each", "Slice", "Bowl".
    var serving: String
    var servingGrams: Double?
    var calories: Int?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var saturatedFatG: Double?
    var fiberG: Double?
    var sugarG: Double?
    var cholesterolMg: Double?
    var sodiumMg: Double?
    var calciumMg: Double?
    var ironMg: Double?
    var vitaminCMg: Double?
    var allergens: [String]?
    var tags: [String]?
    /// Live-site IDs for the item's label (allergens); only valid on `date`.
    var menuId: String?
    var lineId: String?

    var mealType: MealType {
        MealPeriodFilter(rawValue: mealPeriod.lowercased())?.mealType ?? .other
    }
}

nonisolated struct DormMenuSection: Identifiable, Sendable {
    var title: String
    var items: [DormMenuItem]
    var id: String { title }
}

/// The meal filter on the Dorm Menu screen and in Dining Hall Mode.
nonisolated enum MealPeriodFilter: String, CaseIterable, Identifiable, Sendable {
    case all, breakfast, lunch, dinner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All", comment: "Dorm menu meal filter")
        case .breakfast: String(localized: "Breakfast", comment: "Dorm menu meal filter")
        case .lunch: String(localized: "Lunch", comment: "Dorm menu meal filter")
        case .dinner: String(localized: "Dinner", comment: "Dorm menu meal filter")
        }
    }

    var mealType: MealType? {
        switch self {
        case .all: nil
        case .breakfast: .breakfast
        case .lunch: .lunch
        case .dinner: .dinner
        }
    }

    func matches(_ item: DormMenuItem) -> Bool {
        self == .all || item.mealPeriod.caseInsensitiveCompare(rawValue) == .orderedSame
    }

    /// The meal that fits the time of day (snack and other fall back to All).
    static var current: MealPeriodFilter {
        switch MealType.currentMeal {
        case .breakfast: .breakfast
        case .lunch: .lunch
        case .dinner: .dinner
        default: .all
        }
    }
}

// MARK: - Store

/// Loads, searches and refreshes the dorm menu. Works fully offline from the saved or
/// bundled JSON; `refreshIfNeeded()` replaces it with the live menu when the network allows.
@Observable
final class DormMenuStore {
    static let shared = DormMenuStore()

    static let defaultLocation = "Chestnut Residence"
    static let locationKey = "dormMenu.location"
    /// Live refresh saves today plus this many following days.
    static let daysToSave = 2
    private static let staleAfter: TimeInterval = 6 * 60 * 60

    private(set) var menu: DormMenu?
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let bundledURL: URL?

    init(
        defaults: UserDefaults = .standard,
        cacheURL: URL = DormMenuStore.defaultCacheURL,
        bundledURL: URL? = Bundle.main.url(forResource: "dorm_menu", withExtension: "json")
    ) {
        self.defaults = defaults
        self.cacheURL = cacheURL
        self.bundledURL = bundledURL
        menu = Self.load(from: cacheURL) ?? bundledURL.flatMap(Self.load(from:))
    }

    var location: String {
        get { defaults.string(forKey: Self.locationKey) ?? Self.defaultLocation }
        set { defaults.set(newValue, forKey: Self.locationKey) }
    }

    // MARK: Reading

    /// The day shown: today when the saved menu has it, otherwise the newest saved day.
    var displayedDate: String? {
        guard let menu, !menu.items.isEmpty else { return nil }
        let today = UofTDiningService.dayString(for: .now)
        let dates = Set(menu.items.map(\.date))
        return dates.contains(today) ? today : dates.max()
    }

    /// True when the menu on screen is not today's (an old snapshot while offline).
    var isShowingOldMenu: Bool {
        guard let date = displayedDate else { return false }
        return date != UofTDiningService.dayString(for: .now)
    }

    /// Items for `date` (default: `displayedDate`) matching the meal filter and a name search.
    func items(
        matching query: String = "",
        period: MealPeriodFilter = .all,
        on date: String? = nil
    ) -> [DormMenuItem] {
        guard let menu, let day = date ?? displayedDate else { return [] }
        let terms = query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return menu.items.filter { item in
            guard item.date == day, period.matches(item) else { return false }
            guard !terms.isEmpty else { return true }
            let haystack = "\(item.name) \(item.station)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Items grouped by station, in menu order. With `.all`, also grouped by meal first.
    func sections(matching query: String, period: MealPeriodFilter) -> [DormMenuSection] {
        var order: [String] = []
        var grouped: [String: [DormMenuItem]] = [:]
        for item in items(matching: query, period: period) {
            let key = period == .all ? "\(item.mealPeriod) · \(item.station)" : item.station
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.map { DormMenuSection(title: $0, items: grouped[$0] ?? []) }
    }

    // MARK: Refreshing

    /// Fetches the live menu when the saved one is missing, from another day, or older than six hours.
    func refreshIfNeeded() async {
        if let menu, menu.location == location, !isShowingOldMenu,
           Date().timeIntervalSince(menu.generatedAt) < Self.staleAfter {
            return
        }
        await refresh()
    }

    /// Downloads today's and tomorrow's menus for `location` and saves them as `dorm_menu.json`.
    /// On failure the saved menu stays in place, so the screen keeps working offline.
    func refresh(session: URLSession = .shared) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        let location = self.location
        var items: [DormMenuItem] = []
        do {
            for offset in 0..<Self.daysToSave {
                let date = Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now
                do {
                    items += try await UofTDiningService.dormMenuItems(at: location, on: date, session: session)
                } catch UofTDiningService.ServiceError.noMenus where offset > 0 {
                    break   // later days aren't always posted yet
                }
            }
            guard !items.isEmpty else { throw UofTDiningService.ServiceError.noMenus }
            let fresh = DormMenu(
                schemaVersion: DormMenu.currentSchemaVersion,
                location: location,
                source: "U of T Food Services, fso.ueat.utoronto.ca/FSO/ServiceMenuReport",
                generatedAt: .now,
                note: nil,
                items: items
            )
            menu = fresh
            save(fresh)
        } catch is CancellationError {
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    /// Remembers allergens fetched for one item so they show offline next time.
    func update(_ item: DormMenuItem) {
        guard var menu, let index = menu.items.firstIndex(where: { $0.id == item.id }) else { return }
        menu.items[index] = item
        self.menu = menu
        save(menu)
    }

    // MARK: Dining Hall Mode prompt

    /// Menu lines for the photo prompt: today's items for `period`, deduplicated by name and
    /// capped so the prompt stays small. Nil when there is no menu to match against.
    func promptSection(period: MealPeriodFilter, limit: Int = 300) -> String? {
        var seen = Set<String>()
        let lines = items(period: period).compactMap { item -> String? in
            guard let calories = item.calories, calories > 0,
                  seen.insert(item.name.lowercased()).inserted else { return nil }
            func g(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "?" }
            let weight = item.servingGrams.map { String(format: "%.0f g", $0) } ?? "weight not published"
            // One short line per item keeps a full day's menu to a few thousand tokens.
            let per = item.serving.isEmpty ? "serving" : item.serving
            // With All, items served at several meals appear once, so the meal isn't named.
            let place = period == .all ? item.station : "\(item.station), \(item.mealPeriod)"
            return "- \(item.name) (\(place)); per \(per), \(weight): "
                + "\(calories) kcal, P \(g(item.proteinG)), C \(g(item.carbsG)), F \(g(item.fatG)), fiber \(g(item.fiberG)), sugar \(g(item.sugarG)), sodium mg \(g(item.sodiumMg))"
        }
        guard !lines.isEmpty else { return nil }
        let shown = lines.prefix(limit)
        let mealText = period == .all ? "today" : "today's \(period.rawValue)"
        return """
        DINING HALL MODE: The user is eating at \(menu?.location ?? "their dining hall"). These are \(mealText) menu items with the dining hall's published nutrition (P/C/F, fiber and sugar in grams):
        \(shown.joined(separator: "\n"))

        Match each food in the photos to the closest menu item above and use that item's name and its nutrition per serving, scaled by how many servings (or grams) are visible. For items listed per 100 g, estimate the grams on the plate. Only invent values for a food that clearly matches nothing on the menu, and say so in its name with "(not on menu)". Put each matched item in the ingredients list with its menu name.
        """
    }

    // MARK: Files

    static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DormMenu", isDirectory: true).appendingPathComponent("dorm_menu.json")
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func load(from url: URL) -> DormMenu? {
        guard let data = try? Data(contentsOf: url),
              let menu = try? decoder.decode(DormMenu.self, from: data),
              menu.schemaVersion <= DormMenu.currentSchemaVersion
        else { return nil }
        return menu
    }

    private func save(_ menu: DormMenu) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(menu).write(to: cacheURL, options: .atomic)
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }
}

// MARK: - Live site → dorm_menu.json items

extension UofTDiningService {
    /// Every meal served at `location` on `date`, as dorm menu items.
    static func dormMenuItems(at location: String, on date: Date, session: URLSession = .shared) async throws -> [DormMenuItem] {
        let locations = try await locations(on: date, session: session)
        guard let match = locations.first(where: { $0.name.caseInsensitiveCompare(location) == .orderedSame }) else {
            throw ServiceError.noMenus
        }
        let day = dayString(for: date)
        var items: [DormMenuItem] = []
        for menu in match.menus {
            for station in try await stations(menuID: menu.id, session: session) {
                items += station.items.map { dormMenuItem(from: $0, mealPeriod: menu.name, day: day) }
            }
        }
        return items
    }

    static func dormMenuItem(from item: MenuItem, mealPeriod: String, day: String) -> DormMenuItem {
        let n = item.nutrients
        return DormMenuItem(
            id: "\(day)-\(item.lineID)",
            date: day,
            mealPeriod: mealPeriod,
            station: item.station,
            name: item.name,
            serving: item.servingText,
            servingGrams: item.servingGrams,
            calories: n.calories.map { Int($0.rounded()) },
            proteinG: n.protein,
            carbsG: n.carbs,
            fatG: n.fat,
            saturatedFatG: n.saturatedFat,
            fiberG: n.fiber,
            sugarG: n.sugar,
            cholesterolMg: n.cholesterol,
            sodiumMg: n.sodium,
            calciumMg: n.calcium,
            ironMg: n.iron,
            vitaminCMg: n.vitaminC,
            menuId: item.menuID,
            lineId: item.lineID
        )
    }

    /// `yyyy-MM-dd` for the Toronto day containing `date`.
    static func dayString(for date: Date) -> String {
        let compact = dateParameter(for: date)   // yyyyMMdd
        let s = Array(compact)
        guard s.count == 8 else { return compact }
        return "\(String(s[0..<4]))-\(String(s[4..<6]))-\(String(s[6..<8]))"
    }
}
