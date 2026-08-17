import Foundation

extension FixedWidthInteger {
    var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}

enum TranscriptOutcome: Equatable {
    case text(String)
    case silence
    case discardedNoise
}

enum Transcriber {
    private static let touchLock = NSLock()
    private static var lastEngineTouch = Date.distantPast

    private static func touchEngine() {
        touchLock.lock()
        lastEngineTouch = Date()
        touchLock.unlock()
    }

    // Fired when recording STARTS: a tiny silent inference re-establishes the
    // keep-alive connection, revives the engine's Metal residency (released
    // after 180s idle), and absorbs any first-request-after-idle cost while
    // the user is still speaking. By release time the pipe is hot.
    static func warmUp(config: Config) {
        // Parakeet stays resident on the Neural Engine; only the whisper
        // HTTP path benefits from pre-heating.
        if config.engine == .parakeet, ParakeetEngine.shared.ready { return }
        touchLock.lock()
        let recent = Date().timeIntervalSince(lastEngineTouch) < 20
        if !recent { lastEngineTouch = Date() }
        touchLock.unlock()
        if recent { return }

        // 0.2s of 16 kHz mono silence, built in memory: 44-byte WAV header
        // plus 3200 zero samples.
        let sampleBytes = 3200 * 2
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.append(UInt32(36 + sampleBytes).littleEndianData)
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(UInt32(16).littleEndianData)
        wav.append(UInt16(1).littleEndianData)          // PCM
        wav.append(UInt16(1).littleEndianData)          // mono
        wav.append(UInt32(16000).littleEndianData)      // sample rate
        wav.append(UInt32(32000).littleEndianData)      // byte rate
        wav.append(UInt16(2).littleEndianData)          // block align
        wav.append(UInt16(16).littleEndianData)         // bits
        wav.append(Data("data".utf8))
        wav.append(UInt32(sampleBytes).littleEndianData)
        wav.append(Data(count: sampleBytes))

        let boundary = "Warm-\(UUID().uuidString)"
        var body = Data()
        // Minimum encoder context: the warmup must be near-free, or it can
        // queue AHEAD of the real request on the server's single inference
        // lane and add latency instead of removing it.
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio_ctx\"\r\n\r\n128\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"warm.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: config.inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = body
        Metrics.session.dataTask(with: request) { _, _, _ in
            AppLog.line("engine warmup done")
        }.resume()
    }

    static func transcribe(fileURL: URL, config: Config) throws -> TranscriptOutcome {
        defer { touchEngine() }
        let started = Date()
        let audio = try Data(contentsOf: fileURL)
        guard audio.count > 800 else { return .silence }
        // ~3 minutes of 16 kHz mono PCM plus a WAV header.
        guard audio.count < 6_000_000 else {
            AppLog.line("transcribe rejected oversized wav bytes=\(audio.count)")
            throw TranscriberError.tooLarge
        }

        // Primary path: Parakeet on the Neural Engine. Any failure falls
        // through to whisper below, whose own recovery can respawn the
        // server on demand.
        if config.engine == .parakeet, ParakeetEngine.shared.ready {
            do {
                let raw = try ParakeetEngine.shared.transcribe(fileURL: fileURL)
                let outcome = finish(raw, config: config)
                let elapsed = Date().timeIntervalSince(started)
                AppLog.line(String(
                    format: "transcribe ok=%.2fs bytes=%d outcome=%@ engine=parakeet",
                    elapsed, audio.count, describe(outcome)))
                return outcome
            } catch {
                AppLog.line("parakeet transcribe failed, falling back to whisper: \(error.localizedDescription)")
            }
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
        // Greedy decode: ~20% faster than beam search, identical output on
        // clean dictation. Temperature fallback still guards bad decodes.
        field("beam_size", "1")
        field("best_of", "1")
        // Whisper pads every clip to a 30s window and encodes all of it, so
        // short dictations pay a long clip's encode. Cropping the encoder
        // context to the real audio length (plus margin) cut short-clip
        // latency 1.6x in A/B with byte-identical text.
        let seconds = Double(max(0, audio.count - 44)) / 32_000
        let audioCtx = max(128, Int((seconds / 30.0 * 1500).rounded(.up)) + 64)
        if audioCtx < 1500 {
            field("audio_ctx", String(audioCtx))
        }
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
        Metrics.session.dataTask(with: request) { data, _, error in
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

    // Diagnostic instrumentation: splits every request into connect / send /
    // server-wait / receive and records the 1-minute load average, so a slow
    // dictation shows WHERE the time went instead of one opaque number.
    private final class Metrics: NSObject, URLSessionTaskDelegate {
        static let shared = Metrics()
        static let session = URLSession(
            configuration: .default,
            delegate: Metrics.shared,
            delegateQueue: nil
        )

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            // .last, not .first: internal retries append transactions and the
            // final one is the exchange that actually reached the server.
            guard let t = metrics.transactionMetrics.last else { return }
            func ms(_ a: Date?, _ b: Date?) -> String {
                guard let a, let b else { return "-" }
                return String(format: "%.0f", b.timeIntervalSince(a) * 1000)
            }
            // preflight = task resume until bytes first move for this
            // exchange. The 23.89s dictation with a 2ms server wait hid its
            // stall exactly here, invisible to per-transaction phases.
            let preflight = ms(metrics.taskInterval.start, t.fetchStartDate)
            var loads = [Double](repeating: 0, count: 1)
            getloadavg(&loads, 1)
            AppLog.line(
                "transcribe split total=\(String(format: "%.0f", metrics.taskInterval.duration * 1000))ms"
                + " preflight=\(preflight)ms"
                + " tx=\(metrics.transactionMetrics.count)"
                + " connect=\(ms(t.connectStartDate, t.connectEndDate))ms"
                + " send=\(ms(t.requestStartDate, t.requestEndDate))ms"
                + " wait=\(ms(t.requestEndDate, t.responseStartDate))ms"
                + " recv=\(ms(t.responseStartDate, t.responseEndDate))ms"
                + String(format: " load=%.1f", loads[0])
            )
        }
    }

    private static func describe(_ outcome: TranscriptOutcome) -> String {
        switch outcome {
        case .text(let text): return "text(\(text.count))"
        case .silence: return "silence"
        case .discardedNoise: return "noise"
        }
    }

    // Whisper writes a mid-sentence hesitation as "..." and capitalizes the
    // next word ("Can you... Explain"). Spoken pauses are not punctuation:
    // drop the dots and the stray capital when the pause interrupts a
    // sentence (lowercase letter or comma before it). "I"/"I'm" keep their
    // capital, and learned vocabulary fixes restore known proper nouns
    // afterward. A trailing ellipsis becomes a plain period.
    private static func softenPauses(_ text: String) -> String {
        var result = text
        let mid = "([a-z,;:])\\s*(?:\\.{2,}|\u{2026})\\s+(\\p{L})"
        while let range = result.range(of: mid, options: .regularExpression) {
            let segment = String(result[range])
            guard let lead = segment.first, let follow = segment.last else { break }
            let after = result[range.upperBound...]
            let keepsCapital = follow == "I"
                && (after.first == nil || after.first == " " || after.first == "'")
            let replacementTail = keepsCapital ? String(follow) : String(follow).lowercased()
            result.replaceSubrange(range, with: "\(lead) \(replacementTail)")
        }
        result = result.replacingOccurrences(
            of: "\\s*(?:\\.{2,}|\u{2026})\\s*$",
            with: ".",
            options: .regularExpression
        )
        return result
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
        // Whisper joins segments with newlines wherever the speaker pauses.
        // Dictated prose must never carry those into the paste (they render
        // as stray line breaks / indents), so collapse every interior
        // whitespace run to one space.
        trimmed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        trimmed = softenPauses(trimmed)
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
