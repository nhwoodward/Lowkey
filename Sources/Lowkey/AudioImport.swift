import AVFoundation

struct ImportedAudio {
    let url: URL
    let duration: TimeInterval

    // Decode the formats accepted by NSOpenPanel before applying PCM limits or
    // sending audio to Whisper. Never rename a compressed file to pretend it is WAV.
    static func prepare(_ source: URL, directory: URL = Config.tmpDirectory) throws -> ImportedAudio {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0 else { throw AudioImportError.empty }
        let duration = Double(file.length) / format.sampleRate
        guard duration <= 120, format.channelCount <= 8,
              Double(file.length) * Double(format.channelCount) <= 32_000_000 else { throw TranscriberError.tooLarge }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(duration * 16_000)) + 1024)
        else { throw AudioImportError.unsupported }
        try file.read(into: input)
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, flag in
            if provided { flag.pointee = .endOfStream; return nil }
            provided = true
            flag.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { throw AudioImportError.empty }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let writer = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        try writer.write(from: output)
        return ImportedAudio(url: url, duration: duration)
    }
}

enum AudioImportError: LocalizedError {
    case empty, unsupported
    var errorDescription: String? {
        switch self {
        case .empty: return "The audio file contains no recording."
        case .unsupported: return "This audio format could not be read. Try a WAV, M4A, or MP3 file."
        }
    }
}
