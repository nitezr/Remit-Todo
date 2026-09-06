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
/// Typing `#` suggests projects and `@` suggests labels (#68, #69, both reported broken in the
/// Electron build). The suggestion list is driven off the token currently under the cursor-end of
/// the string, so it appears while typing and disappears the moment the token is completed.
struct QuickAddView: View {
    @Binding var text: String
    var isFocused: FocusState<RemitFocusTarget?>.Binding
    var focusValue: RemitFocusTarget
    var projects: [RemitProject]
    var labels: [RemitLabel]
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                HStack(spacing: 6) {
                    Circle()
                        .fill(suggestion.color)
                        .frame(width: 8, height: 8)
                    Text(suggestion.name)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(index == highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { accept(suggestion) }
            }
            Text("\u{21B9} to complete")
                .font(.system(size: 9))
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

    private var suggestions: [Suggestion] {
        guard isFocused.wrappedValue == focusValue, let token = activeToken else { return [] }
        switch token.trigger {
        case "#":
            return projects
                .filter { token.query.isEmpty || $0.title.lowercased().hasPrefix(token.query) }
                .prefix(6)
                .map { Suggestion(id: $0.id, name: $0.title, color: Color(hex: $0.colorHex), trigger: "#") }
        default:
            return labels
                .filter { token.query.isEmpty || $0.name.lowercased().hasPrefix(token.query) }
                .prefix(6)
                .map { Suggestion(id: $0.id, name: $0.name, color: $0.color.swiftUIColor, trigger: "@") }
        }
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
