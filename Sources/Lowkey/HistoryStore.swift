import Foundation

struct HistoryItem: Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var duration: TimeInterval
    var language: String
    var audioFileName: String?

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return Config.historyDirectory.appendingPathComponent(audioFileName)
    }
}

final class HistoryStore {
    static let shared = HistoryStore()
    private let limit = 80
    private(set) var items: [HistoryItem] = []
    private var listeners: [UUID: () -> Void] = [:]
    private var legacyOnChange: UUID?

    var onChange: (() -> Void)? {
        get { nil }
        set {
            if let id = legacyOnChange {
                stopObserving(id)
                legacyOnChange = nil
            }
            if let newValue {
                legacyOnChange = observe(newValue)
            }
        }
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private var fileURL: URL {
        Config.supportDirectory.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    func add(text: String, duration: TimeInterval, language: String, audioURL: URL?) {
        var name: String?
        if let audioURL {
            let destName = UUID().uuidString + ".wav"
            let dest = Config.historyDirectory.appendingPathComponent(destName)
            if keepAudio(from: audioURL, to: dest) {
                name = destName
            }
        }
        let item = HistoryItem(
            id: UUID(),
            text: text,
            createdAt: Date(),
            duration: duration,
            language: language,
            audioFileName: name
        )
        items.insert(item, at: 0)
        trim()
        persist()
    }

    private func keepAudio(from source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: source, to: dest)
            return fm.fileExists(atPath: dest.path)
        } catch {
            do {
                try fm.copyItem(at: source, to: dest)
                return fm.fileExists(atPath: dest.path)
            } catch {
                return false
            }
        }
    }

    func updateText(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
        persist()
    }

    func delete(id: UUID) {
        if let item = items.first(where: { $0.id == id }), let url = item.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == id }
        persist()
    }

    private func trim() {
        if items.count <= limit { return }
        for extra in items.suffix(from: limit) {
            if let url = extra.audioURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        items = Array(items.prefix(limit))
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([HistoryItem].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        DispatchQueue.main.async {
            self.listeners.values.forEach { $0() }
        }
    }
}
