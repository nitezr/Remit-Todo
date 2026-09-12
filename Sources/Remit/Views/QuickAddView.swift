import SwiftUI

/// Where keyboard focus sits inside a task view. The list and the quick-add field share one
/// `@FocusState` so that plain-letter shortcuts (`j`, `e`, `t`...) only fire while the list holds
/// focus, and never swallow characters being typed into the field.
enum RemitFocusTarget: Hashable {
    case list
    case quickAdd
}

/// Single-line quick add, rendered as the last row of the task list rather than as a bar pinned
/// to the window bottom -- the add affordance belongs at the end of the tasks it appends to
/// (ROADMAP.md #71/#72/#73, where the wrong placement was corrected twice in the Electron build).
///
/// Typing `#` suggests projects and `@` suggests Reminders tags (#68, #69, both reported broken in the
/// Electron build). The suggestion list is driven off the token currently under the cursor-end of
/// the string, so it appears while typing and disappears the moment the token is completed.
struct QuickAddView: View {
    @Binding var text: String
    var isFocused: FocusState<RemitFocusTarget?>.Binding
    var focusValue: RemitFocusTarget
    var projects: [RemitProject]
    var labels: [ReminderTag]
    var onSubmit: () -> Void

    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Add task...", text: $text)
                    .textFieldStyle(.plain)
                    .focused(isFocused, equals: focusValue)
                    .onSubmit(submit)
                    .onExitCommand { isFocused.wrappedValue = .list }
                    .onChange(of: text) { highlighted = 0 }
                    .onKeyPress(.upArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = max(0, highlighted - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        highlighted = min(suggestions.count - 1, highlighted + 1)
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard !suggestions.isEmpty else { return .ignored }
                        accept(suggestions[highlighted])
                        return .handled
                    }
            }
            .padding(.vertical, 4)

            if !suggestions.isEmpty {
                suggestionList
            }
        }
    }

    private var suggestionList: some View {
        // Height-capped and scrollable: showing every match matters, but a 22-row list would push
        // the task list off screen.
        ScrollView {
            suggestionRows
        }
        .frame(maxHeight: suggestions.count > 7 ? 210 : nil)
        .fixedSize(horizontal: false, vertical: suggestions.count <= 7)
    }

    private var suggestionRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                HStack(spacing: 6) {
                    Circle()
                        .fill(suggestion.color)
                        .frame(width: 8, height: 8)
                    Text(suggestion.name)
                        .font(Theme.font(12))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(index == highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { accept(suggestion) }
            }
            Text("\u{21B9} to complete")
                .font(Theme.font(9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.leading, 24)
        .padding(.bottom, 4)
    }

    // MARK: - Token matching

    private struct Suggestion: Identifiable {
        let id: String
        let name: String
        let color: Color
        let trigger: Character
    }

    /// The `#foo` or `@foo` token being typed at the very end of the string. Only a trailing token
    /// counts -- suggesting for a token in the middle of finished text would fight the cursor.
    private var activeToken: (trigger: Character, query: String)? {
        guard let lastSpace = text.lastIndex(where: { $0 == " " }) ?? (text.isEmpty ? nil : text.startIndex) else {
            return nil
        }
        var token = String(text[lastSpace...]).trimmingCharacters(in: .whitespaces)
        if token.isEmpty { return nil }
        guard let trigger = token.first, trigger == "#" || trigger == "@" else { return nil }
        token.removeFirst()
        return (trigger, token.lowercased())
    }

    /// Everything matching, ranked. The list scrolls rather than being truncated, so a name that
    /// matches is always reachable -- a hard cap silently hid most of a 22-project list.
    private var suggestions: [Suggestion] {
        guard isFocused.wrappedValue == focusValue, let token = activeToken else { return [] }
        switch token.trigger {
        case "#":
            return projects
                .compactMap { project -> (Int, Suggestion)? in
                    guard let rank = Self.rank(project.title, query: token.query) else { return nil }
                    return (rank, Suggestion(
                        id: project.id, name: project.title,
                        color: Color(hex: project.colorHex), trigger: "#"
                    ))
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        default:
            return labels
                .compactMap { label -> (Int, Suggestion)? in
                    guard let rank = Self.rank(label.name, query: token.query) else { return nil }
                    return (rank, Suggestion(
                        id: label.id, name: label.name,
                        color: label.color, trigger: "@"
                    ))
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    /// Lower ranks sort first; nil means no match.
    ///
    /// Matching ignores a leading emoji and matches anywhere in the name, not just at the start.
    /// Project and label names here are emoji-prefixed -- "🤝 Acme", "⏳waiting" -- so prefix
    /// matching against the raw title meant `#acme` and `@waiting` matched nothing at all, which
    /// is the entire point of typing them.
    static func rank(_ name: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let stripped = searchable(name)
        if stripped.hasPrefix(query) { return 0 }
        if stripped.contains(query) { return 1 }
        // Last resort so a pasted or typed emoji still finds its own label.
        if name.lowercased().contains(query) { return 2 }
        return nil
    }

    /// The name with leading emoji and punctuation removed, lowercased, so "🤝 Acme" searches as
    /// "acme".
    static func searchable(_ name: String) -> String {
        var text = name.lowercased()
        while let first = text.first, !first.isLetter, !first.isNumber {
            text.removeFirst()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces the partial token with the full name. Spaces are stripped so the parser's
    /// `#(\S+)` / `@(\S+)` patterns still see one token.
    private func accept(_ suggestion: Suggestion) {
        guard activeToken != nil else { return }
        let compact = suggestion.name.replacingOccurrences(of: " ", with: "")
        if let lastSpace = text.lastIndex(of: " ") {
            text = String(text[...lastSpace]) + "\(suggestion.trigger)\(compact) "
        } else {
            text = "\(suggestion.trigger)\(compact) "
        }
        highlighted = 0
    }

    private func submit() {
        // Enter completes an open suggestion rather than submitting a half-typed token.
        if !suggestions.isEmpty {
            accept(suggestions[highlighted])
            return
        }
        onSubmit()
    }
}
