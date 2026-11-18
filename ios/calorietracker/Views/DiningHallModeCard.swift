import SwiftUI

/// "Dining Hall Mode" for photo logging: when on, the vision prompt includes the dorm menu
/// (optionally one meal) so the AI matches the plate against real menu items and their
/// published nutrition instead of guessing generic portions.
enum DiningHallMode {
    static let enabledKey = "diningHallMode.enabled"
    static let periodKey = "diningHallMode.mealPeriod"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var period: MealPeriodFilter {
        UserDefaults.standard.string(forKey: periodKey).flatMap(MealPeriodFilter.init(rawValue:)) ?? .all
    }

    /// The prompt section, or nil when the mode is off or no menu is saved.
    static func promptSection(store: DormMenuStore = .shared) -> String? {
        guard isEnabled else { return nil }
        return store.promptSection(period: period)
    }
}

/// Toggle and meal picker shown on the Meal Photos sheet.
struct DiningHallModeCard: View {
    @AppStorage(DiningHallMode.enabledKey) private var isEnabled = false
    @AppStorage(DiningHallMode.periodKey) private var periodRaw = MealPeriodFilter.all.rawValue
    @State private var store = DormMenuStore.shared

    private var period: Binding<MealPeriodFilter> {
        Binding(
            get: { MealPeriodFilter(rawValue: periodRaw) ?? .all },
            set: { periodRaw = $0.rawValue }
        )
    }

    private var itemCount: Int { store.items(period: period.wrappedValue).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dining Hall Mode")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Text("Match the photo to \(store.location)'s menu and its nutrition facts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Dining Hall Mode", isOn: $isEnabled)
                    .labelsHidden()
                    .tint(AppColors.calorie)
            }

            if isEnabled {
                Picker("Meal", selection: period) {
                    ForEach(MealPeriodFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Group {
                    if store.menu == nil {
                        Text("No menu saved yet. Open Dorm Menu once while online.")
                    } else if itemCount == 0 {
                        Text("Nothing on today's menu for this meal; the AI will estimate as usual.")
                    } else if store.isShowingOldMenu, let date = store.displayedDate {
                        Text("Using the saved menu from \(DormMenuView.displayDate(date)) (\(itemCount) items).")
                    } else {
                        Text("\(itemCount) menu items will be sent with the photo.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .task(id: isEnabled) {
            if isEnabled { await store.refreshIfNeeded() }
        }
    }
}
