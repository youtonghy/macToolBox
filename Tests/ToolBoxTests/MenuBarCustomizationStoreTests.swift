import XCTest
@testable import ToolBoxCore

final class MenuBarCustomizationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarCustomizationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> MenuBarCustomizationStore {
        MenuBarCustomizationStore(defaults: defaults)
    }

    // MARK: - Defaults

    func testMissingConfigurationLoadsDefaultLayout() {
        XCTAssertEqual(
            makeStore().load(),
            MenuBarLayoutConfiguration.default()
        )
    }

    func testDefaultLayoutMatchesShippedOrderAndVisibility() {
        let configuration = MenuBarLayoutConfiguration.default()

        XCTAssertEqual(
            configuration.entries.map(\.id),
            MenuBarElementID.defaultOrder
        )
        XCTAssertTrue(configuration.entries.allSatisfy(\.isVisible))
    }

    // MARK: - Round trips

    func testConfigurationRoundTripsThroughDefaults() {
        let store = makeStore()
        let configuration = MenuBarLayoutConfiguration(entries: [
            MenuBarElementEntry(id: .wifiSignal),
            MenuBarElementEntry(id: .chipPower, isVisible: false),
            MenuBarElementEntry(id: .quickControls),
            MenuBarElementEntry(id: .appAudio),
            MenuBarElementEntry(id: .displayControl, isVisible: false),
            MenuBarElementEntry(id: .cableStatus),
        ])

        store.save(configuration)

        XCTAssertEqual(store.load(), configuration)
    }

    func testSaveNormalizesBeforePersisting() {
        let store = makeStore()

        store.save(MenuBarLayoutConfiguration(entries: [
            MenuBarElementEntry(id: .wifiSignal),
            MenuBarElementEntry(id: .wifiSignal, isVisible: false),
        ]))

        XCTAssertEqual(store.load().entries.map(\.id), [.wifiSignal, .chipPower, .appAudio, .cableStatus, .displayControl, .quickControls])
    }

    // MARK: - Dirty payload handling

    func testCorruptPayloadFallsBackToDefaultAndKeepsBackup() throws {
        defaults.set(Data("not a menu bar layout".utf8), forKey: MenuBarCustomizationStore.defaultsKey)

        let configuration = makeStore().load()

        XCTAssertEqual(configuration, MenuBarLayoutConfiguration.default())
        let backupKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(MenuBarCustomizationStore.defaultsKey).corrupt-") }
        XCTAssertEqual(backupKeys.count, 1)
    }

    func testEmptyArrayPayloadRestoresAllElementsInDefaultOrder() {
        defaults.set(Data("[]".utf8), forKey: MenuBarCustomizationStore.defaultsKey)

        XCTAssertEqual(
            makeStore().load(),
            MenuBarLayoutConfiguration.default()
        )
    }

    // MARK: - Unknown / duplicate / missing identifiers

    func testUnknownIdentifiersAreDropped() {
        let payload = #"""
        [
          {"id": "futureModule", "isVisible": true},
          {"id": "wifiSignal", "isVisible": false}
        ]
        """#
        defaults.set(Data(payload.utf8), forKey: MenuBarCustomizationStore.defaultsKey)

        let configuration = makeStore().load()

        XCTAssertFalse(configuration.entries.contains { $0.id.rawValue == "futureModule" })
        XCTAssertEqual(configuration.entry(for: .wifiSignal)?.isVisible, false)
    }

    func testDuplicateEntriesKeepFirstOccurrence() {
        let payload = #"""
        [
          {"id": "wifiSignal", "isVisible": false},
          {"id": "wifiSignal", "isVisible": true}
        ]
        """#
        defaults.set(Data(payload.utf8), forKey: MenuBarCustomizationStore.defaultsKey)

        XCTAssertEqual(makeStore().load().entry(for: .wifiSignal)?.isVisible, false)
    }

    func testMissingIdentifiersAreAppendedInDefaultOrder() {
        let payload = #"""
        [
          {"id": "quickControls", "isVisible": false},
          {"id": "wifiSignal", "isVisible": true}
        ]
        """#
        defaults.set(Data(payload.utf8), forKey: MenuBarCustomizationStore.defaultsKey)

        XCTAssertEqual(
            makeStore().load().entries.map(\.id),
            [.quickControls, .wifiSignal, .chipPower, .appAudio, .cableStatus, .displayControl]
        )
    }

    func testLegacyPayloadWithoutVisibilityFlagDefaultsToVisible() {
        let payload = #"""
        [{"id": "chipPower"}, {"id": "appAudio", "isVisible": false}]
        """#
        defaults.set(Data(payload.utf8), forKey: MenuBarCustomizationStore.defaultsKey)

        let configuration = makeStore().load()

        XCTAssertEqual(configuration.entry(for: .chipPower)?.isVisible, true)
        XCTAssertEqual(configuration.entry(for: .appAudio)?.isVisible, false)
    }

    // MARK: - Model editing

    @MainActor
    func testModelTogglesVisibilityAndPersists() {
        let model = MenuBarCustomizationModel(store: makeStore())

        model.setVisible(false, for: .appAudio)

        XCTAssertFalse(model.isVisible(.appAudio))
        XCTAssertEqual(makeStore().load().entry(for: .appAudio)?.isVisible, false)

        model.setVisible(true, for: .appAudio)

        XCTAssertTrue(model.isVisible(.appAudio))
        XCTAssertEqual(makeStore().load().entry(for: .appAudio)?.isVisible, true)
    }

    @MainActor
    func testModelMovesElementAndPersistsOrder() {
        let model = MenuBarCustomizationModel(store: makeStore())

        model.move(fromOffsets: IndexSet(integer: 5), toOffset: 0)

        XCTAssertEqual(model.entries.first?.id, .quickControls)
        XCTAssertEqual(
            makeStore().load().entries.map(\.id),
            model.entries.map(\.id)
        )
    }

    @MainActor
    func testModelResetRestoresDefaultLayout() {
        let model = MenuBarCustomizationModel(store: makeStore())
        model.setVisible(false, for: .chipPower)
        model.move(fromOffsets: IndexSet(integer: 5), toOffset: 0)
        XCTAssertFalse(model.isDefaultLayout)

        model.resetToDefault()

        XCTAssertEqual(model.entries, MenuBarLayoutConfiguration.default().entries)
        XCTAssertTrue(model.isDefaultLayout)
        XCTAssertEqual(makeStore().load(), MenuBarLayoutConfiguration.default())
    }

    // MARK: - Runtime projection

    func testProjectionRequiresUserEnabledAndRuntimeAvailable() {
        let entries = MenuBarElementID.defaultOrder.map { MenuBarElementEntry(id: $0) }
        let context = MenuBarElementRuntimeContext(
            cableItemCount: 2,
            audioRowCount: 3,
            isAudioLiteMode: false,
            hasExternalDisplay: true,
            showsColorPreset: true
        )

        XCTAssertEqual(
            MenuBarElementProjection.visibleElements(from: entries, context: context),
            MenuBarElementID.defaultOrder
        )
    }

    func testProjectionFiltersUserHiddenElementsInConfiguredOrder() {
        var entries = MenuBarElementID.defaultOrder.map { MenuBarElementEntry(id: $0) }
        entries.swapAt(0, 5) // quickControls first, chipPower last
        entries[entries.firstIndex { $0.id == .wifiSignal }!].isVisible = false

        let visible = MenuBarElementProjection.visibleElements(
            from: entries,
            context: MenuBarElementRuntimeContext(
                cableItemCount: 1,
                audioRowCount: 2,
                isAudioLiteMode: false,
                hasExternalDisplay: true,
                showsColorPreset: false
            )
        )

        XCTAssertEqual(visible, [.quickControls, .appAudio, .cableStatus, .displayControl, .chipPower])
    }

    func testProjectionHidesElementsWithoutRuntimeDataButKeepsConfiguration() {
        let entries = MenuBarElementID.defaultOrder.map { MenuBarElementEntry(id: $0) }
        let offlineContext = MenuBarElementRuntimeContext(
            cableItemCount: 0,
            audioRowCount: 0,
            isAudioLiteMode: false,
            hasExternalDisplay: false,
            showsColorPreset: false
        )

        XCTAssertEqual(
            MenuBarElementProjection.visibleElements(from: entries, context: offlineContext),
            [.chipPower, .wifiSignal, .quickControls]
        )

        // The same configuration returns hidden elements to their configured
        // position once runtime data is available again.
        let onlineContext = MenuBarElementRuntimeContext(
            cableItemCount: 1,
            audioRowCount: 2,
            isAudioLiteMode: false,
            hasExternalDisplay: true,
            showsColorPreset: true
        )

        XCTAssertEqual(
            MenuBarElementProjection.visibleElements(from: entries, context: onlineContext),
            MenuBarElementID.defaultOrder
        )
    }

    func testProjectionWithEverythingDisabledYieldsNoElements() {
        let entries = MenuBarElementID.defaultOrder.map { MenuBarElementEntry(id: $0, isVisible: false) }

        XCTAssertTrue(
            MenuBarElementProjection.visibleElements(
                from: entries,
                context: MenuBarElementRuntimeContext()
            ).isEmpty
        )
    }
}
