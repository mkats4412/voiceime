import Foundation
import Speech
import AVFoundation

/// CLI ヘルパープロセスとして動作し、stdin から PCM Float32 音声バッファを受け取って
/// SFSpeechRecognizer でリアルタイム音声認識を行い、stdout に認識結果を 1 行ずつ出力するクラス
public final class LiveSpeechHelper {
    public static func run() {
        // パイプ破断時の SIGPIPE による異常終了を無視
        signal(SIGPIPE, SIG_IGN)

        var localeIdentifier = "en-US"
        var sampleRate: Double = 44100.0

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--locale"), idx + 1 < args.count {
            localeIdentifier = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--sample-rate"), idx + 1 < args.count, let sr = Double(args[idx + 1]), sr > 0 {
            sampleRate = sr
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

        let stdoutLock = NSLock()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let out = "TEXT:\(text)\n"
                    if let data = out.data(using: .utf8) {
                        stdoutLock.lock()
                        defer { stdoutLock.unlock() }
                        try? FileHandle.standardOutput.write(contentsOf: data)
                    }
                }
            }
            if let error = error {
                let nsErr = error as NSError
                if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 203 {
                    // 通常の認識終了・無音は無視
                }
            }
        }

        // 親プロセスからは常に channelData[0]（モノラル 1ch Float32）が送られるため 1ch 固定で整合させる
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fputs("[Helper] Invalid audio format\n", stderr)
            exit(1)
        }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            exit(1)
        }

        // ストリーム断片化（4バイト境界の端数）対策用の直列キューと残余バッファ
        let ingestQueue = DispatchQueue(label: "com.voiceime.helper.ingest")
        var remainderData = Data()

        let stdinHandle = FileHandle.standardInput
        stdinHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            ingestQueue.async {
                if chunk.isEmpty {
                    // EOF: 親プロセスがパイプを閉じた ➔ 音声終了・ハンドラ解除・正常終了
                    handle.readabilityHandler = nil
                    request.endAudio()
                    task.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        exit(0)
                    }
                    return
                }

                remainderData.append(chunk)
                let availableFrames = remainderData.count / bytesPerFrame
                guard availableFrames > 0 else { return }

                let consumableBytes = availableFrames * bytesPerFrame
                let frameCount = AVAudioFrameCount(availableFrames)

                if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                    buffer.frameLength = frameCount
                    remainderData.withUnsafeBytes { rawBuffer in
                        guard let baseAddress = rawBuffer.baseAddress,
                              let channelData = buffer.floatChannelData else { return }
                        memcpy(channelData[0], baseAddress, consumableBytes)
                    }
                    request.append(buffer)
                }

                // 消費したフレーム分を除去し、端数バイト（0〜3バイト）を次回に繰り越す
                remainderData.removeFirst(consumableBytes)
            }
        }

        // 親プロセスがクラッシュ等で突然死した場合のセーフティ（定期的に親PIDの生存を監視）
        let ppid = getppid()
        let watchdogTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        watchdogTimer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        watchdogTimer.setEventHandler {
            if getppid() != ppid || getppid() <= 1 {
                exit(0)
            }
        }
        watchdogTimer.resume()

        RunLoop.main.run()
        _ = task
        _ = watchdogTimer
    }
}
