import AppKit
import ApplicationServices
import Foundation

// Doing things inside an app by clicking its own menus and buttons, the way you would.
// Collect what can be clicked, let an engine pick the next click toward the goal, click,
// look again. Nothing app-specific: Claude, Slack, Dia and Finder all work the same way.

struct Clickable {
    let label: String       // what you would read on screen, with the menu path for menu items
    let element: AXUIElement
    var isField = false     // a text box: "clicking" it puts the cursor there
    var mouse = false       // no Press action (Dia's profile dots): clicked with the mouse at its centre
}

enum UIScan {
    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return (v as! AXUIElement) as? T }
        return v as? T
    }

    /// Electron apps (Claude, Slack, VS Code) hide their page from Accessibility until asked.
    static func wake(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    static func clickables(pid: pid_t, limit: Int = 240) -> [Clickable] {
        let app = AXUIElementCreateApplication(pid)
        var out: [Clickable] = []
        var seen: [String: Int] = [:]
        let profiles = BrowserProfiles.names(pid: pid)
        func add(_ label: String, _ el: AXUIElement, _ field: Bool = false, _ mouse: Bool = false) {
            var l = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard l.count > 1, l.count < 90 else { return }
            // The same words twice on a page are two things ("Google Docs: Sign-in" is the first
            // and the third result), so the second is kept as "... #2" for "click the second one".
            let n = (seen[l.lowercased()] ?? 0) + 1
            seen[l.lowercased()] = n
            if n > 1 { guard n <= 5 else { return }; l += " #\(n)" }
            // Dia shows a second profile of the same name as "Work 2".
            if profiles.contains(label) || profiles.contains(label.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)) {
                l = "profile: " + l
            }
            out.append(Clickable(label: l, element: el, isField: field, mouse: mouse))
        }
        // On-screen first: open popovers and menus, then the focused window.
        let wins: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        let focused: AXUIElement? = attr(app, kAXFocusedWindowAttribute)
        for w in ([focused].compactMap { $0 } + wins).prefix(3) {
            walkWindow(w, depth: 0) { add($0, $1, $2, $3) }
        }
        // A long sidebar (Claude lists every past session) must not push the menu bar off the end:
        // the window gets what is left after the menus, and the menus always make it in whole.
        // An open popup menu (Claude's model list) is what you are looking at: it goes first.
        let popup = out.filter { (attr($0.element, kAXRoleAttribute) as String?) == "AXMenuItem" }
        let onScreen = popup + out.filter { (attr($0.element, kAXRoleAttribute) as String?) != "AXMenuItem" }
        out = []
        if let bar: AXUIElement = attr(app, kAXMenuBarAttribute) {
            walkMenu(bar, path: [], depth: 0) { add($0, $1, $2, false) }
        }
        return Array(onScreen.prefix(max(60, limit - out.count))) + out
    }

    private static let pressable: Set<String> = ["AXButton", "AXRadioButton", "AXLink", "AXMenuItem", "AXCheckBox",
                                                 "AXPopUpButton", "AXMenuButton", "AXTab", "AXCell", "AXRow",
                                                 "AXDisclosureTriangle", "AXStaticText", "AXUnknown", "AXGroup", "AXImage"]

    private static let fields: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private static func walkWindow(_ el: AXUIElement, depth: Int, _ add: (String, AXUIElement, Bool, Bool) -> Void) {
        // Claude's model picker sits 28 levels down; the old limit of 28 hid the whole chat pane.
        guard depth < 44 else { return }
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        if fields.contains(role) {
            let name = [attr(el, kAXTitleAttribute) as String?, attr(el, kAXDescriptionAttribute) as String?,
                        attr(el, "AXPlaceholderValue") as String?, attr(el, kAXHelpAttribute) as String?]
                .compactMap { $0 }.first { !$0.isEmpty } ?? (role == "AXTextArea" ? "text area" : "text box")
            add("text box: \(name)", el, true, false)
        }
        if pressable.contains(role) {
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            let canPress = ((actions as? [String]) ?? []).contains(kAXPressAction as String)
            let title = [attr(el, kAXTitleAttribute) as String?, attr(el, kAXDescriptionAttribute) as String?]
                .compactMap { $0 }.first { !$0.isEmpty }
            if canPress {
                var label = title ?? [attr(el, kAXValueAttribute) as String?, attr(el, kAXHelpAttribute) as String?]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                // Dia's sidebar tabs are unnamed controls marked "tab": say so, for "the Google Doc tab".
                if (attr(el, kAXIdentifierAttribute) as String?) == "tab" || (attr(el, kAXHelpAttribute) as String?) == "tab" {
                    label = "tab: " + label
                }
                if !label.isEmpty && !(label.hasPrefix("tab: ") && label.count <= 5) { add(label, el, false, false) }
            } else if role == "AXUnknown", let title, frame(el) != nil {
                // A named control with no Press action: Dia's profile dots. Clicked with the mouse.
                add(title, el, false, true)
            }
        }
        let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
        for k in kids { walkWindow(k, depth: depth + 1, add) }
    }

    private static func walkMenu(_ el: AXUIElement, path: [String], depth: Int, _ add: (String, AXUIElement, Bool) -> Void) {
        guard depth < 6 else { return }
        let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
        for (idx, k) in kids.enumerated() {
            let role: String = attr(k, kAXRoleAttribute) ?? ""
            let title: String = attr(k, kAXTitleAttribute) ?? ""
            if role == "AXMenuBarItem" {
                if depth == 0 && idx == 0 { continue }            // the Apple menu: shut down, log out...
                walkMenu(k, path: title.isEmpty ? path : path + [title], depth: depth + 1, add)
            } else if role == "AXMenuItem" {
                let sub: [AXUIElement] = attr(k, kAXChildrenAttribute) ?? []
                let enabled: Bool = attr(k, kAXEnabledAttribute) ?? false
                if title == "Services" { continue }          // acts on other apps, not this one
                if sub.isEmpty, enabled, !title.isEmpty {
                    add((path + [title]).joined(separator: " > "), k, false)
                } else if !sub.isEmpty {
                    walkMenu(k, path: path + [title], depth: depth + 1, add)
                }
            } else {
                walkMenu(k, path: path, depth: depth + 1, add)
            }
        }
    }

    /// The pressable rows inside the window's "Sidebar" group, in screen order.
    static func sessions(pid: pid_t) -> [Clickable] {
        let app = AXUIElementCreateApplication(pid)
        guard let w: AXUIElement = attr(app, kAXFocusedWindowAttribute) ?? (attr(app, kAXWindowsAttribute) as [AXUIElement]?)?.first
        else { return [] }
        var out: [Clickable] = []
        var seen = Set<String>()
        func walk(_ el: AXUIElement, _ depth: Int, _ inside: Bool) {
            guard depth < 44 else { return }
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            let desc: String = attr(el, kAXDescriptionAttribute) ?? ""
            let here = inside || (role == "AXGroup" && desc == "Sidebar")
            if here, role == "AXButton" {
                let t = [attr(el, kAXTitleAttribute) as String?, desc as String?].compactMap { $0 }.first { !$0.isEmpty } ?? ""
                if t.count > 2, seen.insert(t).inserted { out.append(Clickable(label: t, element: el)) }
            }
            for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(k, depth + 1, here) }
        }
        walk(w, 0, false)
        return out
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success, let p,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success, let s,
              AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz),
              sz.width > 1, sz.height > 1 else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// A real click at the element's centre, then the pointer goes back where it was.
    static func mouseClick(_ el: AXUIElement) -> Bool {
        guard let f = frame(el) else { return false }
        let at = CGPoint(x: f.midX, y: f.midY)
        let back = CGEvent(source: nil)?.location
        // Move there first: SwiftUI controls (Dia's tabs) ignore a click that arrives without a hover.
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            e?.post(tap: .cghidEventTap)
            usleep(70_000)
        }
        usleep(150_000)
        if let back { CGWarpMouseCursorPosition(back) }
        return true
    }

    static func press(_ c: Clickable) -> Bool {
        if c.mouse { return mouseClick(c.element) }
        if c.isField {
            return AXUIElementSetAttributeValue(c.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        if AXUIElementPerformAction(c.element, kAXPressAction as CFString) == .success { return true }
        // Dia's sidebar tabs list a Press action and then refuse it: click them like a person would.
        return mouseClick(c.element)
    }
}

// MARK: - The click loop

enum UIAgent {
    /// Never offered as a choice, whoever is deciding: these lose data or end your session.
    static let danger = try! NSRegularExpression(
        pattern: #"\b(delete|reset|remove|erase|quit|log ?out|sign ?out|shut ?down|restart|uninstall|clear cache|force|empty trash|sleep|lock screen|discard|archive all|free up)\b"#,
        options: [.caseInsensitive])

    static func safe(_ label: String) -> Bool {
        danger.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) == nil
    }

    /// `pick(labels, clicked)` returns the index to click next, or nil when done or stuck.
    @MainActor
    static func run(goal: String, app: AppEntry,
                    pick: @escaping ([String], [String]) async -> Int?) async -> Executor.Outcome {
        // Menus and buttons can be pressed through Accessibility even when the app is behind other
        // windows, so coming forward is nice to have, not required.
        let front = await Executor.bringToFront(app)
        if !front { dlog("\(app.name) did not come forward; clicking in the background") }
        guard let pid = Executor.runningApp(app)?.processIdentifier else {
            return Executor.Outcome(ok: false, note: "\(app.name) is not running")
        }
        UIScan.wake(pid)
        try? await Task.sleep(nanoseconds: 300_000_000)
        var clicked: [String] = []
        // Known places in known apps go straight there: no engine round trip, no guessing.
        let route = AppKnowledge.route(goal: goal, app: app.name)
        var skipTo = 0
        for (n, target) in route.enumerated() {
            if target == "{session}" {
                guard let hit = await pickSession(goal: goal, pid: pid) else { break }
                let ok = UIScan.press(hit)
                dlog("ui session click \(ok ? "" : "FAILED ")\"\(hit.label)\"")
                if ok { clicked.append(hit.label) }
                continue
            }
            // Known targets are matched by code, not read by an engine, so nothing is cut off.
            let items = UIScan.clickables(pid: pid, limit: 2000).filter { safe($0.label) }
            let names = target.split(separator: "|").map(String.init)
            // Already there: the first click opened the waiting session itself, not the side
            // switcher, so a second "Awaiting input" click would open a different session.
            if let last = clicked.last, names.contains(where: { AppKnowledge.same(last, $0) }) { continue }
            // A later step already on screen (the picker is open, or its confirmation is up): go
            // straight there. Pressing the picker again would shut it.
            if n < skipTo { continue }
            if let later = (n + 1 ..< route.count).last(where: { k in
                let want = route[k].split(separator: "|").map(String.init)
                return items.contains { i in want.contains { AppKnowledge.same(i.label, $0) } }
            }) { skipTo = later; continue }
            // A confirmation that only sometimes appears ("Switch model?" mid-session): wait for it briefly.
            var hitNow = names.lazy.compactMap({ n in items.first { AppKnowledge.same($0.label, n) } }).first
            if hitNow == nil, n > 0, n == route.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let again = UIScan.clickables(pid: pid, limit: 2000).filter { safe($0.label) }
                hitNow = names.lazy.compactMap({ n in again.first { AppKnowledge.same($0.label, n) } }).first
            }
            guard let hit = hitNow else {
                dlog("ui route: \"\(target)\" not on screen in \(app.name)")
                break
            }
            let ok = UIScan.press(hit)
            dlog("ui route click \(ok ? "" : "FAILED ")\"\(hit.label)\"")
            if ok { clicked.append(hit.label) }
            if n < route.count - 1 { try? await Task.sleep(nanoseconds: 600_000_000) }   // let the tab load
        }
        if !clicked.isEmpty {
            return Executor.Outcome(ok: true, note: clicked.joined(separator: " \u{2192} "), icon: app.url.path, focus: app)
        }
        // "Click the first Google sign-in": every word said is on the label, and the position
        // picks among them in screen order. No engine needed when the words settle it.
        let all = UIScan.clickables(pid: pid, limit: 2000).filter { safe($0.label) }
        if let hit = wordMatch(goal: goal, appName: app.name, items: all) {
            let ok = UIScan.press(hit)
            dlog("ui word match \(ok ? "" : "FAILED ")\"\(hit.label)\"")
            if ok { return Executor.Outcome(ok: true, note: hit.label, icon: app.url.path, focus: app) }
        }
        var waits = 0
        var step = 0
        while step < 4 {
            let items = UIScan.clickables(pid: pid).filter { safe($0.label) }
            dlog("ui step \(step + 1) in \(app.name): \(items.count) safe clickables")
            let labels = items.map { AppKnowledge.explain($0.label, app: app.name) }
            let pickIndex = items.isEmpty ? nil : await pick(labels, clicked)
            guard let i = pickIndex, i < items.count else {
                // A page that just started loading (Gmail after "open gmail") has almost nothing yet.
                // A full window where nothing fits will not change by waiting: give up now.
                if clicked.isEmpty && waits < 3 && items.count < 40 {
                    waits += 1
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    continue
                }
                break
            }
            step += 1
            let label = items[i].label
            if clicked.last == label { break }                 // same click twice: nothing is changing
            let ok = UIScan.press(items[i])
            dlog("ui click \(ok ? "" : "FAILED ")\"\(label)\"")
            clicked.append(label)
            try? await Task.sleep(nanoseconds: 800_000_000)   // let the menu or page open
        }
        return Executor.Outcome(ok: !clicked.isEmpty,
                                note: clicked.isEmpty ? "found nothing to click for that" : clicked.joined(separator: " \u{2192} "),
                                icon: app.url.path, focus: app)
    }

    /// Claude's sidebar sessions, and Jev's pick of the one the goal is about.
    @MainActor
    static func pickSession(goal: String, pid: pid_t) async -> Clickable? {
        let states = ["Awaiting input ", "Unread response ", "Idle ", "Running ", "Working "]
        let nav = #"^(hide sidebar|back|forward|search|new|projects|artifacts|scheduled|design|customize|dispatch|pinned|yesterday|today|older|view all|filter|more navigation items)\b|^(more options for|toggle sessions for|new session in|mark as unread|show \d+ more|bulk actions)|^(sep|oct|nov|dec|jan|feb|mar|apr|may|jun|jul|aug) \d+$"#
        let items = UIScan.sessions(pid: pid).filter {
            $0.label.lowercased().range(of: nav, options: .regularExpression) == nil
        }
        guard !items.isEmpty else { dlog("ui session: sidebar is empty"); return nil }
        let names = items.map { l -> String in
            let s = l.label
            for st in states where s.hasPrefix(st) { return String(s.dropFirst(st.count)) }
            return s
        }
        // Every word said is in one title: no engine needed.
        if let w = wordMatch(goal: goal, appName: "Claude", items: items.enumerated().map {
            Clickable(label: names[$0.offset], element: $0.element.element)
        }), let i = names.firstIndex(of: w.label) { return items[i] }
        guard let chooser = Executor.chooser else { return nil }
        guard let i = await chooser(goal, names, "Each option is a session (chat or Claude Code task) in the "
            + "sidebar, by its title. `said` asks to open one of them by its topic, maybe loosely or misheard. "
            + "Which session is it?") else { dlog("ui session: none of \(names.count) fit"); return nil }
        return items[i]
    }

    static let ordinals: [String: Int] = ["first": 0, "1st": 0, "top": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2,
                                          "fourth": 3, "4th": 3, "fifth": 4, "5th": 4, "last": -1]

    /// The labels holding every word you said about the thing (sign-in matches "Sign-in",
    /// doc matches "Docs"), then the one at the position you named, first by default.
    static func wordMatch(goal: String, appName: String, items: [Clickable]) -> Clickable? {
        let stop: Set<String> = ["change", "switch", "move", "jump", "show", "use", "make", "set", "into", "my", "click", "tap", "press", "hit", "choose", "select", "pick", "open", "go", "to", "visit",
                                 "on", "the", "a", "an", "in", "inside", "one", "please", "that", "this", "link", "result",
                                 "button", "option", "item", "entry", "for", "me", "of", "and", "tab", "page", "app"]
        let appWords = Set(normalise(appName).split(separator: " ").map(String.init))
        let words = normalise(Aliases.apply(goal)).split(separator: " ").map(String.init)
        let pos = words.compactMap { ordinals[$0] }.first
        let want = words.filter { !stop.contains($0) && ordinals[$0] == nil && !appWords.contains($0) }
        guard !want.isEmpty else { return nil }
        func has(_ label: String, _ w: String) -> Bool {
            normalise(label).split(separator: " ").contains { lw in
                lw == w || (w.count >= 3 && (lw.hasPrefix(w) || w.hasPrefix(lw) && lw.count >= 3))
            }
        }
        // Menu-bar items are reached by path, not by what is on screen; leave them to the engine.
        let found = items.filter { item in !item.label.contains(" > ") && want.allSatisfy { has(item.label, $0) } }
        guard !found.isEmpty else { return nil }
        // Several matches and no position: only safe when you asked for "the first" implicitly by
        // naming it fully, so take the one whose label is closest in length to what you said.
        guard let p = pos else {
            return found.count == 1 ? found[0] : found.min { $0.label.count < $1.label.count }
        }
        let i = p < 0 ? found.count - 1 : p
        return i < found.count ? found[i] : nil
    }

    /// The no-Jev picker: the on-screen label sharing the most words with what you said.
    static func rulesPick(goal: String, appName: String) -> ([String], [String]) async -> Int? {
        let stop: Set<String> = ["open", "go", "to", "the", "a", "in", "inside", "on", "my", "please", "switch",
                                 "change", "show", "me", "click", "select", "app", "and", "for", "of", "with"]
        let appWords = Set(normalise(appName).split(separator: " ").map(String.init))
        let want = Set(normalise(goal).split(separator: " ").map(String.init)).subtracting(stop).subtracting(appWords)
        return { labels, clicked in
            guard !want.isEmpty, clicked.count < 2 else { return nil }
            var best: (Int, Int)?
            for (i, l) in labels.enumerated() where !clicked.contains(l) {
                let words = Set(normalise(l).split(separator: " ").map(String.init))
                let score = words.intersection(want).count
                if score > (best?.1 ?? 0) { best = (i, score) }
            }
            return best?.0
        }
    }
}


// MARK: - What some apps call things

/// Names people say that an app's buttons do not use. In Claude, Cowork is the "Claude" tab of
/// the Claude | Code switcher (Projects, Scheduled, Dispatch, Design live there), and speech
/// recognition hears "Cowork" as "coworker" or "co work".
enum AppKnowledge {
    struct Place {
        let said: String; let click: [String]; let means: String; var home = false
        /// Only this app has it: said while the app is in front, it goes straight here, no engine.
        var direct = false
    }

    /// "Switch to Opus" names a menu item the second click needs. Recognition hears Opus as
    /// octopus or opus's, Sonnet as sonic, Haiku as hi koo.
    static let models: [(said: String, label: String)] = [
        (#"\b(opus\w*|octopus|opas|oppus)\b"#, "Opus"), (#"\b(sonnet\w*|sonic|sonet|sonnett)\b"#, "Sonnet"),
        (#"\b(haiku|hiku|hi ?koo|hai ?ku)\b"#, "Haiku"), (#"\b(fable|fabel|fables)\b"#, "Fable"),
    ]
    static let efforts = ["low", "medium", "high", "extra", "max"]

    /// Claude's two modes. "Claude" is chat and Cowork; "Code" is Claude Code.
    static let modes: [String: [Place]] = [
        "Claude": [
            Place(said: #"\bco ?work(er|ers|ing)?\b|\bcowok\b|\bco-work|\bchat\b|\bhome\b"#, click: ["Go > Claude"],
                  means: "Cowork and chat, the Claude tab"),
            Place(said: #"\bclaude code\b|\b(in|inside|into|to) code\b|\bcode (tab|mode|session|side)|^\s*(open |go to |switch to )?code\b"#,
                  click: ["Go > Code"], means: "Claude Code, the Code tab"),
        ],
    ]

    /// Places inside an app. `home`: only on Claude's Claude tab, so that tab comes first.
    static let places: [String: [Place]] = [
        "Claude": [
            // Sessions show their state first in the sidebar: "Awaiting input Website migration".
            // The Claude | Code switcher says when the other side has one: "Code, awaiting your input".
            Place(said: #"\b(needs?|needing|awaiting|waiting|wants|asking|blocked)\b.*\b(inputs?|attention|approval|permission|answer|reply|response|me|you)\b|\bawaiting\b|\bneeds? (my )?inputs?\b"#,
                  click: ["Awaiting input|Code, awaiting your input|Claude, awaiting your input", "Awaiting input"],
                  means: "the session waiting for your input", direct: true),
            Place(said: #"\bunread\b|\bnew (reply|replies|response|responses|message)\b|\b(finished|done|completed|replied)\b.*\b(tab|session|chat|one)\b"#,
                  click: ["Unread response"], means: "the session with an unread reply", direct: true),
            Place(said: #"\b(still )?(running|working|in progress|busy)\b.*\b(tab|session|chat|one)\b"#,
                  click: ["Running|Working"], means: "the session still running", direct: true),
            Place(said: #"\bmodels?\b|\b(switch|change|use|go|move|set) (it |this |the session )?(to|on) (opus|octopus|sonnet|sonic|haiku|fable)\b|^\s*(use|pick|choose|select|switch to|change to|go with)( the)? (opus|octopus|sonnet|sonic|haiku|fable)\b|^\s*(opus|octopus|sonnet|sonic|haiku|fable)\w*( \d+)*\s*$"#,
                  click: ["Model:", "{model}", "Switch model"], means: "the model picker", direct: true),
            Place(said: #"\beffort\b|\bthinking (level|effort|budget)\b"#,
                  click: ["Effort:", "{effort}"], means: "the effort picker", direct: true),
            Place(said: #"\bnew (session|chat|task|conversation|tab|thread)\b"#, click: ["File > New Session|File > New Chat"], means: "start a new session"),
            Place(said: #"\bnew window\b"#, click: ["File > New Session in New Window|File > New Chat"], means: "new session in a new window"),
            Place(said: #"\b(reopen|re-open|bring back|restore)\b.*\b(tab|session|closed)\b|\bclosed (tab|session)\b"#,
                  click: ["File > Reopen Closed Session"], means: "reopen the last closed session"),
            Place(said: #"\bnext (tab|session)\b"#, click: ["Go > Next Session|Go > Next Chat"], means: "next session"),
            Place(said: #"\b(previous|prev|last) (tab|session)\b"#, click: ["Go > Previous Session|Go > Previous Chat"], means: "previous session"),
            // "Open the chat about Neuralink", "the terminal for video editing": a session by its topic,
            // picked from the sidebar by Jev (the words said are rarely the session's exact title).
            Place(said: #"\b(chat|session|conversation|thread|terminal|task)s? (about|on|for|called|named|regarding|with|where|that|titled|from)\b|\b(open|go to|switch to|show|take me to|jump to)( the| my)? (?!new |next |previous |last )[a-z0-9].{2,}? (chat|session|conversation|thread|task)\b"#,
                  click: ["{session}"], means: "a session by its topic"),
            Place(said: #"\bsplit\b"#, click: ["View > Split View > New Session on the Right"], means: "split view"),
            Place(said: #"\bschedul"#, click: ["Scheduled"], means: "Cowork scheduled tasks", home: true),
            Place(said: #"\bdispatch"#, click: ["Dispatch"], means: "Cowork Dispatch", home: true),
            Place(said: #"\bprojects?\b"#, click: ["Projects"], means: "Cowork projects", home: true),
            Place(said: #"\bartifacts?\b"#, click: ["Artifacts"], means: "artifacts", home: true),
            Place(said: #"\bdesign\b"#, click: ["Design"], means: "Claude Design", home: true),
            Place(said: #"\b(customi[sz]e|skills|connectors|plugins)\b"#, click: ["Customize"], means: "skills, connectors and plugins", home: true),
            Place(said: #"\bsettings?\b|\bpreferences\b"#, click: ["Claude > Settings…"], means: "settings"),
            Place(said: #"\bsearch\b"#, click: ["Go > Search…"], means: "search sessions"),
            Place(said: #"\bterminal\b"#, click: ["View > Show Terminal"], means: "terminal pane"),
            Place(said: #"\bside ?chat\b"#, click: ["View > Show Side Chat"], means: "side chat"),
        ],
    ]

    /// Tab and window commands mean something else in apps without tabs. In Claude a "tab" is a
    /// session: "a new tab in Claude Code" is the Code tab, then File > New Session.
    static let asPlace: [String: String] = ["new_tab": "new session", "new_window": "new window",
                                            "reopen_tab": "reopen closed session", "next_tab": "next session",
                                            "previous_tab": "previous session"]

    /// Places people name as if they were apps. "Open Cowork" means Claude's Cowork tab.
    static let owned: [(said: String, app: String)] = [(#"\bco ?work(er|ers|ing)?\b|\bcowok\b|\bco-work"#, "Claude")]

    static func owner(of text: String) -> String? {
        let t = text.lowercased()
        return owned.first { t.range(of: $0.said, options: .regularExpression) != nil }?.app
    }

    /// The clicks for what the goal names: the mode it names (Code, Cowork) and then the place,
    /// most specific first. Empty when the app or the place is unknown.
    /// Against the words as said and with punctuation dropped: "re-open" and "that's" both count.
    static func says(_ goal: String, _ pattern: String) -> Bool {
        [goal.lowercased(), normalise(goal)].contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    static func place(_ goal: String, app: String) -> Place? {
        places[app]?.first { says(goal, $0.said) }
    }

    static func route(goal: String, app: String) -> [String] {
        let g = normalise(goal)
        let mode = modes[app]?.first { says(goal, $0.said) }
        guard let place = place(goal, app: app) else { return mode?.click ?? [] }
        // Fill in the menu item named in the sentence; with none named, just open the picker.
        let click = place.click.compactMap { c -> String? in
            if c == "{model}" { return models.first { g.range(of: $0.said, options: .regularExpression) != nil }?.label }
            if c == "{effort}" { return efforts.first { g.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }?.capitalized }
            return c
        }
        if place.home { return ["Go > Claude"] + click }
        // The picker and the session list are on both sides; "model" must not also switch to Code.
        return (place.direct ? [] : (mode?.click ?? [])) + click
    }

    /// "Scheduled" matches the on-screen "Scheduled Scheduled tasks have updates";
    /// "Go > Claude" matches only itself.
    static func same(_ label: String, _ target: String) -> Bool {
        // Claude renames menu items per tab: "File > New Session" in Code is "File > New Chat" in
        // Cowork. A target lists every name, split by "|".
        if target.contains("|") { return target.split(separator: "|").contains { same(label, String($0)) } }
        return label == target || label.hasPrefix(target + ",") || (!target.contains(">") && label.hasPrefix(target + " "))
    }

    /// The label as the engine sees it, with what the app means by it.
    static func explain(_ label: String, app: String) -> String {
        if app == "Claude" {
            for (state, means) in [("Awaiting input ", "waiting for your input"), ("Unread response ", "has an unread reply"),
                                   ("Idle ", "idle"), ("Running ", "still running")] where label.hasPrefix(state) {
                return "session \u{201C}\(label.dropFirst(state.count))\u{201D} (\(means))"
            }
            if label.hasSuffix(", awaiting your input") {
                return "\(label) (switches to the \(label.hasPrefix("Code") ? "Code" : "Claude/Cowork") side, where a session waits for you)"
            }
        }
        guard let list = places[app].map({ $0 + (modes[app] ?? []) }) else { return label }
        let notes = list.filter { $0.click.last.map { same(label, $0) } == true }.map(\.means)
        return notes.isEmpty ? label : "\(label) (\(notes.joined(separator: "; ")))"
    }
}


// MARK: - Browser profiles

/// Chromium browsers (Dia, Chrome, Brave, Edge, Arc) list their profiles in "Local State".
/// Knowing the names lets "switch to the Analytics profile" find the right dot or menu item.
enum BrowserProfiles {
    private static var cache: [pid_t: Set<String>] = [:]

    static func names(pid: pid_t) -> Set<String> {
        if let c = cache[pid] { return c }
        guard let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName else { return [] }
        let sup = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dirs = ["Dia": "Dia/User Data", "Google Chrome": "Google/Chrome", "Brave Browser": "BraveSoftware/Brave-Browser",
                    "Microsoft Edge": "Microsoft Edge", "Arc": "Arc/User Data", "Chromium": "Chromium"]
        var out = Set<String>()
        if let d = dirs[name], let data = try? Data(contentsOf: sup.appendingPathComponent(d + "/Local State")),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = (j["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] {
            for v in info.values {
                if let n = v["name"] as? String, !n.isEmpty { out.insert(n) }
            }
        }
        cache[pid] = out
        return out
    }
}


// MARK: - Your own names for things

/// ~/Library/Application Support/SayOpen/aliases.json maps what you say to what is on screen:
/// {"my work account": "Work"} makes "switch profile to my work account" find
/// the Work profile. Read on every use, so edits apply without a restart.
enum Aliases {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SayOpen/aliases.json")
    }

    static func apply(_ said: String) -> String {
        guard let d = try? Data(contentsOf: url), let map = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return said }
        var out = " " + normalise(said) + " "
        for (k, v) in map.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: " " + normalise(k) + " ", with: " " + v + " ")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
