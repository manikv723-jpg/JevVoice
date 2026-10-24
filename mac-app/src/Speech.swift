import CoreAudio
import AVFoundation
import AppKit
import Carbon
import Combine
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Speech

/// Streams partial transcripts plus the recogniser's runner-up hearings and a mic level.
/// A recognition task ends on a long pause, so the next one starts straight away.
/// `generation` makes callbacks from a cancelled task harmless.
final class Listener {
    var onText: ((String, [String], Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    var onNewTranscript: (() -> Void)?     // a fresh recognition task: its transcript starts from zero
    /// App names the recogniser should expect. Without this it writes "Claude" as "cloud".
    var vocabulary: [String] = []
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var lastLevelAt = Date.distantPast
    private(set) var running = false

    func start() {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable else {
            dlog("recognizer unavailable (nil: \(recognizer == nil))")
            onError?("Speech recognition unavailable"); return
        }
        dlog("listener starting, on-device: \(recognizer.supportsOnDeviceRecognition), vocabulary \(vocabulary.count)")
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            guard let self else { return }
            self.request?.append(buf)
            self.meter(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            dlog("audio engine failed: \(error)")
            onError?("Microphone failed: \(error.localizedDescription)")
            return
        }
        dlog("audio engine running, input format \(input.outputFormat(forBus: 0))")
        running = true
        restart()
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        task?.cancel()
        task = nil
        request = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        onLevel?(0)
    }

    /// Drop whatever was said so far and listen afresh.
    func restart() {
        guard running, let recognizer else { return }
        generation += 1
        let gen = generation
        task?.cancel()
        onNewTranscript?()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result {
                    let best = result.bestTranscription.formattedString
                    let alts = result.transcriptions.dropFirst().prefix(3)
                        .map(\.formattedString).filter { $0 != best }
                    self.onText?(best, alts, result.isFinal)
                    if result.isFinal { self.restart(); return }
                }
                if let error {
                    dlog("recognition error: \(error.localizedDescription)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if gen == self.generation { self.restart() }
                    }
                }
            }
        }
    }

    private func meter(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0 ..< n { sum += ch[i] * ch[i] }
        let level = min(1, sqrt(sum / Float(n)) * 14)
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) > 0.05 else { return }
        lastLevelAt = now
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}

// MARK: - Global hotkey (Carbon: needs no Accessibility permission)

final class Hotkey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5341_594F), id: 1)   // 'SAYO'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}


// MARK: - Is Wispr Flow listening?

/// Watches which processes have the microphone open (what the orange dot shows). While Wispr
/// Flow is dictating, one of its helper processes is running audio input; SayOpen must not
/// treat that dictation as commands.
@MainActor
final class MicWatch {
    static let shared = MicWatch()
    var onChange: ((Bool) -> Void)?
    private(set) var wisprActive = false
    private var prefix = ""
    private var timer: Timer?

    func start(bundlePrefix: String) {
        prefix = bundlePrefix
        guard !prefix.isEmpty, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = MicWatch.inputActive(bundlePrefix: self.prefix)
                if now != self.wisprActive {
                    self.wisprActive = now
                    self.onChange?(now)
                }
            }
        }
    }

    static func inputActive(bundlePrefix: String) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &inAddr, 0, nil, &s, &running) == noErr, running == 1 else { continue }
            var bAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var s2 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &bAddr, 0, nil, &s2, &cf) == noErr,
                  let bid = cf?.takeRetainedValue() as String? else { continue }
            if bid.hasPrefix(bundlePrefix) { return true }
        }
        return false
    }
}
