import SwiftUI

// The Settings Vocabulary page. Both stores publish, so rows added from the
// History window appear here while Settings is open.
struct VocabularySettings: View {
    @ObservedObject private var vocabulary = VocabularyStore.shared
    @ObservedObject private var snippets = SnippetStore.shared

    var body: some View {
        Form {
            Section {
                PhraseTable(
                    columns: ("Heard", "Write as"),
                    rows: vocabulary.entries.map { PhraseRow(id: $0.id, left: $0.heard, right: $0.writeAs) },
                    empty: "No replacements",
                    noun: "replacement",
                    requiresRight: false,
                    add: { vocabulary.add(heard: $0, writeAs: $1) },
                    remove: vocabulary.removeEntry(id:)
                )
            } header: {
                Text("Replacements")
            } footer: {
                Text("Lowkey writes the replacement whenever it hears the phrase. Leave Write as empty to teach Whisper a spelling.")
            }

            Section {
                PhraseTable(
                    columns: ("Say", "Insert"),
                    rows: snippets.items.map { PhraseRow(id: $0.id, left: $0.trigger, right: $0.expansion) },
                    empty: "No snippets",
                    noun: "snippet",
                    requiresRight: true,
                    add: { snippets.add(trigger: $0, expansion: $1) },
                    remove: snippets.remove(id:)
                )
            } header: {
                Text("Snippets")
            } footer: {
                Text("Say a snippet on its own or at the start of a dictation, and Lowkey inserts its text.")
            }
        }
    }
}

private struct PhraseRow: Identifiable, Hashable {
    let id: UUID
    let left: String
    let right: String
}

// A two-column table with an add bar: select rows and press Delete, use the
// minus button, or the context menu to remove them.
private struct PhraseTable: View {
    let columns: (String, String)
    let rows: [PhraseRow]
    let empty: String
    let noun: String
    let requiresRight: Bool
    let add: (String, String) -> Void
    let remove: (UUID) -> Void

    @State private var selection = Set<UUID>()
    @State private var left = ""
    @State private var right = ""
    @FocusState private var leftFocused: Bool

    private var canAdd: Bool {
        !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresRight || !right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn(columns.0) { cell($0.left) }
            TableColumn(columns.1) { cell($0.right) }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .scrollDisabled(false)
        .frame(height: 148)
        .overlay {
            if rows.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("Delete") { delete(ids) }
            }
        }
        .onDeleteCommand { delete(selection) }

        HStack(spacing: 8) {
            Button { delete(selection) } label: {
                Image(systemName: "minus").frame(width: 12, height: 16)
            }
            .disabled(selection.isEmpty)
            .help("Remove Selected")
            .accessibilityLabel("Remove selected \(noun)")
            TextField(columns.0, text: $left, prompt: Text(columns.0))
                .focused($leftFocused)
            TextField(columns.1, text: $right, prompt: Text(columns.1))
            Button("Add", action: submit)
                .disabled(!canAdd)
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .onSubmit(submit)
    }

    // Multi-line snippets read on one line; the tooltip keeps the full text.
    private func cell(_ text: String) -> some View {
        Text(text.replacingOccurrences(of: "\n", with: " ")).help(text)
    }

    private func submit() {
        guard canAdd else { return }
        add(left, right)
        left = ""
        right = ""
        leftFocused = true
    }

    private func delete(_ ids: Set<UUID>) {
        ids.forEach(remove)
        selection.subtract(ids)
    }
}
