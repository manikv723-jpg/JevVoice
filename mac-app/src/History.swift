import AppKit
import Foundation
import SQLite3

// "Open the Roadmap 2.0 Google Doc": a page you have been to, found by its title in the browser's
// own history, the way its address bar would suggest it. Works for any doc, sheet, deck or page
// visited before, whether or not a tab still has it open.

enum PageHistory {
    struct Page { let title: String; let url: String; let visits: Int; let lastVisit: Int64 }

    /// Chromium browsers keep one History database per profile.
    static let dirs = ["Dia": "Dia/User Data", "Google Chrome": "Google/Chrome", "Brave Browser": "BraveSoftware/Brave-Browser",
                       "Microsoft Edge": "Microsoft Edge", "Arc": "Arc/User Data", "Chromium": "Chromium"]

    /// Words that say what kind of page, not what it is called. They favour that kind of page.
    static let kinds: [String: String] = ["doc": "docs.google.com/document", "docs": "docs.google.com/document",
                                          "document": "docs.google.com/document", "sheet": "docs.google.com/spreadsheets",
                                          "sheets": "docs.google.com/spreadsheets", "spreadsheet": "docs.google.com/spreadsheets",
                                          "slides": "docs.google.com/presentation", "slide": "docs.google.com/presentation",
                                          "deck": "docs.google.com/presentation", "presentation": "docs.google.com/presentation",
                                          "form": "docs.google.com/forms", "notion": "notion.so", "figma": "figma.com"]

    /// Spoken numbers as the title writes them: "roadmap two point oh" is "roadmap 2 0".
    static func words(_ s: String) -> [String] {
        let n = ["zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                 "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        return normalise(s).split(separator: " ").map(String.init).filter { $0 != "point" }.map { n[$0] ?? $0 }
    }

    static func pages(browser: String) -> [Page] {
        guard let d = dirs[browser] else { return [] }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(d)")
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        var out: [Page] = []
        for p in profiles {
            let src = root.appendingPathComponent("\(p)/History")
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            // The browser holds the file open and locked: read a copy.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("sayopen-history-\(p.replacingOccurrences(of: " ", with: "_"))")
            try? FileManager.default.removeItem(at: copy)
            guard (try? FileManager.default.copyItem(at: src, to: copy)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: copy) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            defer { sqlite3_close(db) }
            let sql = "select title, url, visit_count, last_visit_time from urls where title != '' order by last_visit_time desc limit 4000"
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW {
                guard let t = sqlite3_column_text(st, 0), let u = sqlite3_column_text(st, 1) else { continue }
                out.append(Page(title: String(cString: t), url: String(cString: u),
                                visits: Int(sqlite3_column_int(st, 2)), lastVisit: sqlite3_column_int64(st, 3)))
            }
        }
        return out
    }

    /// The page whose title holds every word you said about it (sounds-alike counts: "road map" is
    /// "Roadmap"), the kind you named first, then the most visited and most recent.
    static func find(_ name: String, kind: String?, browser: String) -> Page? {
        let want = words(name)
        guard !want.isEmpty else { return nil }
        func has(_ title: [String], _ w: String) -> Bool {
            title.contains { t in
                t == w || (w.count >= 3 && (t.hasPrefix(w) || w.hasPrefix(t) && t.count >= 3))
                    || (w.count >= 4 && t.count >= 4 && FileSearch.soundex(t) == FileSearch.soundex(w))
            }
        }
        let prefix = kind.flatMap { kinds[$0] }
        var best: (Page, Double)?
        var seen = Set<String>()
        for p in pages(browser: browser) {
            // One entry per document: the same doc is many URLs (edit, #gid=..., ?tab=...).
            let key = p.title.lowercased()
            guard seen.insert(key).inserted else { continue }
            let tw = words(p.title)
            guard want.allSatisfy({ has(tw, $0) }) else { continue }
            var score = Double(want.count) / Double(max(tw.count, 1))      // "Roadmap 2.0" beats "Roadmap 2.0 old copy"
            if let prefix, p.url.contains(prefix) { score += 1 }
            if p.url.contains("docs.google.com") { score += 0.3 }
            score += min(Double(p.visits), 50) / 500
            if score > (best?.1 ?? 0) { best = (p, score) }
        }
        return best?.0
    }

    /// "open the Roadmap 2.0 google doc" -> ("Roadmap 2.0", "doc").
    static func parse(_ said: String) -> (name: String, kind: String?)? {
        let s = normalise(said)
        let kindWords = kinds.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let re = #"^(?:please )?(?:open|pull up|bring up|show|show me|go to|take me to|switch to|find)(?: up)?(?: the| my| our| that)? (.+?)(?: google)? ("# + kindWords + #")(?: file| page| tab)?$"#
        guard let r = try? NSRegularExpression(pattern: re),
              let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let n = Range(m.range(at: 1), in: s), let k = Range(m.range(at: 2), in: s) else { return nil }
        let name = String(s[n]).replacingOccurrences(of: #"\bgoogle$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, String(s[k]))
    }
}
