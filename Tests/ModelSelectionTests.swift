import Foundation
import XCTest
@testable import StreamAdapter

final class ModelSelectionTests: XCTestCase {
    func testSwitchUsesStableIDWhenModelsHaveTheSameDisplayName() {
        let first = UUID(), second = UUID()
        let a = ChatModel(providerID: first, name: "model-a", displayName: "Model")
        let b = ChatModel(providerID: second, name: "model-b", displayName: "Model")
        var catalog = ModelCatalog()
        catalog.update([a], for: first)
        catalog.update([b], for: second)
        XCTAssertEqual(catalog.selection(id: a.id, enabledProviderIDs: [first, second]), a)
        XCTAssertEqual(catalog.selection(id: b.id, enabledProviderIDs: [first, second]), b)
        catalog.beginLoading([first, second])
        XCTAssertEqual(catalog.selection(id: b.id, enabledProviderIDs: [first, second]), b)
        let renamed = ChatModel(providerID: second, name: "model-b", displayName: "Renamed model")
        catalog.update([renamed], for: second)
        XCTAssertEqual(catalog.selection(id: b.id, enabledProviderIDs: [first, second]), renamed)
    }

    func testFailedRefreshNeverSilentlySwitchesProviders() {
        let first = UUID(), second = UUID()
        let a = ChatModel(providerID: first, name: "a")
        let b = ChatModel(providerID: second, name: "b")
        var catalog = ModelCatalog()
        catalog.update([a], for: first)
        catalog.update([b], for: second)
        catalog.fail("Offline", for: second)
        XCTAssertNil(catalog.selection(id: b.id, enabledProviderIDs: [first, second]))
        catalog.update([b], for: second)
        XCTAssertEqual(catalog.selection(id: b.id, enabledProviderIDs: [first, second]), b)
        XCTAssertNil(catalog.selection(id: b.id, enabledProviderIDs: [first]))
    }

    func testOnlyUnselectedStateDefaultsToFirstEnabledProvider() {
        let id = UUID()
        let model = ChatModel(providerID: id, name: "first")
        var catalog = ModelCatalog()
        catalog.update([model], for: id)
        XCTAssertEqual(catalog.selection(id: nil, enabledProviderIDs: [id]), model)
        XCTAssertNil(catalog.selection(id: "removed-model", enabledProviderIDs: [id]))
        XCTAssertNil(catalog.selection(id: nil, enabledProviderIDs: []))
    }
}
