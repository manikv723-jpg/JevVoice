import Foundation

// The Jev engine. One request per clause asks every question at once, in parallel, against the
// same state: which action, which app, which words are the content, which setting, and whether
// this is a command at all. Most answers go unused for any one clause; a second round trip would
// cost ~400ms, so asking speculatively is the cheaper side of the trade.

enum JevError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case let .http(code, body): return code == 401 ? "API key rejected" : "Jev error \(code): \(body.prefix(80))"
        }
    }
}

struct JevVerdict {
    var plan: Plan?
    var why: String         // one line for the notch and the log
    var ms: Int
}

/// Every contiguous run of words (up to 12) from the clause. Jev picks which one is the content,
/// so whatever reaches a search box or a note is words the speaker actually said.
func spans(_ clause: String) -> [String] {
    let w = Array(clause.split(separator: " ").map(String.init).suffix(16))
    var out: [String] = []
    var seen = Set<String>()
    for i in 0 ..< w.count {
        for j in (i + 1) ... min(w.count, i + 12) {
            let s = w[i ..< j].joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            if !s.isEmpty, seen.insert(s.lowercased()).inserted { out.append(s) }
        }
    }
    return Array(out.prefix(200))
}

/// The action options Jev chooses between. SAYOPEN_HIDE=id,id leaves some out, for measuring.
private func actionCriteria() -> [String: Any] {
    let hidden = Set((ProcessInfo.processInfo.environment["SAYOPEN_HIDE"] ?? "").split(separator: ",").map(String.init))
    var out: [String: Any] = [:]
    for c in capabilities where !hidden.contains(c.id) { out[c.id] = c.say }
    return out
}

final class JevEngine {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpShouldUsePipelining = true
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()
    /// A fresh HTTPS connection to Jev costs ~1s (TLS) before any answer; a reused one costs nothing.
    /// The connection goes cold between commands, so the first word you speak pays for it. `warm()`
    /// opens it as soon as you start talking, and keeps it open for a few minutes after.
    private var lastWarm = Date.distantPast
    private var lastSpoke = Date.distantPast
    private var keepAlive: Timer?

    func warm() {
        lastSpoke = Date()
        if keepAlive == nil {
            keepAlive = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                guard let self, Date().timeIntervalSince(self.lastSpoke) < 240 else { return }
                self.ping()
            }
        }
        if Date().timeIntervalSince(lastWarm) > 15 { ping() }
    }

    private func ping() {
        lastWarm = Date()
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/")!)
        req.httpMethod = "HEAD"
        session.dataTask(with: req).resume()
    }

    private var appQuestion: [String: Any] = [:]
    private var appNames = Set<String>()

    private let fixed: [String: Any] = {
        var q: [String: Any] = [
            "action": [
                "type": "choice",
                "instructions": "`instruction` is one clause of what someone is saying to their Mac, possibly "
                    + "mid-sentence, misheard by speech recognition, or in Hinglish (kholo = open, band karo = close "
                    + "or stop, chalao = play). Which one of these should the Mac do for it? A complaint about the "
                    + "computer implies the fix ('it's too loud' means turn the volume down). `earlier` lists what "
                    + "was already done for earlier clauses of the same sentence.",
                "criteria": actionCriteria()
                    .merging(["none": "Not an instruction: conversation, thinking aloud, or a half-finished phrase.",
                              "other": "An instruction to the computer that none of the other options covers."]) { a, _ in a },
            ],
            "asking": [
                "type": "noul",
                "instructions": "Is the speaker telling the computer what they want it to do, or what they want "
                    + "to do on it next? Casual, Hinglish and misheard commands count, and so do complaints about "
                    + "the computer that imply a fix ('it's too loud'). Remarks and opinions in conversation, and "
                    + "stories about things done earlier, do not.",
            ],
        ]
        for (name, opts) in settingOptions {
            q["setting:\(name)"] = ["type": "choice", "instructions": "If `instruction` is about \(name), which option?",
                                    "criteria": opts]
        }
        return q
    }()

    func setApps(_ apps: [AppEntry]) {
        var criteria: [String: Any] = [:]
        for a in apps { criteria[a.name] = a.category.map { "category: \($0)" } ?? NSNull() }
        criteria["none"] = "No app is named or meant."
        appNames = Set(apps.map(\.name))
        appQuestion = [
            "type": "choice",
            "instructions": "Which installed app does `instruction` name or mean, if any? That includes the app to "
                + "act inside ('a new tab in terminal' means Terminal). Speech recognition often mishears app names "
                + "as ordinary words that sound alike, and the speaker may use Hinglish. Match loosely: nicknames, "
                + "what the app is for, words that sound like the name. Pick 'none' if no app is meant or it is "
                + "not in this list.",
            "criteria": criteria,
        ]
    }

    /// One pick among things on screen: a pop-up's buttons, a sidebar of sessions. `none`, when
    /// given, lets Jev say the words are about none of them. Returns the index and Jev's confidence.
    func choose(said: String, context: [String: Any] = [:], instructions: String, options: [String],
                none: String?, key: String) async -> (Int?, Double) {
        var crit: [String: Any] = [:]
        for (i, o) in options.enumerated() { crit["o\(i)"] = o }
        if let none { crit["none"] = none }
        let q: [String: Any] = ["pick": ["type": "choice", "instructions": instructions, "criteria": crit]]
        var state = context
        state["said"] = said
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["state": state, "model": "jev-latest", "questions": q])
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = (j["answers"] as? [String: Any])?["pick"] as? [String: Any],
              let choice = a["choice"] as? String else { return (nil, 0) }
        let conf = (a["confidence"] as? NSNumber)?.doubleValue ?? 0
        dlog("jev choose: \(choice) \(String(format: "%.2f", conf)) for \"\(said)\"")
        guard choice.hasPrefix("o"), let i = Int(choice.dropFirst()), i < options.count else { return (nil, conf) }
        return (i, conf)
    }

    /// Which of the candidate files is the one meant. There is no "none": the search already
    /// narrowed things down, so Jev's job is to put its probability on the likeliest one.
    func pickFile(said: String, labels: [String], key: String) async -> Int? {
        var crit: [String: Any] = [:]
        for (i, l) in labels.enumerated() { crit["f\(i)"] = l }
        let q: [String: Any] = ["file": ["type": "choice",
            "instructions": "`said` is how someone described, out loud, a file to open. Speech recognition "
                + "mishears names ('Jeff' for Jev, 'Kaydence' for Cadence) and people describe files loosely "
                + "('my PPT which I built with Jev' can be a slide saved as png, html or pdf, 'the deck' can "
                + "be a pdf). Each option is a file on their Mac with its folder and when it last changed. "
                + "Which is the file they most likely mean? A file that opens in a desktop app (pdf, pptx, key, "
                + "png, mp4) beats a web page (html), source code or a folder unless they asked for those. When several fit equally, prefer the "
                + "most recently changed one.", "criteria": crit]]
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["state": ["said": said], "model": "jev-latest", "questions": q])
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = (j["answers"] as? [String: Any])?["file"] as? [String: Any],
              let choice = a["choice"] as? String, choice.hasPrefix("f") else { return nil }
        return Int(choice.dropFirst())
    }

    /// One step of doing something inside an app: which of the things on screen to click next.
    /// Returns nil when Jev says the goal is done, or that nothing here helps.
    func pickClick(goal: String, app: String, clicked: [String], labels: [String], key: String) async -> Int? {
        var crit: [String: Any] = [
            "done": "The clicks so far already did what was asked.",
            "none": "Nothing listed gets closer to what was asked.",
        ]
        for (i, l) in labels.enumerated() { crit["e\(i)"] = l }
        let q: [String: Any] = ["click": [
            "type": "choice",
            "instructions": "`goal` is what someone asked the app `app` to do. `clicked` is what has been clicked so "
                + "far, in order. Each option is something that can be clicked in that app right now: on-screen "
                + "buttons, tabs, list rows, and menu items shown with their menu path. Which one should be clicked "
                + "next to get closer to the goal? After opening a menu or popup, its items appear as options.",
            "criteria": crit,
        ]]
        let state: [String: Any] = ["goal": goal, "app": app, "clicked": clicked.isEmpty ? ["nothing yet"] : clicked]
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["state": state, "model": "jev-latest", "questions": q])
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = (j["answers"] as? [String: Any])?["click"] as? [String: Any],
              let choice = a["choice"] as? String else { return nil }
        let conf = (a["confidence"] as? NSNumber)?.doubleValue ?? 0
        // With ~200 things on screen the probability spreads thin even when the pick is clearly
        // right ("Go > Code" at 0.3). Accept a clear winner: 0.4, or 0.2 and twice the runner-up.
        let probs = ((a["probabilities"] as? [String: Any]) ?? [:]).compactMap { ($0.value as? NSNumber)?.doubleValue }
            .sorted(by: >)
        let runnerUp = probs.count > 1 ? probs[1] : 0
        let clear = conf >= 0.4 || (conf >= 0.2 && conf >= 2 * runnerUp)
        dlog("jev click: \(choice == "done" || choice == "none" ? choice : labels[Int(choice.dropFirst()) ?? 0]) "
            + String(format: "%.2f (next %.2f)", conf, runnerUp))
        guard choice.hasPrefix("e"), clear, let i = Int(choice.dropFirst()) else { return nil }
        return i
    }

    func decide(_ clause: String, earlier: [String], front: String?, alternatives: [String],
                key: String) async throws -> JevVerdict {
        var questions = fixed
        questions["app"] = appQuestion
        let cands = spans(clause)
        if !cands.isEmpty {
            var crit: [String: Any] = ["none": "No content was dictated."]
            for (i, s) in cands.enumerated() { crit["s\(i)"] = s }
            questions["text"] = [
                "type": "choice",
                "instructions": "Each option is words taken from `instruction`. Which is exactly the content the "
                    + "speaker dictated: the search query, the website, or the note or reminder text? Leave out "
                    + "command words ('search for', 'google', 'find', 'play', 'remind me to', 'note that') and where "
                    + "to look ('on youtube', 'on google'). Pick 'none' if nothing was dictated.",
                "criteria": crit,
            ]
        }
        var state: [String: Any] = ["instruction": clause, "earlier": earlier.isEmpty ? ["nothing yet"] : earlier]
        if let front { state["app in front"] = front }
        if !alternatives.isEmpty { state["speech recognition also heard it as"] = alternatives }

        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["state": state, "model": "jev-latest",
                                                                   "questions": questions])
        let t0 = Date()
        let (data, resp) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw JevError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let answers = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["answers"] as? [String: Any] ?? [:]

        func pick(_ q: String) -> (String, Double) {
            let a = answers[q] as? [String: Any]
            return (a?["choice"] as? String ?? "none", (a?["confidence"] as? NSNumber)?.doubleValue ?? 0)
        }
        let (action, aConf) = pick("action")
        let asking = ((answers["asking"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue ?? 0
        let (app, appConf) = pick("app")
        let (textKey, _) = pick("text")
        let why = String(format: "%@ %.2f, asking %.2f, app %@ %.2f", action, aConf, asking, app, appConf)

        guard let cap = capabilityByID[action], aConf >= threshold, asking >= 0.5 else {
            return JevVerdict(plan: nil, why: why, ms: ms)
        }
        var plan = Plan(action: action)
        if app != "none", appConf >= threshold, appNames.contains(app) { plan.app = app }
        // Acting mid-clause needs more than the usual bar: "Open term" once opened Dia at 0.67.
        plan.sure = aConf >= 0.8 && (plan.app == nil || appConf >= 0.8)
        switch cap.need {
        case .app:
            if plan.app == nil { return JevVerdict(plan: nil, why: why + ", no app", ms: ms) }
        case .text:
            guard textKey != "none", let i = Int(textKey.dropFirst()), i < cands.count else {
                return JevVerdict(plan: nil, why: why + ", no text", ms: ms)
            }
            plan.text = cands[i]
        case let .setting(name):
            plan.setting = pick("setting:\(name)").0
        case .nothing:
            if action == "in_app" { plan.text = clause }
        }
        return JevVerdict(plan: plan, why: why, ms: ms)
    }
}
