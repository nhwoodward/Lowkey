import Combine
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

// One row of the Settings vocabulary table: a fix, or a spelling no fix writes.
struct VocabularyEntry: Equatable, Identifiable {
    var id: UUID
    var heard: String
    var writeAs: String
}

final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()
    @Published private(set) var terms: [VocabularyTerm] = []
    @Published private(set) var fixes: [SpellingFix] = []

    private let fileURL: URL

    private struct Snapshot: Codable {
        var terms: [VocabularyTerm]
        var fixes: [SpellingFix]
    }

    init(directory: URL = Config.supportDirectory) {
        fileURL = directory.appendingPathComponent("vocabulary.json")
        load()
    }

    var entries: [VocabularyEntry] {
        let standalone = terms.filter { term in
            !fixes.contains { $0.right.caseInsensitiveCompare(term.phrase) == .orderedSame }
        }
        return fixes.map { VocabularyEntry(id: $0.id, heard: $0.wrong, writeAs: $0.right) }
            + standalone.map { VocabularyEntry(id: $0.id, heard: $0.phrase, writeAs: "") }
    }

    var promptHint: String {
        let names = terms.map(\.phrase).filter { !$0.isEmpty }.prefix(24)
        guard !names.isEmpty else { return "" }
        var hint = "Preferred spellings: " + names.joined(separator: ", ") + "."
        if hint.count > 400 {
            hint = String(hint.prefix(400))
        }
        return hint
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

    // An explicit Settings entry. Unlike learn, a case-only replacement is
    // deliberate here ("github" -> "GitHub"), and re-adding a phrase replaces
    // its row instead of leaving the old spelling behind.
    func add(heard: String, writeAs: String) {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = writeAs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else { return }
        guard !to.isEmpty, to != from else { return addTerm(from) }
        if let existing = fixes.first(where: { $0.wrong.caseInsensitiveCompare(from) == .orderedSame }) {
            removeEntry(id: existing.id)
        }
        fixes.append(SpellingFix(id: UUID(), wrong: from, right: to, count: 1))
        // The heard form is no longer a spelling to prefer.
        terms.removeAll {
            $0.phrase.caseInsensitiveCompare(from) == .orderedSame || $0.phrase.caseInsensitiveCompare(to) == .orderedSame
        }
        terms.append(VocabularyTerm(id: UUID(), phrase: to))
        persist()
    }

    // A fix row owns the spelling it writes, so that term goes with it unless
    // another fix still writes it.
    func removeEntry(id: UUID) {
        if let fix = fixes.first(where: { $0.id == id }) {
            fixes.removeAll { $0.id == id }
            if !fixes.contains(where: { $0.right.caseInsensitiveCompare(fix.right) == .orderedSame }) {
                terms.removeAll { $0.phrase.caseInsensitiveCompare(fix.right) == .orderedSame }
            }
        } else {
            terms.removeAll { $0.id == id }
        }
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
    }
}
