import Foundation

// The engine without Jev: hand-written patterns, a nickname table and edit-distance name
// matching. Written to be as good as a careful developer would make it in a day, then left
// alone, so the side-by-side is fair. Every line here is something Jev works out on its own.

enum Rules {
    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code", "code": "Visual Studio Code", "settings": "System Settings",
        "system preferences": "System Settings", "preferences": "System Settings", "whatsapp": "WhatsApp",
        "whats app": "WhatsApp", "gpt": "ChatGPT", "chat gpt": "ChatGPT", "chatgpt": "ChatGPT", "obs": "OBS",
        "email": "Mail", "mail": "Mail", "task manager": "Activity Monitor", "activity": "Activity Monitor",
        "docker": "OrbStack", "vpn": "NordVPN", "wispr": "Wispr Flow", "whisper": "Wispr Flow",
        "whisper flow": "Wispr Flow", "grok": "Grok Bot", "camera": "Photo Booth", "files": "Finder",
        "app store": "App Store", "terminal": "Terminal", "claude": "Claude", "cloud": "Claude",
        "quicktime": "QuickTime Player", "grammarly": "Grammarly Desktop", "calculator": "Calculator",
    ]

    static let fill: Set<String> = ["the", "my", "a", "an", "app", "application", "please", "for", "me", "up",
                                    "do", "karo", "kar", "de", "dena", "na", "can", "could", "you", "hey", "ok",
                                    "okay", "now", "to", "in", "on", "it", "this", "that", "and", "then", "just"]

    static func decide(_ clause: String, apps: [AppEntry]) -> Plan? {
        let s = " " + normalise(clause) + " "
        func has(_ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        func grab(_ p: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: m.numberOfRanges - 1), in: s) else { return nil }
            let t = s[r].trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let named = findApp(in: s, apps: apps)

        // voice typing
        if has(#" (let me|i want to|i wanna|start|begin) (type|typing|dictat)"#) || has(" voice typing ")
            || has(" dictation ") { return Plan(action: "dictate") }
        if has(" (open|start|launch) (wispr|whisper) flow ") { return Plan(action: "dictate") }
        if has(#" (press|hit) (enter|return) "#) || has(" run it ") || has(" send it ") { return Plan(action: "press_enter") }

        // tabs and windows
        if has(" (reopen|re open|bring back|restore) (the )?(last |closed )?tab") || has(" undo close tab ") {
            return Plan(action: "reopen_tab")
        }
        if has(" new tab ") || has(" another tab ") || has(" (open|add) (a )?tab ") {
            return Plan(action: "new_tab", app: named?.name)
        }
        if has(" close (this |the )?tab ") { return Plan(action: "close_tab") }
        if has(" next tab ") { return Plan(action: "next_tab") }
        if has(" (previous|last) tab ") { return Plan(action: "previous_tab") }
        if has(" (reload|refresh) ") { return Plan(action: "reload") }
        if has(" go back ") { return Plan(action: "go_back") }
        if has(" go forward ") { return Plan(action: "go_forward") }
        if has(" new window ") { return Plan(action: "new_window", app: named?.name) }
        if has(" close (this |the )?window ") { return Plan(action: "close_window") }
        if has(" minimi[sz]e ") { return Plan(action: "minimize") }
        if has(" full ?screen ") { return Plan(action: "fullscreen") }

        // dictated content
        if let t = grab(#" (?:new|make|create|take|write|add) (?:a )?note (?:saying |called |titled |that says |about )?(.+)"#) {
            return Plan(action: "new_note", text: t)
        }
        if let t = grab(#" remind me to (.+)"#) ?? grab(#" add (.+) to (?:my )?reminders"#) {
            return Plan(action: "new_reminder", text: t)
        }
        if let t = grab(#" (?:search|find|look up|play) (?:for )?(.+) on youtube"#) ?? grab(#" youtube (?:search )?(?:for )?(.+)"#) {
            return Plan(action: "youtube_search", text: t)
        }
        if let t = grab(#" (?:search|google|look up)(?: for| about)? (.+)"#) { return Plan(action: "web_search", text: t) }
        if let t = grab(#" (?:go to|open|visit) ([a-z0-9-]+ ?(?:dot|\.) ?[a-z.]+)"#) { return Plan(action: "open_website", text: t) }

        // system
        if has(" unmute ") { return Plan(action: "volume", setting: "unmute") }
        if has(" mute ") { return Plan(action: "volume", setting: "mute") }
        if has(" volume ") || has(" louder ") || has(" quieter ") || has(" sound ") {
            if has(" (max|maximum|full) ") { return Plan(action: "volume", setting: "max") }
            if has(" (half|50|fifty) ") { return Plan(action: "volume", setting: "half") }
            if has(" (up|louder|increase|raise) ") { return Plan(action: "volume", setting: "up") }
            if has(" (down|quieter|lower|decrease|reduce) ") { return Plan(action: "volume", setting: "down") }
        }
        if has(" (next|skip) (song|track) ") || has(" skip ") { return Plan(action: "media", setting: "next") }
        if has(" previous (song|track) ") { return Plan(action: "media", setting: "previous") }
        if has(" (pause|resume) ") || has(" play (the )?music ") || has(" stop the music ") {
            return Plan(action: "media", setting: "play_pause")
        }
        if has(" dark mode ") || has(" night mode ") { return Plan(action: "appearance", setting: "dark") }
        if has(" light mode ") { return Plan(action: "appearance", setting: "light") }
        if has(" bright(er|ness up| up) ") { return Plan(action: "brightness", setting: "up") }
        if has(" (dim|dimmer|brightness down|darker screen) ") { return Plan(action: "brightness", setting: "down") }
        if has(" screen ?shot ") || has(" capture (the )?screen ") { return Plan(action: "screenshot") }
        if has(" lock (the )?(screen|mac|computer|laptop) ") { return Plan(action: "lock_screen") }
        for f in ["downloads", "desktop", "documents", "applications"] where has(" (open|show|go to)( my| the)? \(f)") {
            return Plan(action: "open_folder", setting: f)
        }

        // inside an app: "open claude code inside claude", "change profile to x", "new chat in claude"
        if has(" inside ") || has(" (change|switch) (the )?(profile|account|org|organisation|organization) ")
            || has(" new chat ") || has(" (open|show) (the )?settings ") {
            return Plan(action: "in_app", app: named?.name, text: clause)
        }

        // apps
        if has(" (quit|close|kill|exit|band karo|band kar) "), let a = named, !has(" (tab|window) ") {
            return Plan(action: "quit_app", app: a.name)
        }
        if has(" (open|launch|start|run|switch to|go to|show|kholo|khol|chalu|chalao) "), let a = named {
            return Plan(action: "open_app", app: a.name)
        }
        return nil
    }

    /// Exact name, then nickname, then the closest spelling (edit distance) of what follows the verb.
    static func findApp(in s: String, apps: [AppEntry]) -> AppEntry? {
        for a in apps.sorted(by: { $0.name.count > $1.name.count }) {
            let n = normalise(a.name)
            if !n.isEmpty, s.contains(" \(n) ") { return a }
        }
        for (alias, target) in aliases.sorted(by: { $0.key.count > $1.key.count }) where s.contains(" \(alias) ") {
            if let a = apps.first(where: { $0.name == target }) { return a }
        }
        let rest = s.split(separator: " ").map(String.init)
            .filter { !fill.contains($0) && !commandWords.contains($0) && !["quit", "close", "kill", "exit"].contains($0) }
            .joined()
        guard rest.count >= 3 else { return nil }
        var best: (AppEntry, Double)?
        for a in apps {
            let n = normalise(a.name).replacingOccurrences(of: " ", with: "")
            let sim = 1 - Double(editDistance(rest, n)) / Double(max(rest.count, n.count))
            if sim > (best?.1 ?? 0) { best = (a, sim) }
        }
        return (best?.1 ?? 0) >= 0.75 ? best?.0 : nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0 ... b.count)
        for i in 1 ... a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1 ... b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
