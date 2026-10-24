// Streams partial speech transcripts to stdout as JSON lines, one per hypothesis.
// {"text": "open notes for me and", "final": false}
// On-device recognition, so the only network hop in the whole demo is the Jev call.

import Foundation
import AVFoundation
import Speech

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ text: String, _ isFinal: Bool) {
    let obj: [String: Any] = ["text": text, "final": isFinal]
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return }
    print(s)
    fflush(stdout)
}

func log(_ s: String) {
    FileHandle.standardError.write(("[listen] " + s + "\n").data(using: .utf8)!)
}

final class Listener {
    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "jevvoice.listener")

    init?() {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return nil }
        recognizer = r
    }

    func run() {
        guard recognizer.isAvailable else { log("recognizer unavailable"); exit(1) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            log("audio engine failed: \(error.localizedDescription)")
            exit(1)
        }
        newTask()
        log("listening. on-device=\(recognizer.supportsOnDeviceRecognition). ctrl-c to stop.")
    }

    // A recognition task ends on a long pause, so we just start the next one.
    private func newTask() {
        task?.cancel()
        task = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                emit(result.bestTranscription.formattedString, result.isFinal)
                if result.isFinal {
                    self.queue.async { self.newTask() }
                    return
                }
            }
            if error != nil {
                self.queue.asyncAfter(deadline: .now() + 0.3) { self.newTask() }
            }
        }
    }
}

guard let listener = Listener() else { log("no en-US recognizer"); exit(1) }

AVCaptureDevice.requestAccess(for: .audio) { micOK in
    guard micOK else { log("microphone access denied"); exit(1) }
    SFSpeechRecognizer.requestAuthorization { status in
        guard status == .authorized else {
            log("speech recognition not authorized (status \(status.rawValue))")
            log("grant it in System Settings > Privacy & Security > Speech Recognition for your terminal app")
            exit(1)
        }
        DispatchQueue.main.async { listener.run() }
    }
}

RunLoop.main.run()
