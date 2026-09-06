import SwiftUI

/// Manage Remit's labels: create, rename, recolour, delete.
///
/// Labels are entirely Remit's own -- Apple ships no API for Reminders tags (see Models/Label.swift
/// and ROADMAP.md), so this page is the only place they can be edited. The Electron build shipped a
/// label section the user couldn't even read (#42), so sizing and contrast are deliberate here:
/// 13pt names, full-strength chip colours, and a swatch large enough to hit.
struct LabelsPage: View {
    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var remindersService: RemindersService
    @Binding var selection: SidebarSelection?

    @State private var newLabelName = ""
    @State private var renamingID: String?
    @State private var draftName = ""

    var body: some View {
        List {
            SwiftUI.Section("Labels") {
                ForEach(metadataStore.labels) { label in
                    row(label)
                }

                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                    TextField("New label", text: $newLabelName)
                        .textFieldStyle(.plain)
                        .onSubmit(createLabel)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
        .navigationTitle("Filters & Labels")
        .navigationSubtitle(metadataStore.labels.isEmpty ? "No labels yet" : "\(metadataStore.labels.count) labels")
    }

    private func row(_ label: RemitLabel) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(LabelColor.allCases, id: \.self) { color in
                    Button {
                        metadataStore.setColor(color, forLabel: label.id)
                    } label: {
                        Label(color.rawValue.capitalized, systemImage: "circle.fill")
                    }
                }
            } label: {
                Circle()
                    .fill(label.color.swiftUIColor)
                    .frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)

            if renamingID == label.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { commitRename(label) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(label.name)
                    .font(.system(size: 13))
                Spacer()
                Text("\(taskCount(label))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { selection = .label(label.id) }
        .contextMenu {
            Button("Show Tasks") { selection = .label(label.id) }
            Button("Rename") {
                draftName = label.name
                renamingID = label.id
            }
            // Deleting a label only removes the label; the tasks carrying it are untouched.
            Button("Delete Label", role: .destructive) {
                metadataStore.removeLabel(label.id)
            }
        }
    }

    private func taskCount(_ label: RemitLabel) -> Int {
        remindersService.tasks.filter { task in
            !task.isCompleted && metadataStore.labels(forTask: task.id).contains { $0.id == label.id }
        }.count
    }

    private func createLabel() {
        let name = newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        metadataStore.addLabel(name: name)
        newLabelName = ""
    }

    private func commitRename(_ label: RemitLabel) {
        metadataStore.renameLabel(label.id, to: draftName)
        renamingID = nil
    }
}
