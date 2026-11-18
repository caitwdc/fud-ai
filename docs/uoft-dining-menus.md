# Dorm Menu (U of T dining halls)

Log food from your University of Toronto dining hall menu, offline, with the nutrition
Food Services publishes. Photo logging can also match a plate against that menu.

## What's in the app

- **+ → Dorm Menu** (`Views/DormMenuView.swift`): search by name, filter All / Breakfast /
  Lunch / Dinner, tap an item, pick 0.5×, 1×, 1.5× or 2× (macros update live), then **Log Food**.
  The entry goes into the day's totals through `FoodStore.addEntry`, with `source: .manual`
  (published data, not an AI estimate). Weighed items keep their grams, and Portion/Each
  items are stored as a serving count. The dining hall menu in the toolbar switches halls.
  Pull to refresh.
- **Dining Hall Mode** (`Views/DiningHallModeCard.swift`, on the Meal Photos sheet): when
  on, the photo prompt includes the saved menu (all meals or one) with each dish's
  nutrition. The AI is told to match foods to those dishes and scale by the servings it
  sees. Up to 300 dishes are sent (a full Chestnut day is about 200, roughly 6.6k tokens).
  Apple Intelligence on-device photo analysis ignores this section, because it doesn't use the text prompt.
- **Data** (`Stores/DormMenuStore.swift`): reads `dorm_menu.json` from Application Support,
  or the bundled `Resources/dorm_menu.json` (Chestnut Residence, Nov 17 2026, 312 items).
  When online it downloads today's and tomorrow's menus and saves them in the same
  format. It refreshes when the saved menu is from another day or more than six hours old.
  Offline, it shows the newest saved day and says so.
- **Allergens and tags** are not in the JSON, because each one needs a separate request.
  They're fetched when you open an item from today's live menu, then saved.

## dorm_menu.json

```json
{
  "schema_version": 1,
  "location": "Chestnut Residence",
  "generated_at": "2026-11-17T23:45:00-05:00",
  "items": [
    {"id": "…", "date": "2026-11-17", "meal_period": "Lunch", "station": "Deli Bar",
     "name": "Egg Salad", "serving": "100g", "serving_grams": 100, "calories": 203,
     "protein_g": 13.75, "carbs_g": 1.19, "fat_g": 15.89, "saturated_fat_g": 3.343,
     "fiber_g": 0.3, "sugar_g": 0.05, "cholesterol_mg": 389, "sodium_mg": 244,
     "calcium_mg": 55, "iron_mg": 1.77, "vitamin_c_mg": 0.1}
  ]
}
```

Optional per item: `allergens`, `tags`, `menu_id`, `line_id` (live-site IDs, valid only on `date`).

## How the U of T site works

There's no public API, but three stateless HTML endpoints (no login, HTTPS) drive the page
(`Services/UofTDiningService.swift`):

| Step | Request | Returns |
|---|---|---|
| Locations for a day | `GET /FSO/ServiceMenuReport/GetDate?dt=YYYYMMDD` | Location tree (`navUnits`). Menu GUIDs are in the control's `'groups':[...]` state, in tree order, and change daily. |
| Items on a menu | `POST /FSO/ServiceMenuReport/GetReport/{menuID}` | Table of stations and items with serving and 12 nutrients. Numbers may contain thousands separators (`1,108`). |
| One item's label | `POST /FSO/ServiceMenuReport/GetLabel/{menuID}/{lineID}` | Ingredients, allergens, may-contain, tags. |

POST body: `allergens=&tags=&maycontain=`. Menus are posted for today plus six days.

## CI: `.github/workflows/build-ios.yml`

This runs on pushes to `main`/`master` (or manually). It builds an unsigned Release app, zips
`Payload/<app>.app` as `FudAI.ipa`, and uploads it as the `FudAI-ipa` artifact. It runs on
`xcode-27`, not `macos-latest`, because the app needs Xcode 27 and `macos-latest` has Xcode 26.
An unsigned IPA must be re-signed (for example with Sideloadly or AltStore) before an iPhone will install it.

## Tests

`calorietrackerTests/DormMenuTests.swift` covers JSON decoding, search and filters, serving
math, the logged entry and the prompt. `UofTDiningServiceTests.swift` covers the HTML parsers.
