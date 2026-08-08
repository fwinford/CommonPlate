import XCTest
@testable import CommonPlateios

/// Proves the Picker's data source decodes from the bundled shared catalog
/// (`Resources/SupportedVendors.json`, a symlink to the repo-root
/// `shared/vendors.json` the backend also reads — see
/// `src/supportedVendors.test.ts`), preserving the exact accepted 11 entries
/// rather than a second hand-maintained Swift list.
final class SupportedVendorCatalogTests: XCTestCase {
    func testDecodesExactlyTheAcceptedElevenSpotsInOrder() {
        let names = SupportedVendorCatalog.diningSpots.map(\.name)

        XCTAssertEqual(names, [
            "Crave NYU",
            "Dunkin' at U-Hall",
            "Jasper Kane Cafe",
            "Peet's Coffee at Kimmel",
            "Cafe 370",
            "Flavor Lab by NYU Eats",
            "Cafe 181",
            "Upstein - Vedge Craft & Smoothie Lab",
            "Upstein - Shareables, Cluckstein, Slidestein & Taqueria",
            "True Burger at UHall",
            "Palladium",
        ])
    }

    func testEveryEntryHasAnAddress() {
        for spot in SupportedVendorCatalog.diningSpots {
            XCTAssertFalse((spot.address ?? "").isEmpty, "\(spot.name) is missing its address")
        }
    }
}
