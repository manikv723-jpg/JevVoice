import AppKit
import ApplicationServices
import Foundation

// Menus drawn in a terminal ("❯ No, exit / Yes, I trust this folder" in Claude Code) are text,
// not buttons, so nothing in them can be clicked. Read the screen, find the list with the
// cursor on it, arrow to the option you named, press Enter.

enum TerminalMenu {
    struct Menu { let options: [String]; let cursor: Int }

    static let terminals: Set<String> = ["Terminal", "iTerm2", "iTerm", "Ghostty", "Warp", "WezTerm", "Alacritty", "kitty"]

    /// The words that pick from a list rather than ask for something new.
    static let pickWords = #"^\s*(yes|yeah|yep|yup|haan|ha|no|nope|nahi|sure|select|choose|pick|option|go with|trust|allow|approve|accept|deny|reject|cancel|don t|do not|the (first|second|third|fourth|last) (one|option)|(first|second|third|fourth|last) (one|option)|number \w+)\b"#

    /// The visible text of the front terminal window.
    static func screen(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let w else { return nil }
        func find(_ el: AXUIElement, _ depth: Int) -> String? {
            guard depth < 8 else { return nil }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXTextArea" {
                var v: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
                if let s = v as? String, !s.isEmpty { return s }
            }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
            for k in (kids as? [AXUIElement]) ?? [] { if let s = find(k, depth + 1) { return s } }
            return nil
        }
        return find(w as! AXUIElement, 0)
    }

    private static let marker = #"^\s*(❯|›|>|→|▸|●)\s+"#
    private static let number = #"^\s*\d+[.)]\s+"#

    /// The last list on screen that has a cursor ("❯") on one of its lines.
    static func menu(in screen: String) -> Menu? {
        let lines = Array(screen.components(separatedBy: "\n").suffix(60))
        guard let at = lines.lastIndex(where: { $0.range(of: marker, options: .regularExpression) != nil }) else { return nil }
        // Options sit on neighbouring lines, indented to where the text after the cursor starts.
        let indent = lines[at].firstIndex { !$0.isWhitespace && !"❯›>→▸●".contains($0) }.map { lines[at].distance(from: lines[at].startIndex, to: $0) } ?? 2
        func isOption(_ l: String) -> Bool {
            if l.range(of: marker, options: .regularExpression) != nil { return true }
            let lead = l.prefix { $0 == " " }.count
            return !l.trimmingCharacters(in: .whitespaces).isEmpty && abs(lead - indent) <= 1
        }
        var lo = at, hi = at
        while lo > 0, isOption(lines[lo - 1]) { lo -= 1 }
        while hi + 1 < lines.count, isOption(lines[hi + 1]) { hi += 1 }
        let opts = lines[lo ... hi].map { l -> String in
            var t = l.replacingOccurrences(of: marker, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: number, with: "", options: .regularExpression)
            return t.trimmingCharacters(in: .whitespaces)
        }
        guard opts.count >= 2, opts.count <= 12 else { return nil }
        return Menu(options: opts, cursor: at - lo)
    }

    /// Which option was named: by number or position, by yes/no, else by shared words.
    static func pick(_ said: String, _ opts: [String]) -> Int? {
        let s = normalise(said)
        let ordinals = ["first": 0, "one": 0, "1": 0, "second": 1, "two": 1, "2": 1, "third": 2, "three": 2, "3": 2,
                        "fourth": 3, "four": 3, "4": 3, "fifth": 4, "five": 4, "5": 4]
        let words = s.split(separator: " ").map(String.init)
        if words.contains("last") && (words.contains("option") || words.contains("one")) { return opts.count - 1 }
        if let i = words.firstIndex(where: { ["option", "number"].contains($0) }), i + 1 < words.count,
           let n = ordinals[words[i + 1]], n < opts.count { return n }
        if let w = words.first(where: { ["first", "second", "third", "fourth", "fifth"].contains($0) }),
           let n = ordinals[w], n < opts.count, words.contains(where: { ["one", "option"].contains($0) }) { return n }
        // Shared words, ignoring filler. "Yes, trust this folder" shares yes/trust/this/folder with
        // "Yes, I trust this folder" and nothing with "No, exit".
        let fill: Set<String> = ["i", "the", "a", "this", "that", "it", "please", "one", "option", "select", "choose", "pick", "go", "with"]
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "haan", "ha", "ok", "okay", "sure", "allow", "approve", "accept", "trust"]
        let no: Set<String> = ["no", "nope", "nahi", "deny", "reject", "cancel", "exit", "don", "dont"]
        let want = Set(words).subtracting(fill)
        var best: (Int, Double)?
        for (i, o) in opts.enumerated() {
            let ow = Set(normalise(o).split(separator: " ").map(String.init))
            var score = Double(want.intersection(ow).count)
            let first = normalise(o).split(separator: " ").first.map(String.init) ?? ""
            if !want.isDisjoint(with: yes) && (first == "yes" || !ow.isDisjoint(with: ["allow", "approve", "trust", "accept"])) { score += 2 }
            if !want.isDisjoint(with: no) && (first == "no" || !ow.isDisjoint(with: ["deny", "reject", "exit"])) { score += 2 }
            if score > (best?.1 ?? 0) { best = (i, score) }
        }
        return best?.0
    }

    /// "Yes, trust this folder" while a terminal in front shows a menu.
    @MainActor
    static func choose(_ said: String, app: NSRunningApplication) async -> Executor.Outcome {
        guard Keys.trusted() else { return Executor.Outcome(ok: false, note: "Allow SayOpen under Accessibility") }
        guard let text = screen(pid: app.processIdentifier), let m = menu(in: text) else {
            return Executor.Outcome(ok: false, note: "no list on screen")
        }
        guard let i = pick(said, m.options) else { return Executor.Outcome(ok: false, note: "none of: \(m.options.joined(separator: " / "))") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let steps = i - m.cursor
        for _ in 0 ..< abs(steps) {
            Keys.press(steps > 0 ? 125 : 126, [])          // down / up arrow
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        Keys.press(36, [])                                  // Return
        dlog("terminal menu: \(m.options) cursor \(m.cursor) -> \(i) \"\(m.options[i])\"")
        return Executor.Outcome(ok: true, note: m.options[i], icon: app.bundleURL?.path)
    }

    /// A terminal is in front, shows a list, and what was said picks from it.
    static func applies(_ said: String, front: NSRunningApplication?) -> Bool {
        guard let front, terminals.contains(front.localizedName ?? ""),
              let text = screen(pid: front.processIdentifier), let m = menu(in: text) else { return false }
        let s = normalise(said)
        if s.range(of: pickWords, options: .regularExpression) != nil { return true }
        // "Move the cursor down to yes I trust this folder": names an option in other words.
        let said = Set(s.split(separator: " ").map(String.init)).subtracting(["i", "the", "a", "to", "this", "that", "it", "on"])
        return m.options.contains { o in said.intersection(normalise(o).split(separator: " ").map(String.init)).count >= 2 }
    }
}
