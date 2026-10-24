import AppKit
import ApplicationServices
import Foundation

// What SayOpen can do. Both engines (Jev and the hand-written rules) produce the same Plan,
// and one executor carries it out, so the comparison is only ever about the deciding.

enum Need { case nothing, app, text, setting(String) }

struct Capability {
    let id: String
    let say: String            // shown to Jev as the meaning of this option
    let need: Need
    var liveOK = false         // may fire before the speaker finishes the clause
}

let settingOptions: [String: [String: String]] = [
    "volume": ["up": "louder, turn it up", "down": "quieter, turn it down", "mute": "mute, silence, no sound",
               "unmute": "unmute, sound back on", "low": "low or quiet level", "half": "half, 50 percent, medium",
               "max": "maximum, full volume"],
    "media": ["play_pause": "play, pause, resume, stop the music", "next": "next or skip track",
              "previous": "previous track, go back a song"],
    "brightness": ["up": "brighter screen", "down": "dimmer screen"],
    "appearance": ["dark": "dark mode, night mode", "light": "light mode, day mode"],
    "scroll": ["down": "scroll down, further down the page", "up": "scroll up, back up the page",
               "top": "to the top", "bottom": "to the bottom, the end"],
    "key": ["up": "up arrow, move up, previous option", "down": "down arrow, move down, next option",
            "left": "left arrow", "right": "right arrow", "escape": "escape, esc, cancel the prompt",
            "tab": "tab key, move to the next link, button or field (the one Enter will press)",
            "shift_tab": "shift-tab, move back to the previous link, button or field",
            "space": "space bar", "backspace": "backspace, delete a character"],
    "folder": ["downloads": "Downloads folder", "desktop": "Desktop folder", "documents": "Documents folder",
               "applications": "Applications folder", "home": "home folder"],
]

let capabilities: [Capability] = [
    Capability(id: "open_app", say: "Open, launch or switch to an application itself (not a mode, page or file inside it).",
               need: .app, liveOK: true),
    Capability(id: "in_app", say: "Click through something inside an app's own screens: a mode, tab, page, button, "
               + "chat, project, profile or text box in it (e.g. 'open Claude Code inside Claude', 'compose a new mail').",
               need: .nothing),
    Capability(id: "open_file", say: "Open a saved document or file by its name.", need: .text),
    Capability(id: "quit_app", say: "Quit or close an application entirely.", need: .app),
    Capability(id: "new_tab", say: "Open a new tab, in a browser, Terminal, Finder or whichever app is meant.",
               need: .nothing),
    Capability(id: "close_tab", say: "Close the current tab.", need: .nothing),
    Capability(id: "reopen_tab", say: "Bring back the tab that was just closed.", need: .nothing),
    Capability(id: "next_tab", say: "Switch to the next tab.", need: .nothing),
    Capability(id: "previous_tab", say: "Switch to the previous tab.", need: .nothing),
    Capability(id: "reload", say: "Reload or refresh the page.", need: .nothing, liveOK: true),
    Capability(id: "go_back", say: "Go back a page.", need: .nothing, liveOK: true),
    Capability(id: "go_forward", say: "Go forward a page.", need: .nothing, liveOK: true),
    Capability(id: "new_window", say: "Open a new window of the app in front or the app named.", need: .nothing),
    Capability(id: "close_window", say: "Close the current window.", need: .nothing),
    Capability(id: "minimize", say: "Minimise the current window.", need: .nothing, liveOK: true),
    Capability(id: "fullscreen", say: "Make the current window full screen, or leave full screen.", need: .nothing, liveOK: true),
    Capability(id: "open_website", say: "Open a website by name or address, e.g. youtube, gmail, amazon.in.", need: .text),
    Capability(id: "web_search", say: "Search the web for something.", need: .text),
    Capability(id: "youtube_search", say: "Search YouTube for a video.", need: .text),
    Capability(id: "new_note", say: "Write a new note in Notes with the words the speaker dictated.", need: .text),
    Capability(id: "new_reminder", say: "Add a reminder with the words the speaker dictated.", need: .text),
    Capability(id: "dictate", say: "Start voice typing into the app in front, e.g. 'let me type', 'open Wispr Flow so I "
               + "can type', 'start dictation'.", need: .nothing, liveOK: true),
    Capability(id: "scroll", say: "Scroll the page or window up or down, or to the top or bottom.",
               need: .setting("scroll")),
    Capability(id: "key", say: "Press a navigation key: arrow up/down/left/right, Escape, Tab, Space, Backspace "
               + "(e.g. 'move down', 'press escape', 'go up one').", need: .setting("key")),
    Capability(id: "press_enter", say: "Press Enter or Return, e.g. 'run it', 'hit enter', 'send it'.", need: .nothing, liveOK: true),
    Capability(id: "volume", say: "Change the speaker volume, or mute or unmute.", need: .setting("volume"), liveOK: true),
    Capability(id: "media", say: "Play, pause, skip or go back a track in whatever is playing.", need: .setting("media"), liveOK: true),
    Capability(id: "brightness", say: "Make the screen brighter or dimmer.", need: .setting("brightness"), liveOK: true),
    Capability(id: "appearance", say: "Switch between dark mode and light mode.", need: .setting("appearance"), liveOK: true),
    Capability(id: "open_folder", say: "Open a folder such as Downloads, Desktop or Documents.", need: .setting("folder"), liveOK: true),
    Capability(id: "screenshot", say: "Take a screenshot.", need: .nothing, liveOK: true),
    Capability(id: "lock_screen", say: "Lock the screen.", need: .nothing, liveOK: true),
]
let capabilityByID = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.id, $0) })

struct Plan: Equatable {
    var action: String
    var app: String? = nil          // a named app: to open, quit, or to act inside
    var text: String? = nil         // dictated content: a query, a note, a site
    var setting: String? = nil
    var sure = true                 // confident enough to act before the speaker finishes the clause

    static func == (l: Plan, r: Plan) -> Bool { l.label == r.label }

    var label: String {
        let a = app ?? ""
        let t = "\u{201C}\(text ?? "")\u{201D}"
        switch action {
        case "open_app": return "Open \(a)"
        case "choose": return "Choose \(t)"
        case "popup": return "Press \(t)"
        case "in_app": return app == nil ? "In app: \(text ?? "")" : "In \(a): \(text ?? "")"
        case "open_file": return "Open file \(t)"
        case "quit_app": return "Quit \(a)"
        case "new_tab": return app == nil ? "New tab" : "New tab in \(a)"
        case "close_tab": return "Close tab"
        case "reopen_tab": return "Reopen closed tab"
        case "next_tab": return "Next tab"
        case "previous_tab": return "Previous tab"
        case "reload": return "Reload"
        case "go_back": return "Back"
        case "go_forward": return "Forward"
        case "new_window": return app == nil ? "New window" : "New \(a) window"
        case "close_window": return "Close window"
        case "minimize": return "Minimise"
        case "fullscreen": return "Full screen"
        case "open_website": return "Open \(text ?? "site")"
        case "web_search": return "Search \(t)"
        case "youtube_search": return "YouTube \(t)"
        case "new_note": return "Note \(t)"
        case "new_reminder": return "Reminder \(t)"
        case "dictate": return "Voice typing"
        case "press_enter": return "Press Enter"
        case "scroll": return "Scroll \(setting ?? "")" + (text.map { " x\($0)" } ?? "")
        case "open_page": return "Open page \(t)"
        case "key": return "Press \(setting ?? "") \(text.map { "x\($0)" } ?? "")".trimmingCharacters(in: .whitespaces)
        case "switch_tab": return "Tab \(setting ?? "")"
        case "volume": return "Volume \(setting ?? "")"
        case "media": return (setting ?? "").replacingOccurrences(of: "_", with: "/").capitalized
        case "brightness": return "Brightness \(setting ?? "")"
        case "appearance": return (setting == "dark" ? "Dark" : "Light") + " mode"
        case "open_folder": return "Open \((setting ?? "").capitalized)"
        case "screenshot": return "Screenshot"
        case "lock_screen": return "Lock screen"
        default: return action
        }
    }
}

// MARK: - Front app tracking

/// The app you were last using. SayOpen's own Settings window must never count, or
/// "new tab" would go to SayOpen.
@MainActor
final class FrontTracker {
    static let shared = FrontTracker()
    private var remembered: NSRunningApplication? = NSWorkspace.shared.frontmostApplication

    /// The app in front right now. Only when that is SayOpen itself (its Settings window) does the
    /// remembered one stand in. A remembered app went stale once and dictation landed in Terminal.
    var last: NSRunningApplication? {
        if let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != Bundle.main.bundleIdentifier { return f }
        return remembered
    }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { self.remembered = app }
            }
        }
    }
}

// MARK: - Executor

@MainActor
enum Executor {
    struct Outcome {
        var ok: Bool
        var note: String = ""
        var icon: String? = nil       // a bundle path, for the notch
        var focus: AppEntry? = nil    // the app this left in front, for "new tab" said next
    }

    /// Set by the brain: which engine chooses the clicks for "in_app". (goal, app name) -> picker.
    static var uiPicker: ((String, String) -> ([String], [String]) async -> Int?)?
    /// Set by the brain: Jev's pick among things on screen. (said, options, what they are) -> index.
    static var chooser: ((String, [String], String) async -> Int?)?
    /// Set by the brain: which engine picks among files matching what you said. (said, labels) -> index.
    static var filePicker: ((String, [String]) async -> Int?)?

    static func run(_ p: Plan, apps: [AppEntry], focus: AppEntry?) async -> Outcome {
        let named = p.app.flatMap { n in apps.first { $0.name == n } }
        switch p.action {
        case "open_app":
            guard let a = named else { return Outcome(ok: false, note: "no app") }
            if a.name == Dictation.appName { return await Dictation.start(apps: apps) }
            launch(a.url, activate: true)
            return Outcome(ok: true, icon: a.url.path, focus: a)

        case "quit_app":
            // "close Wispr Flow" means finish dictating (handled as a stop phrase while dictating),
            // never quit the app that does the typing.
            if named?.name == Dictation.appName { return Outcome(ok: false, note: "Wispr is not dictating") }
            guard let a = named, let bid = Bundle(url: a.url)?.bundleIdentifier else { return Outcome(ok: false, note: "no app") }
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).forEach { $0.terminate() }
            return Outcome(ok: true, icon: a.url.path)

        case "new_tab", "close_tab", "reopen_tab", "next_tab", "previous_tab", "reload", "go_back", "go_forward",
             "new_window", "close_window", "minimize", "fullscreen", "press_enter":
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            let target = named ?? focus ?? currentFront(apps)
            if let target { guard await bringToFront(target) else { return Outcome(ok: false, note: "\(target.name) did not come forward") } }
            let browser = target.map(Browsers.isBrowser) ?? false
            // Prefer clicking the app's own menu item ("Shell > New Tab" in Terminal, "File > New Tab"
            // in browsers): it works while the app is still coming forward, where a keystroke is lost.
            if let target, let m = menuFor[p.action],
               let pid = runningApp(target)?.processIdentifier,
               ({ Menus.focusFrontWindow(pid: pid); return true }()),
               Menus.press(pid: pid, shortcut: m.key, mods: m.mods, titles: m.titles) {
                dlog("\(p.action): clicked menu item in \(target.name)")
                return Outcome(ok: true, icon: target.url.path, focus: target)
            }
            dlog("\(p.action): no menu item found, sending the shortcut to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (target \(target?.name ?? "none"))")
            switch p.action {
            case "new_tab": Keys.press(17, .maskCommand)
            case "close_tab": Keys.press(13, .maskCommand)
            case "reopen_tab": Keys.press(17, [.maskCommand, .maskShift])
            case "next_tab": Keys.press(48, .maskControl)
            case "previous_tab": Keys.press(48, [.maskControl, .maskShift])
            case "reload": Keys.press(15, .maskCommand)
            case "go_back": Keys.press(33, .maskCommand)
            case "go_forward": Keys.press(30, .maskCommand)
            case "new_window": Keys.press(45, .maskCommand)
            case "close_window": Keys.press(13, browser ? [.maskCommand, .maskShift] : .maskCommand)
            case "minimize": Keys.press(46, .maskCommand)
            case "fullscreen": Keys.press(3, [.maskCommand, .maskControl])
            default: Keys.press(36, [])        // Return
            }
            return Outcome(ok: true, icon: target?.url.path, focus: target)

        case "scroll":
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            for i in 0 ..< min(max(Int(p.text ?? "") ?? 1, 1), 10) {
                if i > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
                Scroll.run(p.setting ?? "down")
            }
            return Outcome(ok: true)

        case "open_page":
            guard let (name, kind) = PageHistory.parse(p.text ?? "") else { return Outcome(ok: false, note: "which page?") }
            let browser = [named, focus, currentFront(apps)].compactMap { $0 }.first(where: Browsers.isBrowser)
                ?? apps.first { $0.name == "Dia" } ?? Browsers.defaultBrowser(apps)
            guard let b = browser else { return Outcome(ok: false, note: "no browser") }
            guard let page = PageHistory.find(name, kind: kind, browser: b.name) else {
                return Outcome(ok: false, note: "no \(kind ?? "page") called \(name) in \(b.name) history")
            }
            dlog("open_page: \"\(name)\" -> \(page.title) \(page.url.prefix(80))")
            // Already open in a tab: go to that tab instead of opening a second copy.
            if let pid = runningApp(b)?.processIdentifier {
                // Dia's tab says "Roadmap 2.0" where the page title says "Roadmap 2.0 - Google Sheets".
                let title = PageHistory.words(page.title)
                if let tab = UIScan.clickables(pid: pid, limit: 2000).first(where: { c in
                    guard c.label.hasPrefix("tab: ") else { return false }
                    let t = PageHistory.words(String(c.label.dropFirst(5)))
                    return !t.isEmpty && title.starts(with: t) && t.count * 2 >= min(title.count, 6) }) {
                    _ = await bringToFront(b)
                    if UIScan.press(tab) { return Outcome(ok: true, note: "tab \(page.title)", icon: b.url.path, focus: b) }
                }
            }
            guard let url = URL(string: page.url) else { return Outcome(ok: false, note: "bad address") }
            NSWorkspace.shared.open([url], withApplicationAt: b.url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err { dlog("open \(url) in \(b.name): \(err.localizedDescription)") }
            }
            return Outcome(ok: true, note: page.title, icon: b.url.path, focus: b)

        case "key":
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            if let t = named ?? focus, !(await bringToFront(t)) { return Outcome(ok: false, note: "\(t.name) did not come forward") }
            let codes: [String: CGKeyCode] = ["up": 126, "down": 125, "left": 123, "right": 124, "escape": 53,
                                              "tab": 48, "space": 49, "backspace": 51]
            let shifted = p.setting == "shift_tab"
            guard let code = shifted ? 48 : codes[p.setting ?? ""] else { return Outcome(ok: false, note: "which key?") }
            for _ in 0 ..< min(max(Int(p.text ?? "") ?? 1, 1), 20) {
                Keys.press(code, shifted ? .maskShift : [])
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return Outcome(ok: true)

        case "switch_tab":
            // Cmd+1...8 is that tab and Cmd+9 the last, in browsers, Terminal and most tabbed apps.
            guard Keys.trusted(), let n = Int(p.setting ?? ""), (1 ... 9).contains(n) else { return Outcome(ok: false, note: "which tab?") }
            Keys.press([18, 19, 20, 21, 23, 22, 26, 28, 25][n - 1], .maskCommand)
            return Outcome(ok: true)

        case "open_website", "web_search", "youtube_search":
            let q = (p.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, let url = webURL(p.action, q) else { return Outcome(ok: false, note: "nothing to search") }
            let browser = [named, focus, currentFront(apps)].compactMap { $0 }.first(where: Browsers.isBrowser)
                ?? Browsers.defaultBrowser(apps)
            let cfg = NSWorkspace.OpenConfiguration()
            if let b = browser {
                NSWorkspace.shared.open([url], withApplicationAt: b.url, configuration: cfg) { _, err in
                    if let err { dlog("open \(url) in \(b.name): \(err.localizedDescription)") }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            return Outcome(ok: true, icon: browser?.url.path, focus: browser)

        case "new_note":
            let t = esc(p.text ?? "")
            let err = await osascript("""
                tell application "Notes"
                    activate
                    set n to make new note with properties {body:"<div>\(t)</div>"}
                    show n
                end tell
                """)
            return Outcome(ok: err == nil, note: err ?? "", icon: "/System/Applications/Notes.app")

        case "new_reminder":
            let err = await osascript("tell application \"Reminders\" to make new reminder with properties {name:\"\(esc(p.text ?? ""))\"}")
            return Outcome(ok: err == nil, note: err ?? "", icon: "/System/Applications/Reminders.app")

        case "dictate":
            return await Dictation.start(apps: apps)

        case "open_file":
            let q = p.text ?? ""
            // Off the main thread: the first time, macOS asks for folder access and waits for you.
            let found = await Task.detached { FileSearch.askForFolders(); return FileSearch.find(q) }.value
            dlog("open_file \"\(q)\": \(found.count) matches")
            guard !found.isEmpty else { return Outcome(ok: false, note: "no file matching \(q)") }
            let labels = found.map(FileSearch.describe)
            // Jev chooses among the candidates. If it cannot be reached, the best-ranked one opens.
            let picked = await filePicker?(q, labels) ?? 0
            let i = picked < found.count ? picked : 0
            dlog("open_file picked \(found[i].lastPathComponent) of \(found.count)")
            let (file, app) = FileSearch.desktopOpen(found[i])
            if file != found[i] { dlog("open_file: \(found[i].lastPathComponent) would open in a browser, opening \(file.lastPathComponent)") }
            if let app {
                _ = try? await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(file)
            }
            let shown = app ?? NSWorkspace.shared.urlForApplication(toOpen: file)
            return Outcome(ok: true, note: file.lastPathComponent, icon: shown?.path)

        case "popup":
            guard let pop = Popups.current(), let b = pop.buttons.first(where: { $0.title == p.text }) else {
                return Outcome(ok: false, note: "the pop-up is gone")
            }
            let ok = Popups.press(b)
            return Outcome(ok: ok, note: ok ? b.title : "could not press \(b.title)", icon: pop.app.bundleURL?.path)

        case "choose":
            guard let front = FrontTracker.shared.last else { return Outcome(ok: false, note: "no terminal in front") }
            return await TerminalMenu.choose(p.text ?? "", app: front)

        case "in_app":
            let goal = p.text ?? ""
            // An app counts only if you said its name ("inside Claude"). "start drafting a new mail"
            // means the web mail in front, not Apple Mail.
            // Named only as a place: "in Claude", "inside Claude", "on Slack". An app called "Mail"
            // must not win because the words "a new mail" were said.
            let said = " " + normalise(goal) + " "
            let mentioned = named.flatMap { app -> AppEntry? in
                let n = normalise(app.name)
                return said.range(of: " (in|inside|on|within|into) (the )?\(n)( app)? ", options: .regularExpression) != nil
                    ? app : nil
            }
            // A place SayOpen knows ("open cowork") belongs to its app whatever is in front.
            let owner = named.flatMap { AppKnowledge.route(goal: goal, app: $0.name).isEmpty ? nil : $0 }
            guard let target = mentioned ?? owner ?? focus ?? currentFront(apps) else { return Outcome(ok: false, note: "no app") }
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            let pick = uiPicker?(goal, target.name) ?? UIAgent.rulesPick(goal: goal, appName: target.name)
            return await UIAgent.run(goal: goal, app: target, pick: pick)

        case "volume":
            guard Keys.trusted() || ["low", "half", "max", "mute", "unmute"].contains(p.setting ?? "")
            else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            switch p.setting {
            case "up": for _ in 0 ..< 3 { Keys.media(0) }
            case "down": for _ in 0 ..< 3 { Keys.media(1) }
            case "mute": _ = await osascript("set volume with output muted")
            case "unmute": _ = await osascript("set volume without output muted")
            case "low": _ = await osascript("set volume output volume 20 without output muted")
            case "half": _ = await osascript("set volume output volume 50 without output muted")
            case "max": _ = await osascript("set volume output volume 100 without output muted")
            default: return Outcome(ok: false, note: "which volume?")
            }
            return Outcome(ok: true)

        case "media":
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            Keys.media(p.setting == "next" ? 17 : p.setting == "previous" ? 18 : 16)
            return Outcome(ok: true)

        case "brightness":
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            for _ in 0 ..< 3 { Keys.media(p.setting == "down" ? 3 : 2) }
            return Outcome(ok: true)

        case "appearance":
            let err = await osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(p.setting == "dark")")
            return Outcome(ok: err == nil, note: err ?? "")

        case "open_folder":
            let fm = FileManager.default
            let url: URL
            switch p.setting {
            case "downloads": url = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            case "desktop": url = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            case "documents": url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            case "applications": url = URL(fileURLWithPath: "/Applications")
            default: url = fm.homeDirectoryForCurrentUser
            }
            NSWorkspace.shared.open(url)
            return Outcome(ok: true, icon: "/System/Library/CoreServices/Finder.app")

        case "screenshot":
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let path = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SayOpen \(f.string(from: Date())).png").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", path]
            try? p.run()
            return Outcome(ok: true, note: "saved to Desktop")

        case "lock_screen":
            guard Keys.trusted() else { return Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
            Keys.press(12, [.maskCommand, .maskControl])       // ctrl-cmd-Q
            return Outcome(ok: true)

        default:
            return Outcome(ok: false, note: "can't do that yet")
        }
    }

    /// Asks macOS to open an app and does not wait for the answer. The async form of this call
    /// sometimes never returns ("Open Dia" froze SayOpen); callers that need the app in front
    /// poll for it with a time limit instead.
    static func launch(_ url: URL, activate: Bool) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err { dlog("launch \(url.lastPathComponent): \(err.localizedDescription)") }
        }
    }

    /// Menu items to click, found by their keyboard shortcut first (the same in every language),
    /// then by title. mods: 0 = cmd, 1 = shift+cmd, 4 = ctrl+cmd, 8 = no cmd.
    static let menuFor: [String: (key: String, mods: Int, titles: [String])] = [
        "new_tab": ("T", 0, ["New Tab"]),
        "close_tab": ("W", 0, ["Close Tab"]),
        "reopen_tab": ("T", 1, ["Reopen Closed Tab", "Reopen Last Closed Tab"]),
        "reload": ("R", 0, ["Reload Page", "Reload This Page", "Reload"]),
        "go_back": ("[", 0, ["Back"]),
        "go_forward": ("]", 0, ["Forward"]),
        "new_window": ("N", 0, ["New Window"]),
        "minimize": ("M", 0, ["Minimize", "Minimise"]),
        "fullscreen": ("F", 4, ["Enter Full Screen", "Exit Full Screen", "Toggle Full Screen"]),
        "next_tab": ("", 0, ["Show Next Tab", "Select Next Tab", "Next Tab"]),
        "previous_tab": ("", 0, ["Show Previous Tab", "Select Previous Tab", "Previous Tab"]),
    ]

    static func runningApp(_ a: AppEntry) -> NSRunningApplication? {
        guard let bid = Bundle(url: a.url)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
    }

    static func currentFront(_ apps: [AppEntry]) -> AppEntry? {
        guard let url = FrontTracker.shared.last?.bundleURL else { return nil }
        return apps.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? AppEntry(name: url.deletingPathExtension().lastPathComponent, url: url, category: nil, uses: 0, agent: false)
    }

    /// Launch or activate, then wait until it really is in front, because keystrokes go to whatever is.
    static func bringToFront(_ a: AppEntry) async -> Bool {
        let bid = Bundle(url: a.url)?.bundleIdentifier
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid { return true }
        // "Open" it the way the Dock does. A background app calling activate() on another app is
        // often refused on recent macOS ("Claude did not come forward").
        launch(a.url, activate: true)
        if let bid { NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.activate(options: [.activateAllWindows]) }
        for _ in 0 ..< 40 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid {
                try? await Task.sleep(nanoseconds: 250_000_000)    // let its window take key focus
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    static func webURL(_ action: String, _ q: String) -> URL? {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        switch action {
        case "web_search": return URL(string: "https://www.google.com/search?q=\(enc)")
        case "youtube_search": return URL(string: "https://www.youtube.com/results?search_query=\(enc)")
        default:
            let s = q.lowercased().replacingOccurrences(of: " dot ", with: ".")
            if s.contains("."), !s.contains(" ") { return URL(string: s.hasPrefix("http") ? s : "https://\(s)") }
            // One word is a site's own name: gmail.com lands in your inbox, where the first search
            // result for "gmail" was Google's marketing page.
            if s.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil { return URL(string: "https://\(s).com") }
            // DuckDuckGo's "\" jumps straight to the first result: "gmail" lands on Gmail.
            let bang = ("\\" + q).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
            return URL(string: "https://duckduckgo.com/?q=\(bang)")
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs AppleScript out of process. Returns the error text, or nil on success.
    static func osascript(_ script: String) async -> String? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: proc.terminationStatus == 0 ? nil : msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do { try p.run() } catch { cont.resume(returning: error.localizedDescription) }
        }
    }
}

// MARK: - Keys

enum Keys {
    /// Keystrokes need Accessibility. The first time, macOS shows its prompt.
    static func trusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

    /// A real key press: down, a short hold, up. Chromium-based apps (Dia, Chrome) ignore a
    /// key-up that lands in the same instant as its key-down.
    static func press(_ code: CGKeyCode, _ flags: CGEventFlags, pid: pid_t? = nil) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            if let pid { e?.postToPid(pid) } else { e?.post(tap: .cghidEventTap) }
            if down { usleep(30_000) }
        }
    }

    /// Types text as keystrokes, for tests.
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text.utf16 {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                var c = ch
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e?.post(tap: .cghidEventTap)
                usleep(8_000)
            }
        }
    }

    /// Hardware media keys: volume 0/1, brightness 2/3, mute 7, play 16, next 17, previous 18.
    static func media(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// A chord of macOS virtual key codes, modifiers included (63 = fn, 55 = cmd, 56 = shift,
    /// 58 = option, 59 = control). Modifiers go down first and come up last.
    static func chord(_ codes: [Int]) {
        let modFlag: [Int: CGEventFlags] = [63: .maskSecondaryFn, 55: .maskCommand, 56: .maskShift,
                                            58: .maskAlternate, 59: .maskControl]
        let mods = codes.filter { modFlag[$0] != nil }
        let keys = codes.filter { modFlag[$0] == nil }
        let src = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        for m in mods {
            flags.insert(modFlag[m]!)
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(m), keyDown: true)
            e?.type = .flagsChanged
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        for k in keys {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: down)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
            }
        }
        for m in mods.reversed() {
            flags.remove(modFlag[m]!)
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(m), keyDown: false)
            e?.type = .flagsChanged
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Menus

/// Clicks a menu item in another app through the Accessibility API, the way you would with
/// the mouse. Terminal's "New Tab" is a submenu of profiles; its default entry carries cmd-T.
enum Menus {
    /// Makes the app's front window the focused one. Terminal turns "New Tab" into a new window
    /// when none of its windows is focused, which is the state just after it is brought forward.
    static func focusFrontWindow(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        let wins: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        guard let w = wins.first(where: { (attr($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String })
            ?? wins.first else { return }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    static func press(pid: pid_t, shortcut: String, mods: Int, titles: [String]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute) else { return false }
        var byTitle: AXUIElement?
        var found: AXUIElement?
        walk(bar, depth: 0) { item in
            let enabled: Bool = attr(item, kAXEnabledAttribute) ?? false
            guard enabled else { return false }
            if !shortcut.isEmpty,
               let ch: String = attr(item, kAXMenuItemCmdCharAttribute), ch.uppercased() == shortcut,
               let m: Int = attr(item, kAXMenuItemCmdModifiersAttribute), m == mods {
                found = item
                return true
            }
            if byTitle == nil, let t: String = attr(item, kAXTitleAttribute),
               titles.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                let kids: [AXUIElement] = attr(item, kAXChildrenAttribute) ?? []
                if kids.isEmpty { byTitle = item }      // a submenu title is not something to press
            }
            return false
        }
        guard let target = found ?? byTitle else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    /// Every menu item with its shortcut, for `--menus AppName OUT`.
    static func dump(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute) else { return ["no menu bar (Accessibility?)"] }
        var out: [String] = []
        walk(bar, depth: 0) { item in
            let t: String = attr(item, kAXTitleAttribute) ?? ""
            let ch: String = attr(item, kAXMenuItemCmdCharAttribute) ?? ""
            let m: Int = attr(item, kAXMenuItemCmdModifiersAttribute) ?? -1
            let kids: [AXUIElement] = attr(item, kAXChildrenAttribute) ?? []
            if !t.isEmpty { out.append("\(t)\t\(ch)\t\(m)\t\(kids.isEmpty ? "" : "submenu")") }
            return false
        }
        return out
    }

    /// Depth-first over the menu bar; `visit` returns true to stop.
    @discardableResult
    private static func walk(_ el: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Bool) -> Bool {
        guard depth < 6 else { return false }
        let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
        for k in kids {
            let role: String = attr(k, kAXRoleAttribute) ?? ""
            if role == kAXMenuItemRole as String, visit(k) { return true }
            if walk(k, depth: depth + 1, visit) { return true }
        }
        return false
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return (v as! AXUIElement) as? T }
        return v as? T
    }
}

// MARK: - Browsers

enum Browsers {
    static let all: Set<String> = {
        guard let probe = URL(string: "https://example.com"),
              let urls = LSCopyApplicationURLsForURL(probe as CFURL, .viewer)?.takeRetainedValue() as? [URL]
        else { return [] }
        return Set(urls.map { $0.standardizedFileURL.path })
    }()

    static func isBrowser(_ a: AppEntry) -> Bool { all.contains(a.url.standardizedFileURL.path) }

    static func defaultBrowser(_ apps: [AppEntry]) -> AppEntry? {
        guard let probe = URL(string: "https://example.com"),
              let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return apps.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }
}

// MARK: - Dictation (Wispr Flow)

/// Voice typing is handed to Wispr Flow: SayOpen presses its hands-free shortcut, keeps the app
/// you were in at the front, and stops acting on speech until you pause.
@MainActor
enum Dictation {
    static let appName = "Wispr Flow"

    /// Wispr's own setting, so a changed shortcut keeps working. Falls back to its default, fn + space.
    static func handsFreeChord() -> [Int] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow/config.json")
        if let d = try? Data(contentsOf: path),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let shortcuts = ((j["prefs"] as? [String: Any])?["user"] as? [String: Any])?["shortcuts"] as? [String: String],
           let combo = shortcuts.first(where: { $0.value == "popo" })?.key {
            let codes = combo.split(separator: "+").compactMap { Int($0) }
            if !codes.isEmpty { return codes }
        }
        return [63, 49]
    }

    static func start(apps: [AppEntry]) async -> Executor.Outcome {
        guard let wispr = apps.first(where: { $0.name == appName }) else {
            return Executor.Outcome(ok: false, note: "Wispr Flow is not installed")
        }
        guard Keys.trusted() else { return Executor.Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
        let front = FrontTracker.shared.last
        if let bid = Bundle(url: wispr.url)?.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            Executor.launch(wispr.url, activate: false)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        // Type into the app you are in. Only if SayOpen's own window has focus, hand it back first.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            front?.activate()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        toggle()
        return Executor.Outcome(ok: true, icon: wispr.url.path)
    }

    /// Wispr types the stop phrase too ("... Close Wispr Flow."). Once its record of this dictation
    /// is written, delete exactly that tail with Backspace, in the app it was pasted into.
    static func trimSpokenStop(since: Date) async {
        for _ in 0 ..< 40 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let (text, at, app) = WisprHistory.latest(), at > since.addingTimeInterval(-2), !text.isEmpty else { continue }
            // Backspace goes to whatever is in front, so only when that is where Wispr pasted.
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard front == app else {
                dlog("trim skipped: Wispr pasted into \(app), \(front) is in front")
                return
            }
            // Work against what is really in the box. Wispr may have made the stop phrase its own
            // list item ("4. Close Wispr Flow."), and rich editors (Claude) do not report the text
            // up to the cursor the way plain boxes do, so no count taken up front is trustworthy.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await trimField() { return }
            // The box cannot be read: fall back to Wispr's own copy of what it pasted.
            let n = stopSuffixLength(text)
            dlog("wispr pasted \(text.count) chars, box unreadable or not ending in the phrase; deleting \(n) by count")
            guard n > 0, fieldValue() == nil else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            for _ in 0 ..< n { Keys.press(51, []) }
            return
        }
        dlog("trim: Wispr wrote no history for this dictation")
    }

    /// How much to take off the end: the stop phrase, the spaces after it, and a comma or dash
    /// Wispr put before it. A full stop, ? or ! before it ends your own sentence and stays.
    static func stopSuffixLength(_ text: String) -> Int {
        let lead = #"(?:\s*[,;:\-–—]\s*|\s+|^)"#
        let tail = #"[\s.!?,]*$"#
        let phrases = [#"(?:close|stop|end|exit|finish|quit)(?:\s+the)?\s+(?:[a-z]+\s+)?[a-z]*flow?"#,
                       #"(?:close|stop|end|exit|finish|quit)(?:\s+the)?\s+(?:wispr|whisper|wisper|visper|whisker)"#,
                       #"[a-z]*(?:is|isp|isk)[a-z]*\s*flow?\s+(?:band(?:\s+karo)?|close|stop)"#,
                       #"(?:stop|done|finish|finished|end)\s+(?:typing|dictation|dictating)"#,
                       #"(?:wispr|whisper|wisper|whisker|visper|wisp)\s*(?:flow|flo|glow|low)"#]
        for p in phrases {
            guard let r = text.range(of: lead + #"\b"# + p + tail, options: [.regularExpression, .caseInsensitive]) else { continue }
            var cut = text[r]
            // Never more than the phrase and its punctuation: a stop phrase is at most ~6 words.
            if cut.split(whereSeparator: { $0.isWhitespace }).count > 6 { return 0 }
            // Keep one space when the phrase followed a full stop, so the next dictation lines up.
            if let prev = text[..<r.lowerBound].last, ".!?".contains(prev), cut.first == " " { cut = cut.dropFirst() }
            return cut.count
        }
        return 0
    }

    /// Deletes the stop phrase from the end of the focused box, checking the box after every
    /// keystroke. False when the box cannot be read or does not end in the phrase.
    static func trimField() async -> Bool {
        if let field = fieldValue(), stopSuffixLength(tidy(field)) > 0 {
                let before = tidy(field)
                let target = cleanEnd(String(before.dropLast(stopSuffixLength(before))))
                dlog("trim: box ends \"\(before.suffix(30))\", deleting back to \"\(target.suffix(20))\"")
                let cap = before.count - target.count + 6
                for _ in 0 ..< cap {
                    guard let now = fieldValue() else { break }
                    let t = tidy(now)
                    if t == target { dlog("trim: done"); return true }
                    if t.count < target.count || !before.hasPrefix(t.prefix(max(0, min(t.count, target.count)))) {
                        dlog("trim: box changed under us, stopped"); return true
                    }
                    Keys.press(51, [])
                    try? await Task.sleep(nanoseconds: 35_000_000)
                }
                dlog("trim: stopped at the cap")
                return true
            }
            return false
    }


    /// Trailing spaces and line breaks do not count.
    static func tidy(_ s: String) -> String {
        var t = s
        while let l = t.last, l.isWhitespace || l == "\u{200B}" || l == "\u{FEFC}" { t.removeLast() }
        return t
    }

    /// Also drop an empty list item left at the end ("\n4." or "\n-").
    static func cleanEnd(_ s: String) -> String {
        var t = tidy(s)
        while let r = t.range(of: #"(\n|^)[ \t]*(\d+[.)]|[-*•])[ \t]*$"#, options: .regularExpression) {
            t = tidy(String(t[..<r.lowerBound]))
        }
        return t
    }

    /// The whole value of the focused text box of the front app.
    static func fieldValue() -> String? {
        // Ask the front app, not the system-wide element: that lookup fails here (-25204).
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        UIScan.wake(front.processIdentifier)                  // Electron (Claude) hides its text until asked
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXValueAttribute as CFString, &v) == .success,
              let value = v as? String, !value.isEmpty else { return nil }
        return value
    }

    /// The text before the cursor in the focused text box of the front app, if it can be read.
    static func focusedText() -> String? {
        // Ask the front app, not the system-wide element: that lookup fails here (-25204).
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        UIScan.wake(front.processIdentifier)                  // Electron (Claude) hides its text until asked
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f else { return nil }
        let el = f as! AXUIElement
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
              let value = v as? String, !value.isEmpty else { return nil }
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range), range.length == 0 {
                let ns = value as NSString
                if range.location >= 0, range.location <= ns.length { return ns.substring(to: range.location) }
            }
        }
        return value
    }

    static func toggle() {
        let chord = handsFreeChord()
        dlog("dictation: pressing \(chord)")
        Keys.chord(chord)
    }
}


// MARK: - Wispr's own record of what it pasted

import SQLite3

enum WisprHistory {
    /// The newest dictation in Wispr Flow's local database: the text it pasted and when it started.
    /// Read-only, one row, and only to find the stop phrase at its end.
    static func latest() -> (String, Date, String)? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = "select timestamp, coalesce(nullif(pastedText,''), nullif(formattedText,''), ''), coalesce(app,'') from History order by timestamp desc limit 1"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW,
              let ts = sqlite3_column_text(st, 0), let tx = sqlite3_column_text(st, 1),
              let ap = sqlite3_column_text(st, 2) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        guard let at = f.date(from: String(cString: ts)) else { return nil }
        return (String(cString: tx), at, String(cString: ap))
    }
}


// MARK: - Finding files by name

enum FileSearch {
    /// Files in your home folder whose names contain every word you said ("launch deck" finds
    /// Launch_Deck_25Sep2026.docx), newest first, via Spotlight. Library and hidden folders are skipped.
    /// macOS hides Desktop, Documents and Downloads from Spotlight searches run by an app that has
    /// not been allowed in. Touching each folder once brings up the "allow access" prompts.
    static func askForFolders() {
        let fm = FileManager.default
        for d in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { _ = try? fm.contentsOfDirectory(atPath: u.path) }
        }
    }

    /// Words that say what kind of file, not what it is called: "my PPT", "the deck", "that pdf".
    /// They boost files of that kind instead of having to appear in the name.
    static let kinds: [String: Set<String>] = {
        let slides: Set<String> = ["ppt", "pptx", "key", "pdf", "png", "jpg", "slide", "slides", "deck"]
        let docs: Set<String> = ["docx", "doc", "pages", "pdf", "md", "txt"]
        let sheets: Set<String> = ["xlsx", "xls", "csv", "numbers"]
        let video: Set<String> = ["mp4", "mov", "m4v", "webm"]
        let image: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]
        return ["ppt": slides, "pptx": slides, "deck": slides, "slide": slides, "slides": slides,
                "presentation": slides, "keynote": slides, "pdf": ["pdf"], "word": docs, "document": docs,
                "doc": docs, "docx": docs, "sheet": sheets, "spreadsheet": sheets, "excel": sheets,
                "csv": sheets, "video": video, "reel": video, "clip": video, "image": image,
                "photo": image, "picture": image, "screenshot": image, "png": image]
    }()

    /// Speech recognition hears names its own way: "Jeff" for Jev, "Kaydence" for Cadence.
    /// Soundex puts words that sound alike on the same key (Jeff and Jev are both J100).
    static func soundex(_ w: String) -> String {
        let code: [Character: Character] = ["b": "1", "f": "1", "p": "1", "v": "1", "c": "2", "g": "2", "j": "2",
            "k": "2", "q": "2", "s": "2", "x": "2", "z": "2", "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6"]
        guard let first = w.first, first.isLetter else { return w }
        var out = String(first), last = code[first]
        for c in w.dropFirst() {
            let d = code[c]
            if let d, d != last { out.append(d) }
            if c != "h" && c != "w" { last = d }
            if out.count == 4 { break }
        }
        return out.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    /// How close a spoken word is to a word in a file name, 0 to 1.
    static func likeness(_ w: String, _ tok: String) -> Double {
        if w == tok { return 1 }
        if w.count >= 3 && tok.count >= 3 && (tok.hasPrefix(w) || w.hasPrefix(tok)) { return 0.95 }
        let spelled = 1 - Double(Rules.editDistance(w, tok)) / Double(max(w.count, tok.count))
        let sounds = w.count >= 3 && tok.count >= 3 && w.first == tok.first && soundex(w) == soundex(tok) ? 0.85 : 0
        return max(spelled, sounds)
    }

    /// Files that could be what you described, best first, for Jev to choose from. Deliberately
    /// loose: a file needs only one real word of what you said in its name or folder, so
    /// "the PPT which has built with Jeff" still reaches built-with-jev.png. Every other word
    /// that matches, the kind of file you named, and recency push a file up the list.
    static func find(_ said: String, limit: Int = 25) -> [URL] {
        let drop: Set<String> = ["the", "my", "a", "an", "file", "files", "called", "named", "open", "please",
                                 "that", "this", "one", "folder", "kholo", "khol", "show", "find", "pull", "up",
                                 "me", "can", "you", "i", "we", "our", "it", "its"]
        // Glue words count a little when a name really has them ("built-with-jev") but never
        // bring a file in on their own.
        let glue: Set<String> = ["which", "that", "has", "have", "had", "is", "was", "with", "of", "to", "and",
                                 "for", "about", "made", "built", "created", "where", "from", "on", "in", "by",
                                 "using", "some", "those", "these", "there", "wala", "wali", "ka", "ki", "ke"]
        let all = normalise(said).split(separator: " ").map(String.init).filter { !drop.contains($0) }
        let kindWords = all.filter { kinds[$0] != nil }
        let wanted = kindWords.reduce(into: Set<String>()) { $0.formUnion(kinds[$1] ?? []) }
        let words = all.filter { kinds[$0] == nil }
        let strong = words.filter { !glue.contains($0) && $0.count >= 2 }
        guard !strong.isEmpty || !wanted.isEmpty else { return [] }

        var pool = Set(scanFolders())
        let spot = strong.filter { $0.count >= 3 }
        if !spot.isEmpty {
            pool.formUnion(mdfind(spot.map { "kMDItemFSName == \"*\($0)*\"cd" }.joined(separator: " || ")))
        }
        func split(_ s: String) -> [String] {
            normalise(s.replacingOccurrences(of: "_", with: " ")).split(separator: " ").map(String.init)
        }
        // Code and package folders are never what you mean by "my PNG" (mdfind brings them in).
        let junk = ["/site-packages/", "/node_modules/", "/__pycache__/", "/venv/", "/.venv/", "/Library/", "/.git/", "/f5venv/"]
        pool = pool.filter { u in !junk.contains { u.path.contains($0) } }
        var scored: [(URL, Double)] = []
        for u in pool {
            let name = split(u.deletingPathExtension().lastPathComponent)
            guard !name.isEmpty else { continue }
            let ext = u.pathExtension.lowercased()
            let folder = split(u.deletingLastPathComponent().lastPathComponent)
            var score = 0.0, hits = 0
            for w in words {
                let inName = name.map { likeness(w, $0) }.max() ?? 0
                let inFolder = (folder.map { likeness(w, $0) }.max() ?? 0) * 0.5
                let best = max(inName, inFolder)
                guard best >= 0.75 * (inName >= inFolder ? 1 : 0.5) else { continue }
                let isStrong = !glue.contains(w)
                if isStrong { hits += 1 }
                score += best * (isStrong ? 1 : 0.3)
            }
            if !wanted.isEmpty {
                let kindHit = wanted.contains(ext) || !Set(name + folder).isDisjoint(with: wanted)
                // You said PNG: a .py or .html with the same name is not it.
                if kindHit { score += 0.6 } else if strong.isEmpty { continue } else { score -= 1 }
            }
            // "built with jev" is built-with-jev.png, not built-with-jev-mirrored.png.
            let unmatched = name.filter { n in !words.contains { likeness($0, n) >= 0.75 } }.count
            score -= 0.15 * Double(unmatched)
            guard hits > 0 || strong.isEmpty else { continue }
            scored.append((u, score))
        }
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        scored.sort { abs($0.1 - $1.1) > 0.01 ? $0.1 > $1.1 : modified($0.0) > modified($1.0) }
        // A web page with a desktop copy beside it is the same thing, twice: keep only the desktop copy.
        let kept = Set(scored.map(\.0))
        scored.removeAll { opensInBrowser($0.0) && desktopSibling($0.0).map(kept.contains) == true }
        return scored.prefix(limit).map(\.0)
    }

    /// Everything a few levels down in Desktop, Documents and Downloads, skipping code and package
    /// folders, capped so a huge Documents folder cannot stall it.
    private static var cache: (at: Date, urls: [URL])?

    private static func scanFolders() -> [URL] {
        if let c = cache, Date().timeIntervalSince(c.at) < 60 { return c.urls }
        let urls = scanFoldersNow()
        cache = (Date(), urls)
        return urls
    }

    private static func scanFoldersNow() -> [URL] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", ".git", "venv", ".venv", "build", "dist", "Library", "__pycache__", "site-packages"]
        var out: [URL] = []
        let started = Date()
        for d in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            guard let root = fm.urls(for: d, in: .userDomainMask).first,
                  let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                if e.level > 3 || skip.contains(u.lastPathComponent) || u.pathExtension == "app" {
                    e.skipDescendants()
                    if skip.contains(u.lastPathComponent) || u.pathExtension == "app" { continue }
                }
                out.append(u)
                if out.count > 30_000 || Date().timeIntervalSince(started) > 1.5 { return out }
            }
        }
        return out
    }

    private static func mdfind(_ predicate: String) -> [URL] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", FileManager.default.homeDirectoryForCurrentUser.path, predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(home + "/Library") && !$0.contains("/.") && !$0.contains("/node_modules/")
                && !$0.contains(".app/") }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return urls.sorted { modified($0) > modified($1) }
    }

    /// Files open on the desktop, not in a browser. Desktop versions, best first, looked for next
    /// to a file that would otherwise open in a browser (built-with-jev.html -> built-with-jev.png).
    static let desktopKinds = ["pdf", "pptx", "ppt", "key", "docx", "pages", "xlsx", "numbers", "png", "jpg", "jpeg", "mp4", "mov"]

    static func opensInBrowser(_ u: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: u) else { return false }
        return Browsers.all.contains(app.standardizedFileURL.path)
    }

    /// The desktop version of the same file, if one sits beside it.
    static func desktopSibling(_ u: URL) -> URL? {
        let base = u.deletingPathExtension()
        return desktopKinds.lazy.map { base.appendingPathExtension($0) }
            .first { $0 != u && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What to open, and with which app, so it lands in a desktop app. A browser-bound file is
    /// swapped for its desktop sibling; a PDF claimed by a browser goes to Preview.
    static func desktopOpen(_ u: URL) -> (URL, URL?) {
        guard opensInBrowser(u) else { return (u, nil) }
        if let sib = desktopSibling(u) { return desktopOpen(sib) }
        if u.pathExtension.lowercased() == "pdf" {
            return (u, URL(fileURLWithPath: "/System/Applications/Preview.app"))
        }
        return (u, nil)   // only a web page exists (plain .html): the browser is the only way to show it
    }

    static func describe(_ u: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = u.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
        let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "\(u.lastPathComponent) in \(folder), changed \(f.string(from: d))"
    }
}


// MARK: - Scrolling

enum Scroll {
    /// A scroll-wheel turn over the middle of the front window, where the mouse may not be.
    /// Top and bottom are the Home and End keys.
    static func run(_ how: String) {
        if how == "top" { Keys.press(115, .maskCommand); Keys.press(115, []); return }
        if how == "bottom" { Keys.press(119, .maskCommand); Keys.press(119, []); return }
        var at = NSEvent.mouseLocation
        if let front = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            var w: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let w {
                let win = w as! AXUIElement
                AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pos)
                AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &size)
                var p = CGPoint.zero, s = CGSize.zero
                if let pos, let size, AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) {
                    at = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)      // AX is top-left based, like CGEvent
                    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: Int32(how == "up" ? 500 : -500), wheel2: 0, wheel3: 0)
                    e?.location = at
                    e?.post(tap: .cghidEventTap)
                    return
                }
            }
        }
        Keys.press(how == "up" ? 116 : 121, [])            // Page Up / Page Down
    }
}
