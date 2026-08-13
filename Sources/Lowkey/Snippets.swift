import Foundation

struct DictationSnippet: Codable, Equatable, Identifiable {
    var id: UUID
    var trigger: String
    var expansion: String
}

final class SnippetStore {
    static let shared = SnippetStore()
    private(set) var items: [DictationSnippet] = []
    var onChange: (() -> Void)?

    private var fileURL: URL {
        Config.supportDirectory.appendingPathComponent("snippets.json")
    }

    private init() { load() }

    func add(trigger: String, expansion: String) {
        let key = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.trigger.compare(key, options: .caseInsensitive) == .orderedSame }) {
            items[index].expansion = value
        } else {
            items.append(DictationSnippet(id: UUID(), trigger: key, expansion: value))
        }
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func apply(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = items.sorted { $0.trigger.count > $1.trigger.count }
        for item in ordered {
            if trimmed.compare(item.trigger, options: .caseInsensitive) == .orderedSame {
                return item.expansion
            }
            // Prefix expansion only at a word boundary, so a "sig" trigger
            // never fires on "significant progress".
            if trimmed.lowercased().hasPrefix(item.trigger.lowercased()) {
                let rest = trimmed.dropFirst(item.trigger.count)
                if let next = rest.unicodeScalars.first,
                   !CharacterSet.alphanumerics.contains(next),
                   next != "_",
                   next != "'",
                   next != "\u{2019}" {
                    return item.expansion + rest
                }
            }
        }
        return text
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationSnippet].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        DispatchQueue.main.async { self.onChange?() }
    }
}
