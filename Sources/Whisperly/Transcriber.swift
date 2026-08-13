import Foundation

enum TranscriptOutcome: Equatable {
    case text(String)
    case silence
    case discardedNoise
}

enum Transcriber {
    static func transcribe(fileURL: URL, config: Config) throws -> TranscriptOutcome {
        let started = Date()
        let audio = try Data(contentsOf: fileURL)
        guard audio.count > 800 else { return .silence }
        // ~3 minutes of 16 kHz mono PCM plus a WAV header.
        guard audio.count < 6_000_000 else {
            AppLog.line("transcribe rejected oversized wav bytes=\(audio.count)")
            throw TranscriberError.tooLarge
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("language", config.language)
        field("response_format", "json")
        field("temperature", "0.0")
        field("no_speech_thold", "0.6")
        field("suppress_nst", "true")
        // 0 = do not keep prior transcripts as decoder prompt.
        field("max_context", "0")
        let hint = VocabularyStore.shared.promptHint
        if !hint.isEmpty {
            field("prompt", hint)
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: config.inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 120)

        let elapsed = Date().timeIntervalSince(started)
        if let resultError {
            AppLog.line(String(format: "transcribe error=%.2fs bytes=%d %@", elapsed, audio.count, resultError.localizedDescription))
            throw resultError
        }
        guard let resultData, !resultData.isEmpty else {
            AppLog.line(String(format: "transcribe empty=%.2fs bytes=%d", elapsed, audio.count))
            throw TranscriberError.emptyResponse
        }

        if let object = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            if let text = object["text"] as? String {
                let outcome = finish(text, config: config)
                let noSpeech = object["no_speech_prob"] as? Double
                AppLog.line(String(format: "transcribe ok=%.2fs bytes=%d outcome=%@ no_speech=%@", elapsed, audio.count, describe(outcome), noSpeech.map { String(format: "%.2f", $0) } ?? "-"))
                // Keep real text even when Whisper also reports a high
                // no-speech probability. Empty text is the only silence.
                return outcome
            }
            if let error = object["error"] as? String {
                AppLog.line(String(format: "transcribe server=%.2fs %@", elapsed, error))
                throw TranscriberError.server(error)
            }
        }
        if let text = String(data: resultData, encoding: .utf8) {
            let outcome = finish(text, config: config)
            AppLog.line(String(format: "transcribe text=%.2fs bytes=%d outcome=%@", elapsed, audio.count, describe(outcome)))
            return outcome
        }
        throw TranscriberError.emptyResponse
    }

    private static func describe(_ outcome: TranscriptOutcome) -> String {
        switch outcome {
        case .text(let text): return "text(\(text.count))"
        case .silence: return "silence"
        case .discardedNoise: return "noise"
        }
    }

    private static func finish(_ raw: String, config: Config) -> TranscriptOutcome {
        let text = clean(raw)
        if case .discardedNoise = text { return .discardedNoise }
        if case .silence = text { return .silence }
        guard case .text(var value) = text else { return .silence }
        value = VocabularyStore.shared.apply(to: value)
        value = SnippetStore.shared.apply(to: value)
        if config.punctuationMode == .none {
            value = value.replacingOccurrences(of: "[\\p{P}]+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? .silence : .text(value)
    }

    private static func clean(_ raw: String) -> TranscriptOutcome {
        var trimmed = raw
        for token in [
            "[BLANK_AUDIO]", "[BLANK AUDIO]", "[ Silence ]", "[silence]",
            "(silence)", "(music)", "(applause)", "[music]", "[applause]",
        ] {
            trimmed = trimmed.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if compact.isEmpty { return .silence }

        // Keep real one-word replies. Only drop phrases Whisper invents
        // when the room is quiet.
        let junk = Set([
            "thanks for watching", "thank you for watching", "thanks for listening",
            "thank you for listening", "subtitles by the amara.org community",
            "please subscribe", "like and subscribe", "please like and subscribe",
            "thanks for watching please subscribe", "see you next time",
            "the end", "uh", "um", "hmm", "mm hmm", "this is a test",
            "music", "applause", "silence", "blank audio", "you",
        ])
        if junk.contains(compact) { return .discardedNoise }

        let words = compact.split(separator: " ").map(String.init)
        if words.count <= 3, words.allSatisfy({ junk.contains($0) }) {
            return .discardedNoise
        }
        return .text(trimmed)
    }
}

enum TranscriberError: LocalizedError {
    case emptyResponse
    case tooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "Whisper returned no text."
        case .tooLarge: return "Recording is too long."
        case .server(let message): return message
        }
    }
}
