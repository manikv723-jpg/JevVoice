import AVFoundation
import AppKit
import Carbon
import Combine
import ServiceManagement
import Speech
import SwiftUI

// SayOpen: lives in the notch. You talk, it does what you asked: opens apps, tabs, searches,
// notes, volume, voice typing through Wispr Flow. Two engines decide side by side:
//   Jev    one TypeSafe request per clause (JevEngine.swift), plus an exact-name fast path
//   Rules  hand-written patterns and fuzzy matching, no model (Rules.swift)
// Speech is recognised on device. The only network call is the Jev request.


/// Plain-text trace of what SayOpen is doing: ~/Library/Application Support/SayOpen/debug.log
func dlog(_ msg: String) {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SayOpen", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("debug.log")
    let line = ISO8601DateFormatter().string(from: Date()) + "  " + msg + "\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

let threshold = 0.50   // Jev confidence needed to open something; 0.60 cost two right answers on the bench
let maxApps = 250      // a Choice takes up to 255 options

// MARK: - App index

struct AppEntry {
    let name: String
    let url: URL
    let category: String?
    let uses: Int          // Spotlight's launch count, used to rank names for the speech recogniser
    let agent: Bool        // menu-bar or background agent (LSUIElement): rarely opened by hand
}

/// Background helpers, installers and uninstallers are never what someone means by "open X".
let junkName = try! NSRegularExpression(
    pattern: #"\b(helper|installer|uninstaller|uninstall|diagnostics|cleanup|updater|url handler|agent)\b|CleanUpUtility|Process$"#,
    options: [.caseInsensitive])

enum AppIndex {
    /// Every app bundle on the Mac, labelled only with the category it declares itself.
    static func scan() -> [AppEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [(URL, Int)] = [
            (URL(fileURLWithPath: "/Applications"), 3),
            (home.appendingPathComponent("Applications"), 3),
            (URL(fileURLWithPath: "/System/Applications"), 2),
            (URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), 0),
        ]
        var byName: [String: AppEntry] = [:]
        for (root, depth) in roots {
            for b in bundles(root, depth) {
                let name = b.deletingPathExtension().lastPathComponent
                guard byName[name] == nil, name != "SayOpen" else { continue }
                let info = NSDictionary(contentsOf: b.appendingPathComponent("Contents/Info.plist"))
                if info?["LSBackgroundOnly"] as? Bool == true { continue }
                let range = NSRange(name.startIndex..., in: name)
                if junkName.firstMatch(in: name, range: range) != nil { continue }
                byName[name] = AppEntry(name: name, url: b, category: category(info), uses: useCount(b),
                                        agent: (info?["LSUIElement"] as? Bool) == true
                                            || (info?["LSUIElement"] as? String) == "1")
            }
        }
        let sorted = byName.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return Array(sorted.prefix(maxApps))
    }

    private static func bundles(_ url: URL, _ depth: Int) -> [URL] {
        let fm = FileManager.default
        if url.pathExtension == "app" { return fm.fileExists(atPath: url.path) ? [url] : [] }
        guard depth >= 0,
              // Not .skipsHiddenFiles: /Applications/Safari.app is a link carrying the hidden flag.
              let kids = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var out: [URL] = []
        for k in kids.sorted(by: { $0.path < $1.path }) where !k.lastPathComponent.hasPrefix(".") {
            if k.pathExtension == "app" {
                out.append(k)                    // never descend into a bundle
            } else if depth > 0, (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out += bundles(k, depth - 1)
            }
        }
        return out
    }

    private static func useCount(_ bundle: URL) -> Int {
        guard let item = MDItemCreateWithURL(nil, bundle as CFURL),
              let n = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber else { return 0 }
        return n.intValue
    }

    private static func category(_ info: NSDictionary?) -> String? {
        guard let c = info?["LSApplicationCategoryType"] as? String, !c.isEmpty,
              let last = c.split(separator: ".").last
        else { return nil }
        return last.replacingOccurrences(of: "-", with: " ")
    }
}

func normalise(_ s: String) -> String {
    let mapped = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
    return String(mapped).split(separator: " ").joined(separator: " ")
}

/// Words that make something a command, and polite filler around it. These are about how
/// people ask, not about any app, so this list does not grow when apps are installed.
let commandWords: Set<String> = ["open", "launch", "start", "run", "show", "khol", "kholo", "kholdo", "chalu",
                                 "chalao", "bring", "fire", "pull"]
let fillerWords: Set<String> = ["the", "my", "app", "application", "please", "for", "me", "up", "do", "karo",
                                "kar", "de", "dena", "na", "can", "could", "you", "hey", "ok", "okay", "now", "to"]

/// "open Slack", "launch the Figma app", "Claude kholo": a command word, the app's exact name,
/// and nothing else but filler. Opens with no network call. Anything looser goes to Jev, which
/// also judges whether the speaker is asking at all, so "I love music" does not open Music.
func exactMatch(_ text: String, _ apps: [AppEntry]) -> AppEntry? {
    let words = normalise(text).split(separator: " ").map(String.init)
    guard words.contains(where: commandWords.contains) else { return nil }
    let rest = words.filter { !commandWords.contains($0) && !fillerWords.contains($0) }.joined(separator: " ")
    guard !rest.isEmpty else { return nil }
    return apps.first { normalise($0.name) == rest }
}

// MARK: - Key storage

/// The API key lives in a file only your user account can read (mode 600), like `gh` or `npm`
/// store tokens. The Keychain was tried first, but an unsigned app looks new to it after every
/// update, so macOS kept asking for the login password.
enum KeyStore {
    static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SayOpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("typesafe-key")
    }()

    static func read() -> String {
        if let k = try? String(contentsOf: file, encoding: .utf8) {
            return k.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func write(_ value: String) {
        guard !value.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        FileManager.default.createFile(atPath: file.path, contents: Data(value.utf8),
                                       attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - History: every app opened, and when

struct Opening: Identifiable {
    let id = UUID()
    let app: String
    let path: String
    let at: Date
    let ms: Int            // from the moment you said it to the moment it opened
    let how: String        // "name" or "Jev 0.93"
    let said: String
}

/// A CSV you can open in Numbers: ~/Library/Application Support/SayOpen/history.csv
enum History {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SayOpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.csv")
    }()
    static let header = "opened_at,app,seconds_after_speaking,decided_by,you_said,app_path\n"
    static let iso = ISO8601DateFormatter()

    static func append(_ o: Opening) {
        let row = [iso.string(from: o.at), o.app, String(format: "%.2f", Double(o.ms) / 1000), o.how, o.said, o.path]
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: ",") + "\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(row.utf8))
            try? h.close()
        }
    }

    static func load(limit: Int = 50) -> [Opening] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let rows = text.split(separator: "\n").dropFirst().suffix(limit)
        return rows.reversed().compactMap { line in
            let f = parse(String(line))
            guard f.count >= 6, let at = iso.date(from: f[0]) else { return nil }
            return Opening(app: f[1], path: f[5], at: at, ms: Int((Double(f[2]) ?? 0) * 1000), how: f[3], said: f[4])
        }
    }

    private static func parse(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { cur.append("\""); chars.removeFirst() } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true } else if c == "," { out.append(cur); cur = "" } else { cur.append(c) }
        }
        out.append(cur)
        return out
    }
}

/// "instant" when the exact name opened it with no network call, otherwise seconds.
func took(_ ms: Int) -> String { ms < 60 ? "instant" : String(format: "%.2fs", Double(ms) / 1000) }

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm:ss a"
    return f
}()

let dayClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM, h:mm a"
    return f
}()

