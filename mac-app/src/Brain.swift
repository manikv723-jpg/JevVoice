import AVFoundation
import AppKit
import Carbon
import ServiceManagement
import Speech
import SwiftUI

// One long sentence is several instructions strung together. Code finds the seams; an engine
// judges one clause at a time, and each clause is acted on the moment it is decided, while you
// are still talking. "open terminal, add a new tab and let me type" is three clauses.

let seamWords: Set<String> = ["and", "then", "also", "phir", "aur"]

struct Clause {
    let text: String
    let span: Int          // transcript words this clause uses up, including the seam after it
    let closed: Bool       // the speaker has moved past it
}

func clauses(_ words: [String]) -> [Clause] {
    var out: [Clause] = []
    var cur: [String] = []
    var span = 0
    for w in words {
        span += 1
        let k = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if seamWords.contains(k) {
            if !cur.isEmpty { out.append(Clause(text: cur.joined(separator: " "), span: span, closed: true)) }
            else if var last = out.popLast() { last = Clause(text: last.text, span: last.span + span, closed: true); out.append(last) }
            cur = []
            span = 0
            continue
        }
        cur.append(w.trimmingCharacters(in: CharacterSet(charactersIn: ",;")))
        if w.hasSuffix(",") || w.hasSuffix(";") {
            out.append(Clause(text: cur.joined(separator: " "), span: span, closed: true))
            cur = []
            span = 0
        }
    }
    if !cur.isEmpty { out.append(Clause(text: cur.joined(separator: " "), span: span, closed: false)) }
    return out
}

/// Checks on what an engine decided, the same for both engines and for the self-test.
enum Guard {
    /// "Open the tab that needs input" is an existing tab, not a new one. A new tab has to be asked
    /// for: new, another, fresh, blank, one more.
    static let newWords = #"\b(new|another|fresh|blank|empty|extra|one more|naya|nayi)\b"#
    /// Closing and quitting lose work, so the word has to be there: "clear this from the text
    /// from the tab" once closed a tab. "Clot" is how "close" is heard mid-sentence.
    static let closeWords = #"\b(clos\w*|clot\w*|quit\w*|kill|exit|shut|band|get rid|rid of|dismiss|remove|bye)\b"#

    static func check(_ plan: Plan?, said: String, front: String?) -> Plan? {
        guard let plan else { return nil }
        let s = normalise(said)
        func has(_ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        if plan.action == "new_tab" && !has(newWords) && !has(#"\b(add|open) a tab\b"#) {
            return Plan(action: "in_app", app: plan.app ?? front, text: said)
        }
        // "...along with Wispr Flow it helps me run my whole computer" is talk about Wispr, not a
        // request to dictate: it once started typing into an open spreadsheet.
        if plan.action == "dictate" || (plan.action == "open_app" && plan.app == "Wispr Flow"),
           s.split(separator: " ").count > 7 {
            dlog("guard: \(plan.label) from a \(s.split(separator: " ").count)-word sentence, dropped")
            return nil
        }
        // "Product" opened Wispr Flow and "Make" opened Terminal: an app has to be named, at least
        // roughly (sounds alike, or starts the same), before it is opened or quit.
        // Describing an app ("the app I make 3D models in") is fine; a stray word or two is not.
        if ["open_app", "quit_app"].contains(plan.action), let app = plan.app, s.split(separator: " ").count <= 2 {
            let said = s.split(separator: " ").map(String.init)
            let name = normalise(app).split(separator: " ").map(String.init).filter { $0.count >= 3 }
            let aliasHit = Rules.aliases.contains { $0.value == app && (" " + s + " ").contains(" \($0.key) ") }
            let named = aliasHit || name.contains { n in said.contains { w in
                w == n || (w.count >= 3 && (n.hasPrefix(w) || w.hasPrefix(n)))
                    || (w.count >= 3 && FileSearch.soundex(w) == FileSearch.soundex(n))
                    || Rules.editDistance(w, n) <= max(1, n.count / 4) } }
            if !named {
                dlog("guard: \(plan.label) but \"\(said.joined(separator: " "))\" never names it, dropped")
                return nil
            }
        }
        if ["close_tab", "close_window", "quit_app"].contains(plan.action) && !has(closeWords) {
            dlog("guard: \(plan.label) without a close word in \"\(said)\", dropped")
            return nil
        }
        return plan
    }

    static let numbers: [String: Int] = ["one": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "for": 4, "five": 5,
                                         "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "once": 1, "twice": 2]
    static func number(_ w: String) -> Int? { Int(w) ?? numbers[w] }

    /// Moving around: scrolling, arrow keys, Escape, tab numbers and "click the first sign-in".
    /// Fixed phrasings, read by code the same way whichever engine is on.
    static func navigation(_ said: String) -> Plan? {
        let s = normalise(said)
        func grab(_ p: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (0 ..< m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : String(s[Range(m.range(at: $0), in: s)!]) }
        }
        if let g = grab(#"\bscroll(?: the page| it| this)?(?: all the way)?(?: (down|up)| to (?:the )?(top|bottom|end|start))?\b"#) {
            let how = g[2].isEmpty ? (g[1].isEmpty ? "down" : g[1]) : (["end", "bottom"].contains(g[2]) ? "bottom" : "top")
            // "Scroll down scroll down" is heard as one clause: scroll once per time it was said,
            // plus "scroll down a lot" / "three times".
            let said = s.components(separatedBy: "scroll").count - 1
            let more = s.range(of: #"\b(a lot|lots|way|more|further|much)\b"#, options: .regularExpression) != nil ? 3 : 1
            let n = max(said, grab(#"\b(\w+) times?\b"#).flatMap { number($0[1]) } ?? 1) * more
            return Plan(action: "scroll", text: n > 1 ? String(min(n, 10)) : nil, setting: how)
        }
        // "Open the Roadmap 2.0 Google Doc": a page from the browser's history, by title.
        if PageHistory.parse(said) != nil { return Plan(action: "open_page", text: said) }
        // "Open built with Jev PNG": a file on this Mac, named with what kind it is.
        if s.range(of: #"^(?:please )?(?:open|show|show me|pull up|bring up|find)(?: up)?(?: the| my| that| our)? .+ (?:png|jpg|jpeg|heic|pdf|ppt|pptx|keynote|docx|word file|xlsx|excel|csv|mp4|mov|video|image|photo|picture|screenshot|file|zip)$"#,
                   options: .regularExpression) != nil {
            return Plan(action: "open_file", text: said)
        }
        if let g = grab(#"^(?:go )?(?:page) (down|up)$"#) { return Plan(action: "scroll", setting: g[1]) }
        let times = grab(#"\b(\w+) times?\b"#).flatMap { number($0[1]) }
        if let g = grab(#"\b(?:press|hit|tap|push)(?: the)? (up|down|left|right|escape|esc|tab|space|spacebar|backspace)\b"#)
            ?? grab(#"\b(up|down|left|right) arrow\b"#) ?? grab(#"^(escape|esc)$"#) {
            let key = ["esc": "escape", "spacebar": "space"][g[1]] ?? g[1]
            return Plan(action: "key", text: times.map(String.init), setting: key)
        }
        if let g = grab(#"^(?:move|go)(?: the)?(?: cursor| selection| highlight)? (up|down)(?: by)?(?: (\w+))?(?: times?)?(?: (?:option|options|line|lines|step|steps))?$"#) {
            return Plan(action: "key", text: (number(g[2]) ?? times).map(String.init), setting: g[1])
        }
        if let g = grab(#"\b(?:switch|go|jump|move|change)(?: over)? to (?:the )?tab (?:number )?(\w+)\b"#) ?? grab(#"^tab (?:number )?(\w+)$"#)
            ?? grab(#"\b(?:switch|go|jump|move)(?: over)? to (?:the )?(\w+) tab\b"#).flatMap({ g in
                ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "last": 9][g[1]].map { _ in g } }) {
            let ord = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "last": 9]
            if let n = number(g[1]) ?? ord[g[1]], (1 ... 9).contains(n) { return Plan(action: "switch_tab", setting: String(n)) }
        }
        // A tab by its name: "switch to the Google Doc tab". Tab labels are read off the screen.
        if let g = grab(#"^(?:switch|go|jump|move|open|show|take me|bring up)(?: over)?(?: to)?(?: the| my)? (.+?) tab$"#),
           g[1].range(of: #"\b(new|another|next|previous|last|closed)\b"#, options: .regularExpression) == nil {
            return Plan(action: "in_app", text: said)
        }
        // Clicking something on screen by its words. "Open" only with a position or a link word,
        // so "open Chrome" still opens the app.
        if s.range(of: #"\b(enter|return)$"#, options: .regularExpression) != nil { return nil }
        // Profiles and accounts are picked on screen, in whichever app is in front.
        if s.range(of: #"^(?:change|switch|move|go)(?: over)?(?: to)?(?: the| my| a)? (?:profile|account|org|organisation|organization|workspace)s?\b|\b(?:profile|account) to\b"#, options: .regularExpression) != nil {
            return Plan(action: "in_app", text: said)
        }
        if s.range(of: #"^(?:click|tap|press|hit|choose|select|pick)(?: on)?\b"#, options: .regularExpression) != nil
            || s.range(of: #"^(?:open|go to|visit) (?:the )?(?:first|second|third|fourth|fifth|last|1st|2nd|3rd|top)\b"#, options: .regularExpression) != nil
            || s.range(of: #"^open (?:the )?.*\b(?:link|result|button)\b"#, options: .regularExpression) != nil {
            return Plan(action: "in_app", text: said)
        }
        return nil
    }

    /// Things only one app has, said while it is in front (or named): "change the model",
    /// "open the session that needs input". No engine needed, and no engine guessing a tab.
    static func direct(_ said: String, front: String?, apps: [AppEntry]) -> Plan? {
        let s = " " + normalise(said) + " "
        for app in AppKnowledge.places.keys where apps.contains(where: { $0.name == app }) {
            let named = s.range(of: " (in|inside|on|into) (the )?\(normalise(app)) ", options: .regularExpression) != nil
            guard named || front == app else { continue }
            if let p = AppKnowledge.place(said, app: app), p.direct { return Plan(action: "in_app", app: app, text: said) }
        }
        return nil
    }
}

enum EngineKind: String { case jev, rules }
enum NotchState: Equatable { case idle, talking, opened, typing, expanded }

@MainActor
final class Brain: ObservableObject {
    @Published var listening = false
    @Published var heard = ""
    @Published var level: Float = 0
    @Published var history: [Opening] = History.load()
    @Published var problem = ""
    @Published var appCount = 0
    @Published var calls = 0
    @Published var hasKey = false
    @Published var keyLoaded = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var notch: NotchState = .idle
    @Published var trusted = AXIsProcessTrusted()
    @Published var typing = false
    @Published var wisprOn = false         // Wispr Flow has the mic: you are dictating, not commanding
    // Wake phrase: asleep, SayOpen ignores everything but "Hey Jev", so a video playing on Twitter
    // or YouTube is not taken as commands. Awake until 6s pass with nothing said.
    @Published var awake = false
    @Published var needsWake: Bool = UserDefaults.standard.object(forKey: "needsWake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(needsWake, forKey: "needsWake"); if !needsWake { awake = false } }
    }
    private var awakeUntil = Date.distantPast
    private var liveFiredPlan: Plan?
    @Published var jevSays = ""
    @Published var rulesSays = ""
    @Published var engine: EngineKind = EngineKind(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .jev {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    var lastSpokeAt = Date.distantPast
    var lastOpenedAt = Date.distantPast

    private(set) var apps: [AppEntry] = []
    private let jev = JevEngine()
    private let listener = Listener()
    private var key = ""
    private var hotkey: Hotkey?

    // The utterance being worked through.
    private var words: [String] = []
    private var alts: [String] = []
    private var final = false
    private var heardAt = Date()
    private var consumed = 0              // words already acted on or passed over
    private var earlier: [String] = []    // what this sentence has done so far, for context
    private var focus: AppEntry?          // the app the last step left in front
    private var busy = false
    private var busySince = Date()
    private var pumpGen = 0               // a loop abandoned by the watchdog must not touch state
    private var liveFired = false         // the open clause already acted; skip it until it closes
    private var endedByPause = false      // the recogniser is still on this sentence
    private var base = 0                  // words of the recogniser's transcript that belong to earlier sentences
    private var taskWords = 0             // length of the recogniser's whole transcript so far
    private var taskText: [String] = []   // that transcript, to notice when a fresh one starts
    private var basePrefix: [String] = [] // the words `base` skips
    private var watchdog: Timer?
    private var waiting: (String, [String], Bool)?   // next utterance, while the last one finishes
    private var quietUntil = Date.distantPast
    private var jevCache: [String: Plan?] = [:]
    private var recentFires: [String: Date] = [:]

    // Voice typing handed to Wispr Flow.
    private var dictationStartedAt = Date()   // to find what Wispr pasted for this dictation

    /// `preview` builds a brain with no mic, key, hotkey or login item, for rendering and tests.
    init(preview: Bool = false) {
        if preview { return }
        rescan()
        listener.onText = { [weak self] text, alts, final in self?.transcript(text, alts, final: final) }
        listener.onLevel = { [weak self] l in self?.level = l }
        listener.onNewTranscript = { [weak self] in
            MainActor.assumeIsolated {
                self?.base = 0
                self?.basePrefix = []
                self?.taskWords = 0
            }
        }
        listener.onError = { [weak self] msg in self?.problem = msg; self?.listening = false }
        Hotkey.action = { [weak self] in self?.toggle() }
        hotkey = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        _ = FrontTracker.shared
        startWatchdog()
        Executor.uiPicker = { [weak self] goal, appName in
            guard let self else { return UIAgent.rulesPick(goal: goal, appName: appName) }
            if self.engine == .rules || self.key.isEmpty { return UIAgent.rulesPick(goal: goal, appName: appName) }
            let key = self.key, jev = self.jev
            return { labels, clicked in await jev.pickClick(goal: goal, app: appName, clicked: clicked, labels: labels, key: key) }
        }
        Executor.chooser = { [weak self] said, options, what in
            guard let self, self.engine == .jev, !self.key.isEmpty else { return nil }
            let (i, conf) = await self.jev.choose(said: said, instructions: what, options: options,
                                                  none: "None of these is the one meant.", key: self.key)
            return conf >= 0.3 ? i : nil
        }
        Executor.filePicker = { [weak self] said, labels in
            guard let self, self.engine == .jev, !self.key.isEmpty else { return labels.isEmpty ? nil : 0 }
            return await self.jev.pickFile(said: said, labels: labels, key: self.key)
        }
        if let w = apps.first(where: { $0.name == Dictation.appName }),
           let bid = Bundle(url: w.url)?.bundleIdentifier {
            MicWatch.shared.onChange = { [weak self] on in self?.wisprChanged(on) }
            MicWatch.shared.start(bundlePrefix: bid)
        }
        if !UserDefaults.standard.bool(forKey: "didOfferLogin") {
            UserDefaults.standard.set(true, forKey: "didOfferLogin")
            setLaunchAtLogin(true)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let k = KeyStore.read()
            DispatchQueue.main.async {
                self.key = k
                self.hasKey = !k.isEmpty
                self.keyLoaded = true
                dlog("launch: key \(k.isEmpty ? "missing" : "loaded"), \(self.appCount) apps, engine \(self.engine.rawValue), accessibility \(AXIsProcessTrusted())")
                if self.hasKey || self.engine == .rules { self.start() }
            }
        }
    }

    func rescan() {
        apps = AppIndex.scan()
        appCount = apps.count
        jev.setApps(apps)
        listener.vocabulary = ["OK Jev", "Hey Jev", "Hey Mac", "Wispr Flow", "close Wispr Flow"]
            + apps.filter { $0.uses > 0 }.sorted { $0.uses > $1.uses }.prefix(95).map(\.name)
    }

    func saveKey(_ k: String) {
        key = k.trimmingCharacters(in: .whitespacesAndNewlines)
        KeyStore.write(key)
        dlog("key saved (\(key.count) chars)")
        hasKey = !key.isEmpty
        problem = ""
        if hasKey { start() }
    }

    func forgetKey() {
        stop()
        saveKey("")
    }

    func toggle() {
        if typing { stopTyping(); return }
        if needsWake && listening {
            if awake { goToSleep(why: "hotkey") } else { wake(skipping: taskWords, why: "hotkey") }
            return
        }
        listening ? stop() : start()
    }

    private func wake(skipping upTo: Int, why: String) {
        awake = true
        awakeUntil = Date().addingTimeInterval(6)
        base = upTo                            // nothing said before waking is a command
        basePrefix = Array(taskText.prefix(upTo))
        dlog("awake (\(why))")
    }

    func goToSleep(why: String) {
        guard awake else { return }
        awake = false
        base = taskWords                       // what was heard so far is done with
        basePrefix = taskText
        words = []
        consumed = 0
        earlier = []
        focus = nil
        liveFired = false
        heard = ""
        dlog("asleep (\(why))")
    }

    /// Index just past "hey jev" (or how speech recognition hears it) in these words, if present.
    private func wakeEnd(_ w: [String]) -> Int? {
        let n = w.map { normalise($0) }
        let hey: Set<String> = ["hey", "hi", "ok", "okay", "hay"]
        // "Jev" is not an English word, so recognition writes Jeff, Jen, Jeb, Chev...: any short
        // word starting j/ch/g after "hey" counts. A video saying "hey John" can wake it, but it still
        // stays awake until told to stop, and conversation still has to read as a command to Jev.
        func isJev(_ w: String) -> Bool { w.range(of: #"^(j|ch|g)[a-z]{1,4}$"#, options: .regularExpression) != nil }
        for i in 0 ..< n.count {
            if n[i] == "sayopen" { return i + 1 }
            guard i + 1 < n.count else { break }
            if hey.contains(n[i]) && isJev(n[i + 1]) { return i + 2 }
            // Measured on three voices: "hey mac" and "hey computer" are heard right every time.
            if hey.contains(n[i]) && ["mac", "computer"].contains(n[i + 1]) { return i + 2 }
            if n[i] == "say" && n[i + 1] == "open" { return i + 2 }
        }
        return nil
    }

    func start() {
        guard !listening else { return }
        problem = ""
        dlog("start: mic status \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), speech status \(SFSpeechRecognizer.authorizationStatus().rawValue)")
        AVCaptureDevice.requestAccess(for: .audio) { micOK in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    dlog("permissions: mic \(micOK), speech \(status.rawValue) (3 = authorized)")
                    guard micOK else { self.problem = "Microphone access is off. System Settings > Privacy > Microphone"; return }
                    guard status == .authorized else { self.problem = "Speech Recognition is off. System Settings > Privacy > Speech Recognition"; return }
                    self.rescan()
                    self.listener.start()
                    self.listening = self.listener.running
                }
            }
        }
    }

    func stop() {
        listener.stop()
        listening = false
        heard = ""
    }

    func askAccessibility() {
        trusted = Keys.trusted()
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { problem = "Launch at login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showLog() {
        if !FileManager.default.fileExists(atPath: History.url.path) {
            try? History.header.write(to: History.url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([History.url])
    }

    // MARK: listening

    /// Scenario tests feed transcripts the way the recogniser does, word by word.
    func feed(_ text: String, final: Bool = false) { transcript(text, [], final: final) }

    private func transcript(_ text: String, _ alts: [String], final: Bool) {
        dlog("hear\(final ? " FINAL" : "") [base \(base), busy \(busy), pending \(self.final), typing \(typing)]: \(text)")
        if Date() < quietUntil { return }
        if typing || wisprOn {
            // Dictation is not commands, with one exception: the phrase that ends it.
            if isStopPhrase(text) { finishDictation(said: text); return }
            if typing { heard = text; lastSpokeAt = Date() }
            // Only the last few words matter here. A long dictation once froze the recogniser's
            // transcript and the stop phrase was never heard, so keep each stretch short.
            if text.split(separator: " ").count > 12 { listener.restart() }
            return
        }
        lastSpokeAt = Date()
        if engine == .jev { jev.warm() }
        if self.final {                       // still finishing the last sentence
            waiting = (text, alts, final)
            if final { dlog("queued (final, previous sentence still running): \(text)") }
            return
        }
        let all = text.split(separator: " ").map(String.init)
        // The recogniser sometimes starts a fresh transcript after a pause without saying so.
        // If the start no longer matches what `base` skips, this is a new transcript.
        let low = { (a: [String]) in a.map { $0.lowercased() } }
        if base > 0, low(Array(all.prefix(base))) != low(basePrefix) {
            // A resent transcript may start with the wake phrase again; it is not part of the command.
            let skip = awake ? (wakeEnd(Array(all.prefix(6))) ?? 0) : 0
            dlog("fresh transcript, reset base \(base) -> \(skip)")
            base = skip
            basePrefix = Array(all.prefix(skip))
        }
        taskWords = all.count
        taskText = all
        if needsWake && !awake {
            let rest = Array(all.dropFirst(base))
            guard let end = wakeEnd(rest) else { return }        // asleep: not a command
            wake(skipping: base + end, why: "\"\(rest.prefix(end).joined(separator: " "))\"")
        }
        if needsWake {
            // Awake stays awake until you say so: "stop Mac", "close Mac", "bye Mac". "Mac" is heard
            // as Mack, Max or Mag too.
            let tail = normalise(Array(all.dropFirst(base)).joined(separator: " "))
            let mac = #"(mac|mack|max|mag|mak|jev|jeff|computer)"#
            if tail.range(of: #"\b(stop|close|bye|goodbye|sleep|pause|shut up|quiet) \#(mac)$|(go to sleep|stop listening|that s all|thats all|sleep now)$"#,
                          options: .regularExpression) != nil {
                goToSleep(why: "asked")
                return
            }
        }
        var w = Array(all.dropFirst(base))
        // "Hey Mac open ..." said while already awake: the wake words are not part of the command.
        if needsWake, let end = wakeEnd(Array(w.prefix(4))) { w = Array(w.dropFirst(end)) }
        if w.isEmpty && !final { return }
        if w != words { heardAt = Date() }
        words = w
        heard = w.joined(separator: " ")
        self.alts = base == 0 ? alts : []     // runner-up hearings cover the whole transcript
        if final {
            self.final = true
            dlog("heard (final): \(text)  alts: \(alts)")
        }
        pump()
    }

    /// Work through the clauses not yet acted on. One loop at a time; it re-reads the transcript
    /// after every await, so words that arrive meanwhile are picked up.
    private func pump() {
        guard !busy else { return }
        busy = true
        busySince = Date()
        pumpGen += 1
        let gen = pumpGen
        Task {
            while !typing && gen == pumpGen {
                let snapshot = (words, final)
                let cls = clauses(Array(words.dropFirst(consumed)))
                guard let c = cls.first else { break }
                let closed = c.closed || final
                if liveFired {
                    // Already acted on this clause while it was being spoken. Once it ends, read the
                    // whole of it again: "open Claude" fired early, but "open Claude coworker inside
                    // Claude" means Cowork. If the whole says more than the start did, do that too.
                    guard closed else { break }
                    consumed += c.span
                    liveFired = false
                    let whole = await decide(c.text, whole: false)
                    if typing || gen != pumpGen { break }
                    if let whole, whole != liveFiredPlan {
                        dlog("whole clause says more: \(whole.label)")
                        await fire(whole, said: c.text)
                        if gen != pumpGen { break }
                    }
                    continue
                }
                let plan = await decide(c.text, whole: consumed == 0 && cls.count == 1)
                if typing || gen != pumpGen { break }
                // Mid-clause firing needs two words at least: "Open" alone once opened Terminal.
                var live = !closed && (capabilityByID[plan?.action ?? ""]?.liveOK ?? false)
                    && (plan?.sure ?? false) && c.text.split(separator: " ").count >= 2
                // "open Claude code..." is not "open Claude": opening early needs the app's name to be
                // the last thing said so far.
                if live, plan?.action == "open_app", let name = plan?.app,
                   !normalise(c.text).hasSuffix(normalise(name)) { live = false }
                if let plan, closed || live {
                    if closed { consumed += c.span } else { liveFired = true; liveFiredPlan = plan }
                    await fire(plan, said: c.text)
                    if gen != pumpGen { break }
                    continue
                }
                if closed {
                    consumed += c.span
                    continue
                }
                if words == snapshot.0 && final == snapshot.1 { break }    // wait for more speech
            }
            guard gen == pumpGen else { return }
            busy = false
            if final && !typing { endUtterance() }
        }
    }

    /// Nothing may hold up listening for long. A step that has not finished in 10 seconds is
    /// abandoned, and the next thing you say is heard normally.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Apple's on-device recogniser seldom marks a sentence finished, even after long
                // silence, so "open Dia" said later got glued onto the last sentence. A 1.2s pause
                // ends the sentence here instead.
                if !self.typing, !self.final, !self.words.isEmpty, Date().timeIntervalSince(self.heardAt) > 1.2 {
                    self.final = true
                    self.endedByPause = true
                    self.pump()
                }
                guard self.busy, Date().timeIntervalSince(self.busySince) > 10 else { return }
                dlog("watchdog: a step hung for 10s, abandoning it")
                self.pumpGen += 1
                self.busy = false
                self.problem = "A step took too long and was skipped"
                self.endUtterance()
            }
        }
    }

    private func endUtterance() {
        // After a pause the recogniser carries on with the same transcript, so the next sentence
        // starts where this one stopped. After a real final it starts a new transcript from zero.
        base = endedByPause ? taskWords : 0
        basePrefix = endedByPause ? taskText : []
        endedByPause = false
        liveFired = false
        words = []
        alts = []
        final = false
        consumed = 0
        earlier = []
        focus = nil
        if let w = waiting {
            waiting = nil
            transcript(w.0, w.1, final: w.2)
        }
    }

    // MARK: deciding

    /// Both engines judge every clause, so the notch can show them side by side. Only the chosen
    /// one acts. Rules answer instantly; in Rules mode Jev's verdict is fetched without waiting.
    private func decide(_ text: String, whole: Bool) async -> Plan? {
        let front = focus?.name ?? FrontTracker.shared.last?.localizedName
        // A pop-up in front is what you are answering: "terminate", "don't save", "yes kill it".
        if let pop = Popups.current() {
            let titles = pop.buttons.map(\.title)
            var hit = Popups.match(text, pop)
            if hit == nil, engine == .jev, !key.isEmpty, text.split(separator: " ").count <= 8 {
                let (i, conf) = await jev.choose(
                    said: text, context: ["popup": pop.message, "app": pop.app.localizedName ?? ""],
                    instructions: "A pop-up on screen asks `popup` with these buttons. `said` is what the person said "
                        + "out loud, maybe misheard. Which button are they pressing? 'kill it', 'end it' mean the "
                        + "destructive choice; 'leave it', 'never mind', 'go back' mean cancel.",
                    options: titles, none: "What they said is not an answer to this pop-up.", key: key)
                if let i, conf >= 0.5 { hit = pop.buttons[i] }
            }
            if let hit {
                jevSays = "Press \u{201C}\(hit.title)\u{201D}  (pop-up: \(titles.joined(separator: " / ")))"
                rulesSays = jevSays
                return Plan(action: "popup", text: hit.title)
            }
        }
        // "Yes, trust this folder" answers the list a terminal is showing (Claude Code's prompts).
        if focus == nil, TerminalMenu.applies(text, front: FrontTracker.shared.last) {
            jevSays = "Choose \u{201C}\(text)\u{201D}  (terminal list)"
            rulesSays = jevSays
            return Plan(action: "choose", text: text)
        }
        if !isStartPhrase(text), let n = Guard.navigation(text) {
            jevSays = "\(n.label)  (navigation)"
            rulesSays = jevSays
            return n
        }
        if let d = Guard.direct(text, front: front, apps: apps) {
            jevSays = "\(d.label)  (known place)"
            rulesSays = jevSays
            return d
        }
        let plan = Guard.check(await decideRaw(text, whole: whole), said: text, front: front)
        return inAppEquivalent(plan, said: text)
    }

    /// "Open a new tab in Claude Code": Claude has sessions, not tabs, and ⌘T does nothing there.
    /// A tab or window command aimed at an app SayOpen knows the layout of becomes clicks inside it.
    private func inAppEquivalent(_ plan: Plan?, said: String) -> Plan? {
        guard let plan, let phrase = AppKnowledge.asPlace[plan.action] else { return plan }
        let s = " " + normalise(said) + " "
        let named = AppKnowledge.places.keys.first { s.contains(" \(normalise($0)) ") }
        guard let app = plan.app ?? named ?? focus?.name ?? FrontTracker.shared.last?.localizedName,
              AppKnowledge.places[app] != nil, apps.contains(where: { $0.name == app }) else { return plan }
        let goal = said + " (" + phrase + ")"
        guard !AppKnowledge.route(goal: goal, app: app).isEmpty else { return plan }
        return Plan(action: "in_app", app: app, text: goal)
    }

    private func decideRaw(_ text: String, whole: Bool) async -> Plan? {
        // Starting voice typing is a fixed phrase, like stopping it, and the same for both engines:
        // "open Wispr Flow" is heard as whisker flo, whisper flow, wisp flow...
        if isStartPhrase(text) {
            jevSays = "Voice typing  (start phrase)"
            rulesSays = "Voice typing  (start phrase)"
            return Plan(action: "dictate")
        }
        // "Open Cowork" is a place inside Claude, not an app called Cowork: no engine needed.
        if let owner = AppKnowledge.owner(of: text), apps.contains(where: { $0.name == owner }) {
            jevSays = "In \(owner): \(text)  (known place)"
            rulesSays = jevSays
            return Plan(action: "in_app", app: owner, text: text)
        }
        let r = Rules.decide(text, apps: apps)
        rulesSays = r?.label ?? "\u{2014}"
        switch engine {
        case .rules:
            if hasKey { Task { _ = await jevPlan(text, whole: whole) } }
            return r
        case .jev:
            return await jevPlan(text, whole: whole)
        }
    }

    private func jevPlan(_ text: String, whole: Bool) async -> Plan? {
        // Code fast path, part of the Jev engine: "open Slack" needs no model.
        if let a = exactMatch(text, apps) {
            jevSays = "Open \(a.name)  (exact name)"
            return Plan(action: "open_app", app: a.name)
        }
        if whole, let alt = alts.first, let a = exactMatch(alt, apps.filter { $0.uses > 0 }) {
            jevSays = "Open \(a.name)  (heard as \u{201C}\(alt)\u{201D})"
            return Plan(action: "open_app", app: a.name)
        }
        guard !key.isEmpty else { jevSays = "no key"; return nil }
        let cacheKey = text.lowercased() + "|" + earlier.joined(separator: ",")
        if let hit = jevCache[cacheKey] { return hit }
        do {
            calls += 1
            let front = focus?.name ?? FrontTracker.shared.last?.localizedName
            let v = try await jev.decide(text, earlier: earlier, front: front,
                                         alternatives: whole ? Array(alts.prefix(2)) : [], key: key)
            dlog("jev: \"\(text)\" -> \(v.plan?.label ?? "nothing") (\(v.why), \(v.ms)ms)")
            jevSays = v.plan?.label ?? "\u{2014}"
            jevCache[cacheKey] = v.plan
            return v.plan
        } catch {
            dlog("jev error: \(error.localizedDescription)")
            problem = error.localizedDescription
            return nil
        }
    }

    // MARK: acting

    private func fire(_ plan: Plan, said: String) async {
        // The recogniser re-sends a sentence it already sent ("add a new tab", then "tab", then
        // "Add a new tab" as a fresh transcript). The same action twice within 4s is that, not you.
        // In-app goals are resent with slightly different words ("OK open Claude code…"), so they
        // count as the same by action and app.
        let byKind: Set<String> = ["in_app", "open_file", "web_search", "youtube_search", "open_website", "new_note", "new_reminder"]
        // Known places compare by where they go: "open cowork" then "new tab in Claude Code" are two
        // commands, not one said twice.
        let route = plan.action == "in_app" ? AppKnowledge.route(goal: plan.text ?? "", app: plan.app ?? "") : []
        let repeatKey = !route.isEmpty ? "in_app|\(plan.app ?? "")|\(route.joined(separator: ","))"
            : byKind.contains(plan.action) ? "\(plan.action)|\(plan.app ?? "")" : plan.label
        // Scrolling, arrows, volume and skipping are said again on purpose ("scroll down... scroll
        // down"); the recogniser's own resends of a sentence come within about a second.
        let again: Set<String> = ["scroll", "key", "volume", "media", "brightness", "press_enter", "next_tab", "previous_tab"]
        let window: TimeInterval = again.contains(plan.action) ? 1.2 : 6
        if let last = recentFires[repeatKey], Date().timeIntervalSince(last) < window {
            dlog("skip repeat: \(plan.label) for \"\(said)\"")
            return
        }
        recentFires[repeatKey] = Date()
        awakeUntil = Date().addingTimeInterval(6)
        let startsTyping = plan.action == "dictate" || (plan.action == "open_app" && plan.app == "Wispr Flow")
        if startsTyping { beginTyping() }
        let out = await Executor.run(plan, apps: apps, focus: focus)
        let now = Date()
        dlog("\(out.ok ? "DID" : "FAILED") \(plan.label) via \(engine.rawValue) for \"\(said)\" \(out.note)")
        if let f = out.focus { focus = f }
        earlier.append(plan.label)
        let o = Opening(app: out.ok ? plan.label : "\(plan.label): \(out.note)", path: out.icon ?? Bundle.main.bundlePath,
                        at: now, ms: Int(now.timeIntervalSince(heardAt) * 1000),
                        how: engine == .jev ? "Jev" : "Rules", said: said)
        history.insert(o, at: 0)
        if history.count > 50 { history.removeLast() }
        History.append(o)
        lastOpenedAt = now
        if !out.ok {
            problem = out.note
            if startsTyping { stopTyping(pressShortcut: false) }
        }
        trusted = AXIsProcessTrusted()
    }

    // MARK: voice typing

    /// Wispr Flow opened or closed the mic. When you start it yourself, SayOpen drops whatever
    /// it was half-way through and ignores speech until Wispr stops; then it throws away what it
    /// heard meanwhile and listens for commands again.
    private func wisprChanged(_ on: Bool) {
        wisprOn = on
        dlog("wispr mic \(on ? "on" : "off")\(typing ? " (SayOpen voice typing)" : "")")
        if on {
            guard !typing else { return }
            dictationStartedAt = Date()
            pumpGen += 1
            busy = false
            final = false
            endUtterance()
            heard = ""
        } else {
            quietUntil = Date().addingTimeInterval(0.6)
            if typing {
                stopTyping(pressShortcut: false)   // you stopped Wispr yourself; pressing would restart it
            } else {
                endUtterance()
                listener.restart()
                heard = ""
            }
        }
    }

    private func beginTyping() {
        typing = true
        dictationStartedAt = Date()
        heard = ""
        listener.restart()                    // what is said from here on is dictation, not commands
        dlog("typing mode on")
    }

    private func isStartPhrase(_ text: String) -> Bool {
        let s = normalise(text)
        return [#"^(please )?(open|start|launch|begin|use)( the)? [a-z]*(is|isp|isk)[a-z]* ?flow?$"#,
                #"^[a-z]*(is|isp|isk)[a-z]* ?flow? (kholo|khol do|chalu karo|start karo)$"#]
            .contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    /// "close Wispr Flow", "stop typing" and the like, at the end of what was just said.
    /// A fixed phrase on purpose: it is a stop word heard during dictation, not a request to judge.
    private func isStopPhrase(_ text: String) -> Bool {
        let s = normalise(text)
        // Speech recognition hears "Wispr" as whisper, whisker, wisp, visper...: any such word
        // counts when "flow" follows it.
        // Heard so far as: close whisper, close whisker flo, close workflow, close prof... Any
        // "close/stop ... flow" ending counts, so a dictated sentence ending "close the workflow"
        // would also stop; that is the trade for catching the misheard name every time.
        let patterns = [#"\b(close|stop|end|exit|finish|quit)( the)? (wispr|whisper|wisper|visper|whisker)$"#,
                        #"\b(close|stop|end|exit|finish|quit)( the)? ([a-z]+ )?[a-z]*flow?$"#,
                        #"\b[a-z]*(is|isp|isk)[a-z]* ?flow? (band|band karo|close|stop)$"#,
                        #"\b(stop|done|finish|finished|end) (typing|dictation|dictating)$"#,
                        // While Wispr has the mic this recogniser often drops the first word, so
                        // "close Wispr Flow" arrives as just "Whisper glow". The name at the end is enough.
                        #"\b(wispr|whisper|wisper|whisker|visper|wisp)( |)(flow|flo|glow|low|flu|slow)$"#]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    /// Ends a dictation by voice. Wispr pastes into whatever you were dictating into, then the
    /// stop phrase it also typed is taken back out with Backspace.
    private func finishDictation(said: String) {
        let since = dictationStartedAt
        dlog("stop phrase heard: \"\(said)\"")
        if typing {
            stopTyping(pressShortcut: true)
        } else {
            if MicWatch.shared.wisprActive { Dictation.toggle() }
            quietUntil = Date().addingTimeInterval(1.2)
            endUtterance()
            listener.restart()
            heard = ""
        }
        let o = Opening(app: "Close Wispr Flow", path: apps.first { $0.name == Dictation.appName }?.url.path ?? Bundle.main.bundlePath,
                        at: Date(), ms: 0, how: "stop phrase", said: said)
        history.insert(o, at: 0)
        History.append(o)
        lastOpenedAt = Date()
        Task { await Dictation.trimSpokenStop(since: since) }
    }

    /// Ends SayOpen's voice-typing mode. Wispr is pressed off only if it is still dictating.
    func stopTyping(pressShortcut: Bool = true) {
        if pressShortcut && MicWatch.shared.wisprActive { Dictation.toggle() }
        typing = false
        heard = ""
        quietUntil = Date().addingTimeInterval(1.2)
        endUtterance()
        listener.restart()
        dlog("typing mode off")
    }
}
