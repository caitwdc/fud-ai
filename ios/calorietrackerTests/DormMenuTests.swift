import Foundation
import Testing
@testable import calorietracker

@Suite("Dorm menu")
@MainActor
struct DormMenuTests {
    /// A store reading the bundled Chestnut Residence snapshot (Nov 17 2026), with no saved copy.
    private func bundledStore() throws -> DormMenuStore {
        let suite = "DormMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("dorm_menu.json")
        let bundled = try #require(Bundle.main.url(forResource: "dorm_menu", withExtension: "json"))
        return DormMenuStore(defaults: defaults, cacheURL: cache, bundledURL: bundled)
    }

    @Test func bundledJSONDecodes() throws {
        let menu = try #require(try bundledStore().menu)
        #expect(menu.location == "Chestnut Residence")
        #expect(menu.items.count == 312)
        #expect(Set(menu.items.map(\.mealPeriod)) == ["Breakfast", "Lunch", "Dinner"])
        let egg = try #require(menu.items.first { $0.name == "Egg Salad" && $0.mealPeriod == "Lunch" })
        #expect(egg.calories == 203)
        #expect(egg.proteinG == 13.75)
        #expect(egg.servingGrams == 100)
        #expect(egg.sodiumMg == 244)
        #expect(egg.mealType == .lunch)
        // Thousands separators in the source ("1,108") are stored as numbers.
        let muffin = try #require(menu.items.first { $0.name == "Egg And Cheddar Muffin" })
        #expect(muffin.sodiumMg == 1108)
    }

    @Test func searchAndMealFilter() throws {
        let store = try bundledStore()
        let day = "2026-11-17"
        #expect(store.items(period: .lunch, on: day).allSatisfy { $0.mealPeriod == "Lunch" })
        #expect(store.items(matching: "egg salad", period: .all, on: day).count == 6)   // 2 kinds × 3 meals
        #expect(store.items(matching: "egg salad", period: .dinner, on: day).map(\.name) == ["Egg Salad", "Cauliflower Egg Salad"])
        #expect(store.items(matching: "BUTTERNUT", period: .breakfast, on: day).isEmpty)
        // Searching also matches the station name.
        #expect(!store.items(matching: "deli", period: .lunch, on: day).isEmpty)
        #expect(store.items(matching: "zzz", on: day).isEmpty)
    }

    @Test func sectionsGroupByStation() throws {
        let store = try bundledStore()
        let lunch = store.sections(matching: "", period: .lunch)
        #expect(lunch.first?.title == "Deli Bar")
        let all = store.sections(matching: "", period: .all)
        #expect(all.first?.title == "Breakfast · Breakfast Entree")
    }

    @Test func servingMultiplierScalesTheLoggedEntry() throws {
        let store = try bundledStore()
        let egg = try #require(store.items(matching: "egg salad", period: .lunch).first { $0.name == "Egg Salad" })
        let logDate = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = DormMenuMath.entry(for: egg, multiplier: 1.5, logDate: logDate)

        #expect(entry.name == "Egg Salad")
        #expect(entry.calories == 305)        // 203 × 1.5 = 304.5 → 305
        #expect(abs(entry.protein - 20.625) < 0.0001)
        #expect(abs(entry.fat - 23.835) < 0.0001)
        #expect(entry.servingSizeGrams == 150)
        #expect(entry.selectedServingQuantity == 1.5)
        #expect(entry.servingUnitOptions == [ServingUnitOption(unit: "serving", gramsPerUnit: 100, quantity: 1.5)])
        #expect(entry.mealType == .lunch)
        #expect(entry.source == .manual)
        #expect(entry.timestamp == logDate)
        #expect(entry.productMetadata?.dataSource == UofTDiningService.dataSourceID)
    }

    @Test func portionItemsLogAServingCountWithoutGrams() throws {
        let store = try bundledStore()
        let soup = try #require(store.items(matching: "butternut", period: .lunch).first)
        let entry = DormMenuMath.entry(for: soup, multiplier: 0.5, logDate: .now)
        #expect(entry.calories == 61)
        #expect(entry.servingSizeGrams == nil)
        #expect(entry.servingUnitOptions.isEmpty)
        #expect(entry.selectedServingUnit == "serving")
        #expect(entry.selectedServingQuantity == 0.5)
    }

    @Test func diningHallPromptListsTheMenu() throws {
        let store = try bundledStore()
        let lunch = try #require(store.promptSection(period: .lunch))
        #expect(lunch.contains("DINING HALL MODE"))
        #expect(lunch.contains("Chestnut Residence"))
        #expect(lunch.contains("- Egg Salad (Deli Bar, Lunch); per 100g, 100 g: 203 kcal, P 13.8, C 1.2, F 15.9"))
        #expect(!lunch.contains("Garlic Naan Bread"))   // breakfast only

        // All meals: repeated dishes appear once, and the whole day fits under the cap.
        let all = try #require(store.promptSection(period: .all))
        let lines = all.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == Set(lines).count)
        #expect(lines.filter { $0.hasPrefix("- Egg Salad (") }.count == 1)
        #expect(all.contains("Steamed Jasmine Rice"))   // dinner made it in
    }

    @Test func mealFilterHelpers() {
        #expect(MealPeriodFilter.lunch.mealType == .lunch)
        #expect(MealPeriodFilter.all.mealType == nil)
        #expect(DormMenuMath.multiplierLabel(0.5).hasSuffix("×"))
        #expect(UofTDiningService.dayString(for: ISO8601DateFormatter().date(from: "2026-11-18T04:30:00Z")!) == "2026-11-17")
    }

    @Test func savedCopyWinsOverTheBundledSnapshot() throws {
        let suite = "DormMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cache = folder.appendingPathComponent("dorm_menu.json")
        let saved = DormMenu(
            schemaVersion: 1, location: "Oak House Dining Hall", source: nil, generatedAt: .now, note: nil,
            items: [DormMenuItem(id: "x", date: "2026-11-18", mealPeriod: "Dinner", station: "Grill", name: "Test Burger", serving: "Each")]
        )
        try DormMenuStore.encoder.encode(saved).write(to: cache)
        let store = DormMenuStore(
            defaults: defaults, cacheURL: cache,
            bundledURL: Bundle.main.url(forResource: "dorm_menu", withExtension: "json")
        )
        #expect(store.menu?.location == "Oak House Dining Hall")
        #expect(store.items(period: .dinner).map(\.name) == ["Test Burger"])
    }
}
