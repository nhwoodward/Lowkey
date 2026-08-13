import AppKit
import Foundation

enum DictationHotkey: String, CaseIterable, Codable {
    case rightCommand
    case leftCommand
    case rightOption
    case function

    var title: String {
        switch self {
        case .rightCommand: return "Right Command"
        case .leftCommand: return "Left Command"
        case .rightOption: return "Right Option"
        case .function: return "Fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightOption: return 61
        case .function: return 63
        }
    }

    var requiredFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand, .leftCommand: return .command
        case .rightOption: return .option
        case .function: return .function
        }
    }
}

enum ClipboardBehavior: String, Codable, CaseIterable {
    case always
    case ifPasteFails
    case never

    var title: String {
        switch self {
        case .always: return "Always"
        case .ifPasteFails: return "If paste fails"
        case .never: return "Never"
        }
    }
}

enum PunctuationMode: String, Codable, CaseIterable {
    case automatic
    case none

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .none: return "Off"
        }
    }
}

struct Config: Codable {
    var modelPath: String
    var whisperServerPath: String
    var host: String
    var port: Int
    var language: String
    var threads: Int
    var hotkey: DictationHotkey
    var showBarAlways: Bool
    var restoreClipboard: Bool
    var playSounds: Bool
    var hideFromDock: Bool
    var startAtLogin: Bool
    var autoPauseAudio: Bool
    var microphoneUID: String
    var clipboardBehavior: ClipboardBehavior
    var punctuationMode: PunctuationMode
    var appearance: AppAppearance

    static let languages: [(String, String)] = [
        ("en", "English"),
        ("auto", "Auto detect"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
    ]

    static var historyDirectory: URL {
        let url = supportDirectory.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let loopbackHost = "127.0.0.1"

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperly", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static var modelsDirectory: URL {
        let url = supportDirectory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var logsDirectory: URL {
        let url = supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var tmpDirectory: URL {
        let url = supportDirectory.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var fileURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            if decoded.threads < 4 {
                var upgraded = decoded
                upgraded.threads = 4
                upgraded.save()
                return upgraded
            }
            return decoded
        }
        let defaults = Config.makeDefault()
        defaults.save()
        return defaults
    }

    init(
        modelPath: String,
        whisperServerPath: String,
        host: String,
        port: Int,
        language: String,
        threads: Int,
        hotkey: DictationHotkey,
        showBarAlways: Bool,
        restoreClipboard: Bool,
        playSounds: Bool,
        hideFromDock: Bool,
        startAtLogin: Bool,
        autoPauseAudio: Bool,
        microphoneUID: String,
        clipboardBehavior: ClipboardBehavior,
        punctuationMode: PunctuationMode,
        appearance: AppAppearance
    ) {
        self.modelPath = modelPath
        self.whisperServerPath = whisperServerPath
        self.host = host
        self.port = port
        self.language = language
        self.threads = threads
        self.hotkey = hotkey
        self.showBarAlways = showBarAlways
        self.restoreClipboard = restoreClipboard
        self.playSounds = playSounds
        self.hideFromDock = hideFromDock
        self.startAtLogin = startAtLogin
        self.autoPauseAudio = autoPauseAudio
        self.microphoneUID = microphoneUID
        self.clipboardBehavior = clipboardBehavior
        self.punctuationMode = punctuationMode
        self.appearance = appearance
    }

    static func makeDefault() -> Config {
        Config(
            modelPath: modelsDirectory.appendingPathComponent("ggml-small.bin").path,
            whisperServerPath: "/opt/homebrew/bin/whisper-server",
            host: "127.0.0.1",
            port: 18789,
            language: "en",
            threads: 4,
            hotkey: .rightCommand,
            showBarAlways: false,
            restoreClipboard: false,
            playSounds: true,
            hideFromDock: true,
            startAtLogin: false,
            autoPauseAudio: false,
            microphoneUID: "",
            clipboardBehavior: .ifPasteFails,
            punctuationMode: .automatic,
            appearance: .system
        )
    }

    init(from decoder: Decoder) throws {
        let fallback = Config.makeDefault()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? fallback.modelPath
        whisperServerPath = try c.decodeIfPresent(String.self, forKey: .whisperServerPath) ?? fallback.whisperServerPath
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? fallback.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? fallback.language
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? fallback.threads
        hotkey = try c.decodeIfPresent(DictationHotkey.self, forKey: .hotkey) ?? fallback.hotkey
        showBarAlways = try c.decodeIfPresent(Bool.self, forKey: .showBarAlways) ?? fallback.showBarAlways
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? fallback.restoreClipboard
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? fallback.playSounds
        hideFromDock = try c.decodeIfPresent(Bool.self, forKey: .hideFromDock) ?? fallback.hideFromDock
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? fallback.startAtLogin
        autoPauseAudio = try c.decodeIfPresent(Bool.self, forKey: .autoPauseAudio) ?? fallback.autoPauseAudio
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID) ?? fallback.microphoneUID
        if let stored = try c.decodeIfPresent(ClipboardBehavior.self, forKey: .clipboardBehavior) {
            clipboardBehavior = stored
        } else if restoreClipboard {
            clipboardBehavior = .ifPasteFails
        } else {
            clipboardBehavior = fallback.clipboardBehavior
        }
        punctuationMode = try c.decodeIfPresent(PunctuationMode.self, forKey: .punctuationMode) ?? fallback.punctuationMode
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? fallback.appearance
    }

    var engineIdentity: String {
        "\(whisperServerPath)|\(modelPath)|\(bindHost)|\(bindPort)|\(language)|\(effectiveThreads)"
    }

    // Never bind or POST off-box, even if config.json was edited by hand.
    var bindHost: String { Self.loopbackHost }

    var bindPort: Int {
        let raw = port == 0 ? 18789 : port
        return min(65_535, max(raw, 1_024))
    }

    // Old builds stored threads=2. The server default is 4, and this
    // machine reports 6 logical cores. Two threads makes short clips wait.
    var effectiveThreads: Int {
        min(8, max(threads < 4 ? 4 : threads, 2))
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    var baseURL: URL {
        URL(string: "http://\(bindHost):\(bindPort)")!
    }

    var inferenceURL: URL {
        baseURL.appendingPathComponent("inference")
    }
}
