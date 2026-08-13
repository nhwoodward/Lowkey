import Foundation

struct VocabularyTerm: Codable, Equatable, Identifiable {
    var id: UUID
    var phrase: String
}

struct SpellingFix: Codable, Equatable, Identifiable {
    var id: UUID
    var wrong: String
    var right: String
    var count: Int
}

final class VocabularyStore {
    static let shared = VocabularyStore()
    private(set) var terms: [VocabularyTerm] = []
    private(set) var fixes: [SpellingFix] = []
    var onChange: (() -> Void)?

    private var fileURL: URL {
        Config.supportDirectory.appendingPathComponent("vocabulary.json")
    }

    private struct Snapshot: Codable {
        var terms: [VocabularyTerm]
        var fixes: [SpellingFix]
    }

    private init() { load() }

    var promptHint: String {
        let names = terms.map(\.phrase).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        return "Preferred spellings: " + names.joined(separator: ", ") + "."
    }

    func addTerm(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if terms.contains(where: { $0.phrase.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return
        }
        terms.append(VocabularyTerm(id: UUID(), phrase: trimmed))
        persist()
    }

    func removeTerm(id: UUID) {
        terms.removeAll { $0.id == id }
        persist()
    }

    func learn(wrong: String, right: String) {
        let from = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from.caseInsensitiveCompare(to) != .orderedSame else { return }
        if let index = fixes.firstIndex(where: { $0.wrong.compare(from, options: .caseInsensitive) == .orderedSame }) {
            fixes[index].right = to
            fixes[index].count += 1
        } else {
            fixes.append(SpellingFix(id: UUID(), wrong: from, right: to, count: 1))
        }
        addTerm(to)
        persist()
    }

    func removeFix(id: UUID) {
        fixes.removeAll { $0.id == id }
        persist()
    }

    func apply(to text: String) -> String {
        var result = text
        let ordered = fixes.sorted { $0.wrong.count > $1.wrong.count }
        for fix in ordered {
            result = replaceInsensitive(result, from: fix.wrong, to: fix.right)
        }
        return result
    }

    private func replaceInsensitive(_ text: String, from: String, to: String) -> String {
        // Word-boundary lookarounds so a fix like "ai" -> "AI" never rewrites
        // the inside of words such as "again".
        // Apostrophes stay inside the word so a fix for "don" cannot
        // rewrite the front of "don't".
        let pattern = "(?<![\\w'\\x{2019}])"
            + NSRegularExpression.escapedPattern(for: from)
            + "(?![\\w'\\x{2019}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: to))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        terms = decoded.terms
        fixes = decoded.fixes
    }

    private func persist() {
        let snapshot = Snapshot(terms: terms, fixes: fixes)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
        DispatchQueue.main.async { self.onChange?() }
    }
}
