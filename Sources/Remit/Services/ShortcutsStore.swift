import AppKit
import SwiftUI

/// User-remapped key bindings, persisted in UserDefaults.
///
/// Only *overrides* are stored, not the full table: an action the user has never touched resolves
/// through `defaultBindings` at read time. That way changing a default in a later version actually
/// reaches everyone who never customised that action, instead of being masked forever by a copy of
/// the old default written out on first launch.
@MainActor
final class ShortcutsStore: ObservableObject {
    @Published private(set) var overrides: [String: [KeyBinding]] = [:]

    private let defaultsKey = "shortcuts.overrides.v1"
    private let defaults: UserDefaults

    /// `defaults` is injectable so tests exercise the real store without writing to the user's
    /// actual preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let raw = defaults.data(forKey: defaultsKey) else { return }
        // Same tolerance as MetadataStore: a binding format that stops decoding must cost the user
        // their customisations at worst, never crash or wipe anything else.
        overrides = (try? JSONDecoder().decode([String: [KeyBinding]].self, from: raw)) ?? [:]
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(encoded, forKey: defaultsKey)
    }

    func bindings(for action: ShortcutAction) -> [KeyBinding] {
        overrides[action.rawValue] ?? action.defaultBindings
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// The action a key would trigger right now, or nil. Used both to dispatch a keypress and to
    /// warn about a conflict before one is created.
    func action(matching event: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { action in
            bindings(for: action).contains { $0.matches(event) }
        }
    }

    func conflict(for binding: KeyBinding, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && bindings(for: other).contains(binding)
        }
    }

    /// Assigns `binding` to `action`, taking it from whichever action held it.
    ///
    /// Stealing rather than refusing is deliberate: refusing would mean "clear the other one
    /// first", which is a puzzle rather than a setting. The UI names whatever lost its key so the
    /// change is never silent.
    @discardableResult
    func assign(_ binding: KeyBinding, to action: ShortcutAction) -> ShortcutAction? {
        let stolenFrom = conflict(for: binding, excluding: action)
        if let stolenFrom {
            var remaining = bindings(for: stolenFrom).filter { $0 != binding }
            overrides[stolenFrom.rawValue] = remaining
            remaining = []
        }
        overrides[action.rawValue] = [binding]
        persist()
        return stolenFrom
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
        persist()
    }

    func resetAll() {
        overrides.removeAll()
        persist()
    }

    /// An action whose every binding has been taken by something else. Surfaced in the UI so a
    /// silently unreachable action is visible rather than merely broken.
    func isUnbound(_ action: ShortcutAction) -> Bool {
        bindings(for: action).isEmpty
    }
}
