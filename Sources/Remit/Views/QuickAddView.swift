import SwiftUI

/// Plain single-line quick add for v0.1. Natural-language parsing (dates, #project, @label, pN)
/// is ROADMAP.md P0 but not yet wired -- this currently just takes the typed text as the title.
struct QuickAddView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("Add task...", text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit(onSubmit)
        }
        .padding(10)
        .background(.regularMaterial)
    }
}
