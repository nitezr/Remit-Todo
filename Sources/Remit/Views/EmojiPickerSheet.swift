import AppKit
import SwiftUI

/// Free-form emoji entry for a project.
///
/// A fixed palette was tried first and was the wrong call -- any emoji should be allowed. macOS
/// already has a system picker, but it can only insert into a focused text field, so this sheet
/// provides that field and opens the picker onto it. Typing or pasting directly works too.
struct EmojiPickerSheet: View {
    let projectTitle: String
    let current: String?
    var onSave: (String?) -> Void
    var onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Emoji for \(projectTitle)")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text("Paste or pick an emoji"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20))
                    .focused($fieldFocused)
                    .onSubmit(save)

                Button {
                    // Needs a focused text field to insert into, hence the explicit focus first.
                    fieldFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                }
                .help("Open the system emoji picker")
            }

            Text("Only the first character is kept.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            text = current ?? ""
            fieldFocused = true
        }
    }

    /// Keeps one grapheme cluster, so a pasted "🏠 Home" becomes "🏠" rather than a label that
    /// duplicates the project name beside it.
    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : String(trimmed.prefix(1)))
    }
}
