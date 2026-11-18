import Foundation
import Testing
@testable import calorietracker

/// Fixtures are trimmed recordings of fso.ueat.utoronto.ca (Nov 17 2026). The location
/// page keeps three of its seven groups; markup is otherwise as the server sends it.
@Suite("U of T dining menus")
@MainActor
struct UofTDiningServiceTests {
    @Test func locationTreePairsNamesWithMenuIDs() {
        let locations = UofTDiningService.parseLocations(UofTDiningFixtures.locationPage)

        #expect(locations.map(\.name) == ["CampusOne Dining Hall", "Chestnut Residence", "Sidney Smith Cafeteria"])
        let chestnut = locations[1]
        #expect(chestnut.menus.map(\.name) == ["Breakfast", "Lunch", "Dinner"])
        #expect(chestnut.menus[1].id == "1b42bfe9-40a3-4252-8ce3-5b1aeb93872e")
        #expect(chestnut.menus[1].mealType == .lunch)
        #expect(chestnut.isDiningHall)

        let sidSmith = locations[2]
        // HTML entities are decoded and cafeteria stations aren't treated as meals.
        #expect(sidSmith.menus.map(\.name) == ["Pronto", "Smart Chicken", "Smash'd Burger"])
        #expect(sidSmith.menus[2].id == "8e9f62fd-493a-4435-94ad-055f3ece01bb")
        #expect(!sidSmith.isDiningHall)
    }

    @Test func pageWithoutTheLocationTreeHasNoLocations() {
        #expect(UofTDiningService.parseLocations("<html><body>Maintenance</body></html>").isEmpty)
    }

    @Test func menuTableGroupsItemsByStationWithNutrients() throws {
        let stations = UofTDiningService.parseStations(
            UofTDiningFixtures.chestnutLunch,
            menuID: "1b42bfe9-40a3-4252-8ce3-5b1aeb93872e"
        )

        #expect(stations.map(\.name) == ["Deli Bar", "Soup"])
        #expect(stations[0].items.map(\.name) == ["Egg Salad", "Tuna Salad"])

        let egg = stations[0].items[0]
        #expect(egg.lineID == "e39ac641-a517-4eaa-8bcf-53420ce68dd6")
        #expect(egg.menuID == "1b42bfe9-40a3-4252-8ce3-5b1aeb93872e")
        #expect(egg.station == "Deli Bar")
        #expect(egg.servingText == "100g")
        #expect(egg.servingGrams == 100)
        #expect(egg.nutrients.calories == 203)
        #expect(egg.nutrients.fat == 15.89)
        #expect(egg.nutrients.saturatedFat == 3.343)
        #expect(egg.nutrients.cholesterol == 389)
        #expect(egg.nutrients.sodium == 244)
        #expect(egg.nutrients.carbs == 1.19)
        #expect(egg.nutrients.fiber == 0.3)
        #expect(egg.nutrients.sugar == 0.05)
        #expect(egg.nutrients.protein == 13.75)
        #expect(egg.nutrients.vitaminC == 0.1)
        #expect(egg.nutrients.calcium == 55)
        #expect(egg.nutrients.iron == 1.77)

        let soup = try #require(stations[1].items.first)
        #expect(soup.name == "Butternut Squash Soup")
        #expect(soup.servingText == "Portion")
        #expect(soup.servingGrams == nil)
    }

    @Test func labelPopupGivesAllergensIngredientsAndTags() {
        let details = UofTDiningService.parseDetails(UofTDiningFixtures.eggSaladLabel)

        #expect(details.allergens == ["Egg"])
        #expect(details.mayContain.isEmpty)
        #expect(details.tags == ["Vegetarian"])
        #expect(details.transFat == 0)
        #expect(details.ingredients?.hasPrefix("Pillow Pack Boiled Egg (Hard Cooked Eggs") == true)
    }

    @Test func weighedItemMapsToAKnownServing() throws {
        let item = try #require(UofTDiningService.parseStations(UofTDiningFixtures.chestnutLunch, menuID: "m").first?.items.first)
        let details = UofTDiningService.parseDetails(UofTDiningFixtures.eggSaladLabel)
        let analysis = UofTDiningService.analysis(for: item, details: details)

        #expect(analysis.name == "Egg Salad")
        #expect(analysis.calories == 203)
        #expect(analysis.protein == 13.75)
        #expect(analysis.carbs == 1.19)
        #expect(analysis.fat == 15.89)
        #expect(analysis.servingSizeGrams == 100)
        #expect(analysis.servingSizeIsKnown)
        #expect(analysis.servingUnitOptions == [ServingUnitOption(unit: "serving", gramsPerUnit: 100, quantity: 1)])
        #expect(analysis.sodium == 244)
        #expect(analysis.transFat == 0)

        let metadata = try #require(analysis.productMetadata)
        #expect(metadata.dataSource == UofTDiningService.dataSourceID)
        #expect(metadata.dataSourceName == "U of T Food Services")
        #expect(metadata.allergens == ["Egg"])
        #expect(metadata.labels == ["Vegetarian"])
        #expect(metadata.categories == ["Deli Bar"])
    }

    @Test func portionItemMapsToAnUnknownWeightServing() throws {
        let soup = try #require(UofTDiningService.parseStations(UofTDiningFixtures.chestnutLunch, menuID: "m").last?.items.first)
        let analysis = UofTDiningService.analysis(for: soup)

        #expect(analysis.calories == 122)
        #expect(!analysis.servingSizeIsKnown)
        #expect(analysis.servingUnitOptions == [.loggedServing(quantity: 1)])
        #expect(analysis.selectedServingUnit == "serving")
        #expect(analysis.productMetadata?.allergens == [])
    }

    @Test func thousandsSeparatorsAndBlankCellsParse() throws {
        // Real rows: "Egg And Cheddar Muffin" lists 1,108 mg sodium; made-to-order pizza has no numbers.
        let html = UofTDiningFixtures.chestnutLunch
            .replacingOccurrences(of: #"<td class="nutCellOdd">244</td>"#, with: #"<td class="nutCellOdd">1,108</td>"#)
            .replacingOccurrences(of: #"<td class="nutCellOdd">122</td>"#, with: #"<td class="nutCellOdd"></td>"#)
        let stations = UofTDiningService.parseStations(html, menuID: "m")
        #expect(stations.first?.items.first?.nutrients.sodium == 1108)
        let soup = try #require(stations.last?.items.first)
        #expect(soup.nutrients.calories == nil)
        #expect(soup.nutrients.fat == 1.36)
    }

    @Test func helpers() {
        #expect(UofTDiningService.grams(fromServing: " 250 g ") == 250)
        #expect(UofTDiningService.grams(fromServing: "Each") == nil)
        #expect(UofTDiningService.decodeEntities("Mac &amp; Cheese &#39;n&#39; Peas") == "Mac & Cheese 'n' Peas")
        #expect(UofTDiningService.nutrientKey(for: "Iron (mg}") == \UofTDiningService.Nutrients.iron)
        #expect(UofTDiningService.nutrientKey(for: "Mystery (g)") == nil)

        // 11:30 PM Nov 17 in Toronto is already Nov 18 in UTC; the site wants the Toronto day.
        let lateEvening = ISO8601DateFormatter().date(from: "2026-11-18T04:30:00Z")!
        #expect(UofTDiningService.dateParameter(for: lateEvening) == "20261117")
    }
}

enum UofTDiningFixtures {
    static let locationPage = #"""
<table border="0" width="100%"> <tr> <td valign="top" class="navOption"> <ul class="dxnbLite_MaterialCompact dx-acc-r dxnbSys" id="navUnits" role="tablist"> <li class="dxnb-gr" role="presentation"><div class="dxnb-header" style="cursor:default;" role="presentation"> <span class="dx-acc dxWeb_nbCollapse_MaterialCompact dxnb-btnLeft dx-acc-s" role="presentation"><img src="/FSO/DXR.axd?r=1_85-RVO3t" alt="" role="presentation"></span><a class="dxalink dx-vam" aria-expanded="true" href="javascript:;" role="tab" aria-haspopup="true"><span class="dxnb-ghtext" role="presentation">CampusOne Dining Hall</span></a> </div><div class="dxnb-headerCollapsed"> <a class="dxalink dx-vam" href="javascript:;"><span class="dxnb-ghtext">CampusOne Dining Hall</span></a> </div><ul class="dxnb-content dxnb-left"> <li class="dxnb-item"><a class="dxnb-link dxalink" href="javascript:;" style="padding-left:50px;" role="tab"><span class="dx-vam" role="presentation">Breakfast</span></a></li><li class="dxnb-item"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Lunch</span></a></li><li class="dxnb-item dxnb-last"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Dinner</span></a></li> </ul></li><li class="dxnb-gr"><div class="dxnb-header"> <a class="dxalink dx-vam" href="javascript:;"><span class="dxnb-ghtext">Chestnut Residence</span></a> </div><div class="dxnb-headerCollapsed"> <a class="dxalink dx-vam" href="javascript:;"><span class="dxnb-ghtext">Chestnut Residence</span></a> </div><ul class="dxnb-content dxnb-left"> <li class="dxnb-item"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Breakfast</span></a></li><li class="dxnb-item"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Lunch</span></a></li><li class="dxnb-item dxnb-last"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Dinner</span></a></li> </ul></li><li class="dxnb-gr"><div class="dxnb-header"> <a class="dxalink dx-vam" href="javascript:;"><span class="dxnb-ghtext">Sidney Smith Cafeteria</span></a> </div><div class="dxnb-headerCollapsed"> <a class="dxalink dx-vam" href="javascript:;"><span class="dxnb-ghtext">Sidney Smith Cafeteria</span></a> </div><ul class="dxnb-content dxnb-left"> <li class="dxnb-item"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Pronto</span></a></li><li class="dxnb-item"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Smart Chicken</span></a></li><li class="dxnb-item dxnb-last"><a class="dxnb-link dxalink" href="javascript:;"><span class="dx-vam">Smash&#39;d Burger</span></a></li> </ul></li> </ul><b class="dx-clear"></b><script id="dxss_1" type="text/javascript">
<!--
ASPx.AddHoverItems('navUnits',[[['dxnb-headerHover'],[''],['GHE0','GHE1','GHE2']]]);
ASPx.createControl(MVCxClientNavBar,'navUnits','',{'accessibilityCompliant':true,'stateObject':{'serverStateEncoded':''},'autoCollapse':true,'enableAnimation':true,'allowSelectItem':true,'selectedItemIndexPath':'','groupsExpanding':[true,false,false]},{'ItemClick':function(s,e){SelectedItemChanged(e);}},null,{'groups':[['',,,,[['66906dc3-aebb-497b-8cd7-a6557e18d042',,,,],['f9874605-411c-449d-ae46-8b1839bdd421',,,,],['5af1ffdc-8639-4223-a791-056e4df5f408',,,,]]],['',,,,[['79c5c21e-f264-4767-80ce-75a92eb43585',,,,],['1b42bfe9-40a3-4252-8ce3-5b1aeb93872e',,,,],['f1814a4c-b556-4c08-a0b1-6416706f6ea3',,,,]]],['',,,,[['b9208841-7f87-4a7c-b7f4-cd3738584ae4',,,,],['1a5c9d8b-c81b-4b11-8b4b-7b561d250c20',,,,],['8e9f62fd-493a-4435-94ad-055f3ece01bb',,,,]]]]});
//-->
</script> </td> </tr> </table>
"""#

    static let chestnutLunch = #"""
<div style="margin:8px;">
<div class="nutritionReport" style="width:100%;">
<table border="0">
<tr>
<th class="nutHeadEvenHorz" align="left" style="padding-left:8px;">Menu Item</th>
<th class="nutHeadEvenHorz">Serving Size</th>
<th class="nutHeadOdd"><div class="nutVertText">Calories</div></th>
<th class="nutHeadEven"><div class="nutVertText">Fat (g)</div></th>
<th class="nutHeadOdd"><div class="nutVertText">Saturated Fat (g)</div></th>
<th class="nutHeadEven"><div class="nutVertText">Cholesterol (mg)</div></th>
<th class="nutHeadOdd"><div class="nutVertText">Sodium (mg)</div></th>
<th class="nutHeadEven"><div class="nutVertText">Carbohydrate (g)</div></th>
<th class="nutHeadOdd"><div class="nutVertText">Total Fibre (g)</div></th>
<th class="nutHeadEven"><div class="nutVertText">Sugars (g)</div></th>
<th class="nutHeadOdd"><div class="nutVertText">Protein (g)</div></th>
<th class="nutHeadEven"><div class="nutVertText">Vitamin C (mg}</div></th>
<th class="nutHeadOdd"><div class="nutVertText">Calcium (mg)</div></th>
<th class="nutHeadEven"><div class="nutVertText">Iron (mg}</div></th>
</tr><tr><td class="courseHeader" colspan="15">Deli Bar</td></tr>
<tr>
<td class="description" tabindex="0"
onclick="MenuItemClick(this,'Egg Salad','1b42bfe9-40a3-4252-8ce3-5b1aeb93872e','e39ac641-a517-4eaa-8bcf-53420ce68dd6');"
onkeypress="MenuItemKeyPress(event,this,'Egg Salad','1b42bfe9-40a3-4252-8ce3-5b1aeb93872e','e39ac641-a517-4eaa-8bcf-53420ce68dd6');"
>
Egg Salad
</td>
<td class="uom">100g</td>
<td class="nutCellOdd">203</td>
<td class="nutCellEven">15.89</td>
<td class="nutCellOdd">3.343</td>
<td class="nutCellEven">389</td>
<td class="nutCellOdd">244</td>
<td class="nutCellEven">1.19</td>
<td class="nutCellOdd">0.3</td>
<td class="nutCellEven">0.05</td>
<td class="nutCellOdd">13.75</td>
<td class="nutCellEven">0.1</td>
<td class="nutCellOdd">55</td>
<td class="nutCellEven">1.77</td>
</tr>
<tr>
<td class="description" tabindex="0"
onclick="MenuItemClick(this,'Tuna Salad','1b42bfe9-40a3-4252-8ce3-5b1aeb93872e','3f77e1a7-1c01-4cc2-b90e-a9e2a3991a52');"
>
Tuna Salad
</td>
<td class="uom">100g</td>
<td class="nutCellOdd">239</td>
<td class="nutCellEven">15.36</td>
<td class="nutCellOdd">1.636</td>
<td class="nutCellEven">34</td>
<td class="nutCellOdd">442</td>
<td class="nutCellEven">0.54</td>
<td class="nutCellOdd">0.1</td>
<td class="nutCellEven">0.19</td>
<td class="nutCellOdd">24.38</td>
<td class="nutCellEven">1.1</td>
<td class="nutCellOdd">2</td>
<td class="nutCellEven">0.87</td>
</tr>
<tr><td class="courseHeader" colspan="15">Soup</td></tr>
<tr>
<td class="description" tabindex="0"
onclick="MenuItemClick(this,'Butternut Squash Soup','1b42bfe9-40a3-4252-8ce3-5b1aeb93872e','0c07b2d1-ea9d-4844-a5be-167722d5f8ba');"
>
Butternut Squash Soup
</td>
<td class="uom">Portion</td>
<td class="nutCellOdd">122</td>
<td class="nutCellEven">1.36</td>
<td class="nutCellOdd">0.407</td>
<td class="nutCellEven">0</td>
<td class="nutCellOdd">882</td>
<td class="nutCellEven">23.08</td>
<td class="nutCellOdd">2.7</td>
<td class="nutCellEven">6.79</td>
<td class="nutCellOdd">2.71</td>
<td class="nutCellEven">0.0</td>
<td class="nutCellOdd">30</td>
<td class="nutCellEven">0.81</td>
</tr>
</table></div></div>
"""#

    static let eggSaladLabel = #"""
<table class="nutLabel" width="380px" border="0" role="presentation" > <tr><td colspan="2" class="nutLabelHeader">Nutrition Facts</td></tr> <tr><td colspan="2" class="nutLabelHeader">Valeur nutritive</td></tr> <tr><td tabindex="0" colspan="2"class="nutLabelDescription">Egg Salad</td></tr> <tr><td tabindex="0" colspan="2"class="nutLabelServing">Per 100g Serving</td></tr> <tr> <td tabindex="0" style="font-weight:bold;font-size:15px;padding-top:2px;">Calories 203</td> <td tabindex="0" style="text-align:right;font-weight:bold;padding-top:2px;">% Daily Value*</td> </tr> <tr> <td tabindex="0" class="nutLabelQty">Fat / Lipides 16g</td> <td tabindex="0" class="nutLabelPct">24%</td> </tr> <tr> <td tabindex="0" class="nutLabelQty">Saturated / satures 3g</td> <td tabindex="0" class="nutLabelPct">17%</td> </tr> <tr> <td tabindex="0" class="nutLabelQty" style="border-bottom: 1px solid #C0C0C0;">+ Trans / trans 0g</td> <td tabindex="0" style="border-bottom: 1px solid #C0C0C0;"></td> </tr> <tr> <td tabindex="0" class="nutLabelQty">Carbohydrate / Glucides 1g</td> <td tabindex="0" class="nutLabelPct"></td> </tr> <tr> <td tabindex="0" class="nutLabelQty nutLabelUL">Protein / Proteines 14g</td> <td tabindex="0" class="nutLabelPct nutLabelUL"></td> </tr> <tr> <td tabindex="0" class="nutLabelQty nutLabelULB">Sodium 244mg</td> <td tabindex="0" class="nutLabelPct nutLabelULB">11%</td> </tr> <tr><td tabindex="0" colspan="2"><b>Ingredients:</b> Pillow Pack Boiled Egg (Hard Cooked Eggs, Citric Acid, Sodium Benzoate As A Preservative.), Mayonnaise Vegan (Sunflower Oil, Water, Beet Sugar, Corn Starch, Salt, Citric Acid, Acetic Acid, Xanthan Gum, Rosemary Extract, Guar Gum, Natural Flavours, Beta-Carotene.), Celery (Celery), Salt (Taste Before Adding Salt) (Salt, Calcium Silicate, Sugar, Potassium Iodide)</td></tr> <tr><td tabindex="0" colspan="2"><b>Allergens:</b> Egg</td>></tr> <tr><td tabindex="0" colspan="2"><b>May Contain:</b> None</td></tr> <tr><td tabindex="0" colspan="2"><b>Tags:</b> Vegetarian</td></tr> </table>
"""#
}
