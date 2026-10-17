import Foundation
import Speech
import AVFoundation

/// CLI ヘルパープロセスとして動作し、stdin から PCM Float32 音声バッファを受け取って
/// SFSpeechRecognizer でリアルタイム音声認識を行い、stdout に認識結果を 1 行ずつ出力するクラス
public final class LiveSpeechHelper {
    public static func run() {
        var localeIdentifier = "en-US"
        var sampleRate: Double = 44100.0
        var channels: Int = 1

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--locale"), idx + 1 < args.count {
            localeIdentifier = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--sample-rate"), idx + 1 < args.count, let sr = Double(args[idx + 1]) {
            sampleRate = sr
        }
        if let idx = args.firstIndex(of: "--channels"), idx + 1 < args.count, let ch = Int(args[idx + 1]) {
            channels = ch
        }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer = recognizer, recognizer.isAvailable else {
            fputs("[Helper] SFSpeechRecognizer unavailable for \(localeIdentifier)\n", stderr)
            exit(1)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        if #available(macOS 10.15, *), recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let out = "TEXT:\(text)\n"
                    if let data = out.data(using: .utf8) {
                        FileHandle.standardOutput.write(data)
                    }
                }
            }
            if let error = error {
                let nsErr = error as NSError
                if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 203 {
                    // fputs("[Helper] Recognition error: \(error.localizedDescription)\n", stderr)
                }
            }
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            fputs("[Helper] Invalid audio format\n", stderr)
            exit(1)
        }

        let stdinHandle = FileHandle.standardInput
        stdinHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: 親プロセスがパイプを閉じた
                request.endAudio()
                return
            }

            let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
            guard bytesPerFrame > 0 else { return }
            let frameCount = UInt32(data.count) / bytesPerFrame
            if frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                buffer.frameLength = frameCount
                data.withUnsafeBytes { rawPtr in
                    if let base = rawPtr.baseAddress {
                        memcpy(buffer.floatChannelData![0], base, Int(data.count))
                    }
                }
                request.append(buffer)
            }
        }

        // 親プロセスが終了したら自動終了するためのシグナル・ループ
        RunLoop.main.run()
        _ = task
    }
}
