import AppKit
import XCTest
@testable import Remit

/// #74 asked for real remapping, and #76-#78 are three rounds of a shortcut reported as "added"
/// that turned out not to be wired to anything. These assert the binding actually resolves and
/// dispatches, not merely that a picker stored a value.
@MainActor
final class ShortcutsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "RemitShortcutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store() -> ShortcutsStore { ShortcutsStore(defaults: defaults) }

    /// Key codes are irrelevant to matching (bindings compare characters), so a nominal one is
    /// fine; the character and modifiers are what the store reads.
    private func event(_ character: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!
    }

    // MARK: - Defaults

    func testUncustomizedActionsResolveToDefaults() {
        let sut = store()

        XCTAssertEqual(sut.bindings(for: .completeTask), [KeyBinding("e")])
        XCTAssertFalse(sut.isCustomized(.completeTask))
        // Two defaults survive: dropping one to simplify remapping would be a regression.
        XCTAssertEqual(sut.bindings(for: .quickAdd), [KeyBinding("q"), KeyBinding("a")])
    }

    func testDefaultKeyDispatchesToItsAction() {
        let sut = store()

        XCTAssertEqual(sut.action(matching: event("e")), .completeTask)
        XCTAssertEqual(sut.action(matching: event("a")), .quickAdd)
        XCTAssertEqual(sut.action(matching: event("1")), .priority1)
        XCTAssertNil(sut.action(matching: event("z")), "an unbound key must not dispatch")
    }

    /// `t` is Today and `⇧T` clears the due date. They differ only by a modifier, so this is the
    /// case that breaks if modifiers are ever dropped from comparison.
    func testShiftDistinguishesOtherwiseIdenticalKeys() {
        let sut = store()

        XCTAssertEqual(sut.action(matching: event("t")), .scheduleToday)
        XCTAssertEqual(sut.action(matching: event("t", .shift)), .scheduleClear)
    }

    // MARK: - Remapping

    func testAssigningRebindsAndTakesEffectImmediately() {
        let sut = store()

        sut.assign(KeyBinding("x"), to: .completeTask)

        XCTAssertEqual(sut.action(matching: event("x")), .completeTask)
        XCTAssertNil(sut.action(matching: event("e")), "the old key must stop working")
        XCTAssertTrue(sut.isCustomized(.completeTask))
    }

    /// Stealing rather than refusing, and reporting what was stolen, so the change is never silent.
    func testAssigningAKeyAlreadyInUseStealsItAndNamesTheLoser() {
        let sut = store()

        let stolen = sut.assign(KeyBinding("e"), to: .editLabels)

        XCTAssertEqual(stolen, .completeTask)
        XCTAssertEqual(sut.action(matching: event("e")), .editLabels)
        XCTAssertFalse(
            sut.bindings(for: .completeTask).contains(KeyBinding("e")),
            "the key must actually leave the action it was taken from"
        )
    }

    /// Taking one of a two-key default leaves the other working rather than unbinding the action.
    func testStealingOneOfTwoBindingsLeavesTheOther() {
        let sut = store()

        sut.assign(KeyBinding("a"), to: .editLabels)

        XCTAssertEqual(sut.action(matching: event("a")), .editLabels)
        XCTAssertEqual(sut.action(matching: event("q")), .quickAdd)
        XCTAssertFalse(sut.isUnbound(.quickAdd))
    }

    func testResetRestoresTheDefault() {
        let sut = store()
        sut.assign(KeyBinding("x"), to: .completeTask)

        sut.reset(.completeTask)

        XCTAssertEqual(sut.bindings(for: .completeTask), [KeyBinding("e")])
        XCTAssertEqual(sut.action(matching: event("e")), .completeTask)
        XCTAssertNil(sut.action(matching: event("x")))
        XCTAssertFalse(sut.isCustomized(.completeTask))
    }

    func testResetAllClearsEveryOverride() {
        let sut = store()
        sut.assign(KeyBinding("x"), to: .completeTask)
        sut.assign(KeyBinding("y"), to: .quickAdd)

        sut.resetAll()

        XCTAssertTrue(sut.overrides.isEmpty)
        XCTAssertEqual(sut.action(matching: event("e")), .completeTask)
    }

    // MARK: - Persistence

    func testCustomBindingsSurviveRelaunch() {
        let first = store()
        first.assign(KeyBinding("x", modifiers: .shift), to: .completeTask)

        let reloaded = store()

        XCTAssertEqual(reloaded.bindings(for: .completeTask), [KeyBinding("x", modifiers: .shift)])
        XCTAssertEqual(reloaded.action(matching: event("x", .shift)), .completeTask)
    }

    /// Only overrides are stored, so an action the user never touched still follows the app's
    /// default if that default changes in a later version.
    func testUntouchedActionsAreNotWrittenToDisk() {
        let sut = store()
        sut.assign(KeyBinding("x"), to: .completeTask)

        XCTAssertEqual(Array(sut.overrides.keys), [ShortcutAction.completeTask.rawValue])
    }

    // MARK: - Display

    func testBindingsRenderAsMacOSWritesThem() {
        XCTAssertEqual(KeyBinding("k").display, "K")
        XCTAssertEqual(KeyBinding("t", modifiers: .shift).display, "⇧T")
        XCTAssertEqual(KeyBinding("z", modifiers: [.command, .shift]).display, "⇧⌘Z")
        XCTAssertEqual(KeyBinding(keyCode: 125).display, "↓")
        XCTAssertEqual(KeyBinding(keyCode: 36).display, "↩")
    }
}
