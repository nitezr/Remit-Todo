import SwiftUI

/// Back/forward history over sidebar selections, so a three-finger swipe navigates the way it does
/// in a browser.
///
/// Modelled on browser history rather than a simple "previous view" toggle: going back then
/// selecting something new discards the forward entries, which is what makes repeated back presses
/// walk a real trail instead of bouncing between two views.
///
/// The controller owns the current selection so that a history move and a click are distinguishable.
/// Doing it the other way -- observing a selection binding and guessing -- means every programmatic
/// move looks like a user action and pushes itself onto the stack, so back never terminates.
@MainActor
final class NavigationHistory: ObservableObject {
    @Published private(set) var current: SidebarSelection?
    @Published private(set) var backStack: [SidebarSelection] = []
    @Published private(set) var forwardStack: [SidebarSelection] = []

    /// Bounded so a long session cannot grow this without limit. 50 is far past what anyone
    /// reaches by swiping, and the oldest entries are the least useful.
    private let limit = 50

    init(start: SidebarSelection? = nil) {
        current = start
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// A deliberate navigation: clicking the sidebar, following a command-palette result, opening a
    /// label. Re-selecting what is already showing is not a navigation and is ignored, otherwise
    /// every redundant click would add a step you have to swipe back through.
    func visit(_ selection: SidebarSelection?) {
        guard let selection, selection != current else { return }
        if let current {
            backStack.append(current)
            if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        }
        forwardStack.removeAll()
        current = selection
    }

    @discardableResult
    func goBack() -> SidebarSelection? {
        guard let previous = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = previous
        return previous
    }

    @discardableResult
    func goForward() -> SidebarSelection? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = next
        return next
    }
}
