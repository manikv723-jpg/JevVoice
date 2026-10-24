import AVFoundation
import AppKit
import Carbon
import Combine
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Test hooks

/// `SayOpen --selftest "phrase" ...` runs both engines on each phrase, acts on nothing, and prints
/// one JSON line per phrase. The key comes from TYPESAFE_API_KEY, never from the app's store.
func selfTest(_ phrases: [String]) -> Never {
    let apps = AppIndex.scan()
    let jev = JevEngine()
    jev.setApps(apps)
    let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ""
    func json(_ p: Plan?) -> [String: Any] {
        guard let p else { return ["action": "none"] }
        var d: [String: Any] = ["action": p.action, "label": p.label]
        if let a = p.app { d["app"] = a }
        if let t = p.text { d["text"] = t }
        if let s = p.setting { d["setting"] = s }
        return d
    }
    let done = DispatchSemaphore(value: 0)
    Task {
        for said in phrases {
            let t0 = Date()
            // The same code checks the app runs before and after either engine. SAYOPEN_FRONT
            // stands in for the app in front.
            let front = ProcessInfo.processInfo.environment["SAYOPEN_FRONT"]
            if let n = Guard.navigation(said) ?? Guard.direct(said, front: front, apps: apps) {
                let line: [String: Any] = ["said": said, "jev": json(n).merging(["ms": 0]) { a, _ in a },
                                           "rules": json(n).merging(["ms": 0]) { a, _ in a }]
                if let d = try? JSONSerialization.data(withJSONObject: line), let s = String(data: d, encoding: .utf8) { print(s); fflush(stdout) }
                continue
            }
            let r = Guard.check(Rules.decide(said, apps: apps), said: said, front: front)
            let rulesMs = Date().timeIntervalSince(t0) * 1000
            var j: [String: Any]
            if let a = exactMatch(said, apps) {
                j = json(Plan(action: "open_app", app: a.name))
                j["ms"] = 0
                j["why"] = "exact name"
            } else {
                do {
                    let v = try await jev.decide(said, earlier: [], front: front, alternatives: [], key: key)
                    j = json(Guard.check(v.plan, said: said, front: front))
                    j["ms"] = v.ms
                    j["why"] = v.why
                } catch { j = ["action": "error", "why": error.localizedDescription] }
            }
            var rj = json(r)
            rj["ms"] = rulesMs
            let line: [String: Any] = ["said": said, "jev": j, "rules": rj]
            if let d = try? JSONSerialization.data(withJSONObject: line), let s = String(data: d, encoding: .utf8) {
                print(s)
                fflush(stdout)
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

/// `open SayOpen.app --args --asrtest OUT.txt a.aiff ...` transcribes audio files with and without
/// the app-name vocabulary. Run through `open` so macOS asks SayOpen, not the terminal, for permission.
func asrTest(_ args: [String]) -> Never {
    let out = URL(fileURLWithPath: args[0])
    let vocab = AppIndex.scan().sorted { $0.uses > $1.uses }.prefix(100).map(\.name)
    let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    r.queue = OperationQueue()          // the main thread is parked on a semaphore below
    var lines: [String] = []
    let done = DispatchSemaphore(value: 0)
    SFSpeechRecognizer.requestAuthorization { status in
        guard status == .authorized else { lines.append("speech not authorized: \(status.rawValue)"); done.signal(); return }
        for f in args.dropFirst() {
            for ctx in [false, true] {
                let sem = DispatchSemaphore(value: 0)
                let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: f))
                req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
                if ctx { req.contextualStrings = vocab }
                var got = "timeout"
                r.recognitionTask(with: req) { res, err in
                    if let res, res.isFinal {
                        got = res.transcriptions.prefix(3).map(\.formattedString).joined(separator: " / ")
                        sem.signal()
                    } else if let err { got = "error \(err.localizedDescription)"; sem.signal() }
                }
                _ = sem.wait(timeout: .now() + 20)
                lines.append("\((f as NSString).lastPathComponent)\t\(ctx ? "with app names" : "plain")\t\(got)")
            }
        }
        done.signal()
    }
    done.wait()
    try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    exit(0)
}

/// `SayOpen --render DIR` draws the notch in every state to PNGs, with made-up data and no mic.
@MainActor
func renderTest(_ dir: String) -> Never {
    let b = Brain(preview: true)
    b.hasKey = true
    b.listening = true
    b.level = 0.55
    b.appCount = 114
    let now = Date()
    let rows: [(String, String, Double, Int)] = [
        ("Claude", "/Applications/Claude.app", 0, 0), ("Google Chrome", "/Applications/Google Chrome.app", 95, 380),
        ("Blender", "/Applications/Blender.app", 1300, 410), ("Notes", "/System/Applications/Notes.app", 5400, 0)]
    b.history = rows.map { Opening(app: $0.0, path: $0.1, at: now.addingTimeInterval(-$0.2), ms: $0.3,
                                   how: $0.3 == 0 ? "name" : "Jev 0.93", said: "") }
    b.heard = "open terminal and add a new tab"
    b.jevSays = "New tab in Terminal"
    b.rulesSays = "New tab"
    let notched = NotchGeometry(screen: NSScreen.main!, width: 185, height: 32, real: true)
    for (name, state) in [("idle", NotchState.idle), ("talking", .talking), ("opened", .opened),
                          ("typing", .typing), ("expanded", .expanded)] {
        b.notch = state
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.78), Color(white: 0.62)], startPoint: .top, endPoint: .bottom)
            NotchView(brain: b, geo: notched, openSettings: {})
        }
        .frame(width: 560, height: 260)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("notch-\(name).png"))
        }
    }
    exit(0)
}

// MARK: - App

let showNote = Notification.Name("com.jevvoice.sayopen.show")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var brain = Brain()
    private var window: NSWindow?
    private var notch: NotchController?
    private var keyWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = FrontTracker.shared               // start watching app switches before anything else
        DistributedNotificationCenter.default().addObserver(forName: showNote, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.showWindow() }
        }
        notch = NotchController(brain: brain, openSettings: { [weak self] in self?.showWindow() })
        // With a key the notch is the whole UI; without one, open Settings so there is somewhere to paste it.
        keyWatch = brain.$keyLoaded.first { $0 }.sink { [weak self] _ in
            MainActor.assumeIsolated { if self?.brain.hasKey == false { self?.showWindow() } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "SayOpen"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: Panel(brain: brain))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@main
struct SayOpenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") { selfTest(Array(args[(i + 1)...])) }
        if let i = args.firstIndex(of: "--asrtest") { asrTest(Array(args[(i + 1)...])) }
        if let i = args.firstIndex(of: "--menus") {
            let name = args[i + 1], out = args[i + 2]
            let pid = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.processIdentifier ?? 0
            let lines = ["trusted \(AXIsProcessTrusted()) pid \(pid)"] + Menus.dump(pid: pid)
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--press") {       // --press AppName action : run one action for real
            let apps = AppIndex.scan()
            // --press AppName action [text] [setting]
            let plan = Plan(action: args[i + 2], app: args[i + 1].isEmpty ? nil : args[i + 1],
                            text: args.count > i + 3 ? args[i + 3] : nil, setting: args.count > i + 4 ? args[i + 4] : nil)
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let o = await Executor.run(plan, apps: apps, focus: nil)
                dlog("--press \(plan.label): ok \(o.ok) \(o.note)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // let an async open reach the app
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--inapp") {       // --inapp AppName "goal": click through it for real
            let apps = AppIndex.scan()
            let plan = Plan(action: "in_app", app: args[i + 1], text: args[i + 2])
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let o = await Executor.run(plan, apps: apps, focus: apps.first { $0.name == args[i + 1] })
                print("in_app ok \(o.ok): \(o.note)")
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--choose") {      // --choose "said" [--dry]: answer the front terminal's list
            guard let front = NSWorkspace.shared.frontmostApplication else { exit(1) }
            let said = args[i + 1]
            guard let text = TerminalMenu.screen(pid: front.processIdentifier) else { print("no screen text in \(front.localizedName ?? "?")"); exit(1) }
            guard let m = TerminalMenu.menu(in: text) else { print("no menu; last lines:\n" + text.components(separatedBy: "\n").suffix(12).joined(separator: "\n")); exit(1) }
            print("options \(m.options) cursor \(m.cursor) applies \(TerminalMenu.applies(said, front: front)) pick \(TerminalMenu.pick(said, m.options).map(String.init) ?? "none")")
            if !args.contains("--dry") {
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in let o = await TerminalMenu.choose(said, app: front); print("chose ok \(o.ok): \(o.note)"); done.signal() }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--page") {        // --page "open the X doc": what it would open, opens nothing
            for said in args[(i + 1)...] {
                guard let (name, kind) = PageHistory.parse(said) else { print("\(said) -> not a page request"); continue }
                let p = PageHistory.find(name, kind: kind, browser: "Dia")
                print("\(said) -> [\(name) | \(kind ?? "-")] \(p.map { "\($0.title) \($0.url.prefix(60))" } ?? "NOT FOUND")")
            }
            exit(0)
        }
        if args.contains("--trimlive") {                  // delete the stop phrase from the focused box, for real
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in print("handled: \(await Dictation.trimField())"); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--trim") {        // --trim "text": what the stop-phrase trim would delete
            let t = args[i + 1]; let n = Dictation.stopSuffixLength(t)
            print("\(n) \"\(t.dropLast(n))\"")
            exit(0)
        }
        if let i = args.firstIndex(of: "--type") {        // --type "text": keystrokes into the front app
            Keys.type(args[i + 1]); usleep(300_000); exit(0)
        }
        if let i = args.firstIndex(of: "--title") {       // --title OUT: front app and its window title
            let app = NSWorkspace.shared.frontmostApplication
            let ax = AXUIElementCreateApplication(app?.processIdentifier ?? 0)
            var w: CFTypeRef?, t: CFTypeRef?
            AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &w)
            if let w { AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) }
            try? "\(app?.localizedName ?? "?") | \(t as? String ?? "?")".write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--ui") {          // --ui AppName OUT: what can be clicked in it
            let name = args[i + 1], out = args[i + 2]
            let pid = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.processIdentifier ?? 0
            UIScan.wake(pid)
            usleep(800_000)
            let t0 = Date()
            let c = UIScan.clickables(pid: pid)
            let lines = ["\(c.count) clickables in \(Int(Date().timeIntervalSince(t0) * 1000))ms"] + c.map(\.label)
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--findfile") {    // --findfile "what you said": matches, best first
            let t0 = Date()
            let found = FileSearch.find(args[i + 1])
            print("\(found.count) matches in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            found.prefix(6).forEach { print("  " + FileSearch.describe($0)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render") { MainActor.assumeIsolated { renderTest(args[i + 1]) } }
        // One copy only. A second launch hands over to the first and leaves.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(showNote, object: nil, deliverImmediately: true)
            others.first?.activate()
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

