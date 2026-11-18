import SwiftUI

/// "Dorm Menu" from the + menu: search the dining hall menu, filter by meal, pick a serving
/// and log it straight into the day's totals. Works offline from the saved `dorm_menu.json`.
///
/// Visual style "Plain Diary": edge-to-edge rows on the system background, hairline
/// dividers, small grey section headers and a macro table. System colors give light
/// and dark mode; the app's theme color is used only for actions.
struct DormMenuView: View {
    /// The day the food is logged on (the day open on the home screen).
    let logDate: Date
    /// Saves the entry. Return false if logging is blocked (e.g. during a fast).
    let onLog: (FoodEntry) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var store = DormMenuStore.shared
    @State private var searchText = ""
    @State private var period: MealPeriodFilter = .current

    static let locations = [
        "Chestnut Residence",
        "CampusOne Dining Hall",
        "New College Dining Hall",
        "Oak House Dining Hall",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Meal", selection: $period) {
                        ForEach(MealPeriodFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    statusLine
                        .listRowSeparator(.hidden)
                }
                .listRowBackground(Color.clear)

                let sections = store.sections(matching: searchText, period: period)
                if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                NavigationLink(value: item) { DormMenuRow(item: item) }
                            }
                        } header: {
                            Text(section.title)
                                .font(.footnote.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search \(store.location)"))
            .navigationTitle("Dorm Menu")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DormMenuItem.self) { item in
                DormMenuItemView(item: item, logDate: logDate) { entry in
                    if onLog(entry) { dismiss() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Dining Hall", selection: Binding(
                            get: { store.location },
                            set: { newValue in
                                store.location = newValue
                                Task { await store.refresh() }
                            }
                        )) {
                            ForEach(Self.locations, id: \.self) { Text($0).tag($0) }
                        }
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh Menu", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "building.2")
                            .accessibilityLabel("Dining hall")
                    }
                }
            }
            .refreshable { await store.refresh() }
            .task { await store.refreshIfNeeded() }
        }
        .tint(AppColors.calorie)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Updating menu…")
            } else if store.isShowingOldMenu, let date = store.displayedDate {
                Image(systemName: "wifi.slash")
                Text("Offline · showing the saved menu from \(Self.displayDate(date))")
            } else if let menu = store.menu {
                Text("\(menu.location) · \(store.displayedDate.map(Self.displayDate) ?? "")")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if store.menu == nil {
                    Text("No menu saved yet").font(.headline)
                    Text(store.lastRefreshError ?? String(localized: "Connect to the internet once to download your dining hall's menu."))
                        .foregroundStyle(.secondary)
                } else if searchText.isEmpty {
                    Text("Nothing listed for \(period.title)").foregroundStyle(.secondary)
                } else {
                    Text("No matches for “\(searchText)”").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    static func displayDate(_ day: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// One menu row: name, serving and macros on the left, calories on the right.
private struct DormMenuRow: View {
    let item: DormMenuItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(DormMenuMath.macroSummary(for: item, multiplier: 1))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let calories = item.calories {
                Text("\(calories)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .accessibilityLabel("\(calories) calories")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Serving picker with live macros and the Log Food button.
struct DormMenuItemView: View {
    let item: DormMenuItem
    let logDate: Date
    let onLog: (FoodEntry) -> Void

    @State private var multiplier: Double = 1
    @State private var details: DormMenuItem?
    @State private var isLogging = false

    static let multipliers: [Double] = [0.5, 1, 1.5, 2]

    private var current: DormMenuItem { details ?? item }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.title2.weight(.bold))
                    Text("\(item.station) · \(item.mealPeriod) · \(item.serving.isEmpty ? String(localized: "1 serving") : item.serving) per serving")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Servings")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Servings", selection: $multiplier) {
                        ForEach(Self.multipliers, id: \.self) { value in
                            Text(DormMenuMath.multiplierLabel(value)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    if let grams = item.servingGrams {
                        Text("\(DormMenuMath.number(grams * multiplier)) g total")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)

                macroTable
                    .listRowInsets(EdgeInsets())
            }

            Section {
                detailRow("Saturated Fat", DormMenuMath.amount(current.saturatedFatG, multiplier, unit: "g"))
                detailRow("Fiber", DormMenuMath.amount(current.fiberG, multiplier, unit: "g"))
                detailRow("Sugar", DormMenuMath.amount(current.sugarG, multiplier, unit: "g"))
                detailRow("Sodium", DormMenuMath.amount(current.sodiumMg, multiplier, unit: "mg"))
                detailRow("Cholesterol", DormMenuMath.amount(current.cholesterolMg, multiplier, unit: "mg"))
                if let allergens = current.allergens {
                    detailRow("Allergens", allergens.isEmpty ? String(localized: "None listed") : allergens.formatted())
                }
                if let tags = current.tags, !tags.isEmpty {
                    detailRow("Tags", tags.formatted())
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                guard !isLogging else { return }
                isLogging = true
                onLog(DormMenuMath.entry(for: current, multiplier: multiplier, logDate: logDate))
            } label: {
                Text("Log Food")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .tint(AppColors.calorie)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .task { await loadAllergens() }
    }

    private var macroTable: some View {
        let cells: [(String, String)] = [
            (String(localized: "Calories"), DormMenuMath.number(Double(current.calories ?? 0) * multiplier, decimals: 0)),
            (String(localized: "Carbs"), DormMenuMath.amount(current.carbsG, multiplier, unit: "g")),
            (String(localized: "Fat"), DormMenuMath.amount(current.fatG, multiplier, unit: "g")),
            (String(localized: "Protein"), DormMenuMath.amount(current.proteinG, multiplier, unit: "g")),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 { Divider() }
                VStack(spacing: 2) {
                    Text(cell.1)
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(cell.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    /// Allergens and tags come from the item's label on the live site; fetched once and saved.
    private func loadAllergens() async {
        guard item.allergens == nil,
              item.date == UofTDiningService.dayString(for: .now),
              let menuID = item.menuId, let lineID = item.lineId else { return }
        let ref = UofTDiningService.MenuItem(
            menuID: menuID, lineID: lineID, name: item.name, station: item.station,
            servingText: item.serving, nutrients: .init()
        )
        guard let label = try? await UofTDiningService.details(for: ref) else { return }
        var updated = item
        updated.allergens = label.allergens
        updated.tags = label.tags
        details = updated
        DormMenuStore.shared.update(updated)
    }
}

/// Serving math and the FoodEntry the app stores, kept out of the views so it can be tested.
enum DormMenuMath {
    static func multiplierLabel(_ value: Double) -> String {
        "\(number(value, decimals: value == value.rounded() ? 0 : 1))×"
    }

    static func number(_ value: Double, decimals: Int? = nil) -> String {
        let places = decimals ?? (abs(value) >= 10 ? 0 : 1)
        return value.formatted(.number.precision(.fractionLength(places)))
    }

    static func amount(_ value: Double?, _ multiplier: Double, unit: String) -> String {
        guard let value else { return "–" }
        return "\(number(value * multiplier)) \(unit)"
    }

    static func macroSummary(for item: DormMenuItem, multiplier: Double) -> String {
        func g(_ v: Double?) -> String { v.map { number($0 * multiplier, decimals: 0) } ?? "–" }
        let serving = item.serving.isEmpty ? "" : "\(item.serving) · "
        return "\(serving)C \(g(item.carbsG))g · F \(g(item.fatG))g · P \(g(item.proteinG))g"
    }

    /// A food log entry in the app's normal format. Weighed items keep their grams so the
    /// entry can be edited later; "Portion"/"Each" items are stored as a serving count.
    static func entry(for item: DormMenuItem, multiplier: Double, logDate: Date) -> FoodEntry {
        func scaled(_ value: Double?) -> Double? { value.map { $0 * multiplier } }
        let grams = item.servingGrams.flatMap { $0 > 0 ? $0 : nil }
        let meal = item.mealType == .other ? MealType.currentMeal : item.mealType
        let metadata = FoodProductMetadata(
            barcode: "",
            packageQuantity: item.serving.isEmpty ? nil : item.serving,
            ingredientsText: nil,
            allergens: item.allergens ?? [],
            traces: [],
            nutriScore: nil,
            novaGroup: nil,
            ecoScore: nil,
            labels: item.tags ?? [],
            categories: [item.station],
            imageURL: nil,
            dataSource: UofTDiningService.dataSourceID
        )
        return FoodEntry(
            name: item.name,
            calories: Int((Double(item.calories ?? 0) * multiplier).rounded()),
            protein: scaled(item.proteinG) ?? 0,
            carbs: scaled(item.carbsG) ?? 0,
            fat: scaled(item.fatG) ?? 0,
            timestamp: logDate,
            emoji: "🍽️",
            source: .manual,   // published dining hall data, not an AI estimate
            mealType: meal,
            sugar: scaled(item.sugarG),
            fiber: scaled(item.fiberG),
            saturatedFat: scaled(item.saturatedFatG),
            cholesterol: scaled(item.cholesterolMg),
            sodium: scaled(item.sodiumMg),
            calcium: scaled(item.calciumMg),
            iron: scaled(item.ironMg),
            vitaminC: scaled(item.vitaminCMg),
            servingSizeGrams: grams.map { $0 * multiplier },
            servingUnitOptions: grams.map { [ServingUnitOption(unit: "serving", gramsPerUnit: $0, quantity: multiplier)] } ?? [],
            selectedServingUnit: "serving",
            selectedServingQuantity: multiplier,
            productMetadata: metadata
        )
    }
}

#Preview {
    DormMenuView(logDate: .now) { _ in true }
}
