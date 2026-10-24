#!/usr/bin/env python3
"""Say an app, it opens. Three ways to decide which app, so they can be compared.

  hard    plain code: exact names, a hand-written alias table, fuzzy spelling
  jev     one Jev Choice over every app on this Mac, nothing hand-written
  hybrid  hard when the transcript contains an app's exact name (0ms), Jev otherwise

  ./listen | python launcher.py              live, fires mid-sentence
  python launcher.py --say "open the thing I edit 3d stuff in"
  python launcher.py --apps                  what it can open
  python launcher.py --bench                 score all three modes on bench.json
"""

import argparse
import difflib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import threading
import time

HERE = pathlib.Path(__file__).parent
ROOTS = [("/Applications", 3), (str(pathlib.Path.home() / "Applications"), 3),
         ("/System/Applications", 2), ("/System/Library/CoreServices/Finder.app", 0)]
THRESHOLD = 0.50        # Jev confidence needed to open something
NONE = "none"


# ---------------------------------------------------------------- app index

def _bundles(root: str, depth: int):
    p = pathlib.Path(root)
    if p.suffix == ".app":
        if p.is_dir():
            yield p
        return
    if not p.is_dir() or depth < 0:
        return
    for child in sorted(p.iterdir()):
        if child.suffix == ".app":
            yield child                     # never descend into a bundle
        elif child.is_dir() and depth > 0 and not child.name.startswith("."):
            yield from _bundles(str(child), depth - 1)


def _category(info: dict) -> str | None:
    cat = info.get("LSApplicationCategoryType", "")
    cat = cat.rsplit(".", 1)[-1].replace("-", " ") if cat else ""
    return cat or None


def index_apps() -> dict[str, dict]:
    """Every app bundle on the Mac, keyed by the name you would say out loud.

    The only description attached is the category the app declares about itself.
    Nothing here is written by hand, so installing an app is all it takes.
    """
    apps: dict[str, dict] = {}
    for root, depth in ROOTS:
        for b in _bundles(root, depth):
            try:
                with open(b / "Contents" / "Info.plist", "rb") as f:
                    info = plistlib.load(f)
            except (OSError, plistlib.InvalidFileException, ValueError):
                info = {}
            name = b.stem
            apps.setdefault(name, {"path": str(b), "category": _category(info)})
    return dict(sorted(apps.items(), key=lambda kv: kv[0].lower()))


def open_app(name: str, apps: dict[str, dict]) -> float:
    t0 = time.monotonic()
    subprocess.Popen(["open", apps[name]["path"]],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return (time.monotonic() - t0) * 1000


# ---------------------------------------------------------------- hardcoded

# What a person writes by hand to cover the obvious nicknames. Every line here
# is a thing Jev is expected to work out on its own.
ALIASES = {
    "chrome": "Google Chrome", "google": "Google Chrome", "browser": "Safari",
    "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
    "settings": "System Settings", "preferences": "System Settings",
    "whatsapp": "WhatsApp", "whats app": "WhatsApp", "gpt": "ChatGPT", "chat gpt": "ChatGPT",
    "obs": "OBS", "email": "Mail", "mail": "Mail", "calendar": "Calendar",
    "task manager": "Activity Monitor", "activity": "Activity Monitor",
    "docker": "OrbStack", "vpn": "NordVPN", "wispr": "Wispr Flow", "whisper": "Wispr Flow",
    "grok": "Grok Bot", "music": "Music", "camera": "Photo Booth", "files": "Finder",
    "finder": "Finder", "app store": "App Store", "terminal": "Terminal",
}
FILLER = re.compile(r"\b(open|opens|opening|launch|start|run|up|the|my|a|an|app|application|"
                    r"please|can|you|could|for|me|kholo|khol|do|karo|chalu|kar|de|dena|"
                    r"hey|go|to|and|then|now|i|want|need)\b", re.I)


def hard_pick(text: str, apps: dict[str, dict], fuzzy: bool = True) -> tuple[str, float]:
    low = " " + re.sub(r"[^a-z0-9 ]", " ", text.lower()) + " "
    # 1. an app's exact name in the transcript, longest wins ("Antigravity IDE" over "Antigravity")
    for name in sorted(apps, key=len, reverse=True):
        if f" {name.lower()} " in low:
            return name, 1.0
    # 2. hand-written nicknames
    for alias in sorted(ALIASES, key=len, reverse=True):
        if f" {alias} " in low and ALIASES[alias] in apps:
            return ALIASES[alias], 0.9
    if not fuzzy:
        return NONE, 0.0
    # 3. spelling slips: "tell a gram", "grammerly"
    rest = re.sub(r"\s+", " ", FILLER.sub(" ", low)).strip()
    if not rest:
        return NONE, 0.0
    squashed = {n.lower().replace(" ", ""): n for n in apps}
    hit = difflib.get_close_matches(rest.replace(" ", ""), squashed, n=1, cutoff=0.75)
    if hit:
        return squashed[hit[0]], 0.6
    return NONE, 0.0


# ---------------------------------------------------------------- Jev

class Jev:
    def __init__(self, apps: dict[str, dict]):
        from typesafe_sdk import Choice, TypeSafeClient
        self.client = TypeSafeClient()
        self.question = {
            "app": Choice(
                instructions=(
                    "`said` is speech from someone talking to their Mac, possibly mid-sentence, "
                    "possibly misheard by speech recognition, possibly in Hinglish. Which of these "
                    "installed apps do they want opened? Match loosely: nicknames, what the app is "
                    "for, and words that sound like the name all count. Pick 'none' if they are not "
                    "asking for an app, or the app they name is not in this list."
                ),
                criteria={**{n: (f"category: {a['category']}" if a["category"] else None)
                             for n, a in apps.items()},
                          NONE: "Not asking to open an app, or the app is not installed."},
            )
        }
        self._cache: dict[str, tuple[str, float, int]] = {}

    def warm(self) -> None:
        try:
            self.pick("open notes")
        except Exception:
            pass
        self._cache.clear()

    def pick(self, text: str) -> tuple[str, float, int]:
        key = text.strip().lower()
        if key in self._cache:
            return (*self._cache[key][:2], 0)
        t0 = time.monotonic()
        r = self.client.system_one(state={"said": text}, questions=self.question)
        ans = r.choices["app"]
        out = (ans.choice, float(ans.confidence), int((time.monotonic() - t0) * 1000))
        self._cache[key] = out
        return out


def decide(text: str, mode: str, apps, jev: Jev | None) -> tuple[str, float, int, str]:
    """Returns (app, confidence, ms, who decided)."""
    if mode in ("hard", "hybrid"):
        t0 = time.perf_counter()
        name, conf = hard_pick(text, apps, fuzzy=(mode == "hard"))
        ms = (time.perf_counter() - t0) * 1000
        if mode == "hard" or conf >= 1.0:
            return name, conf, round(ms, 2), "code"
    name, conf, ms = jev.pick(text)
    return name, conf, ms, "jev"


# ---------------------------------------------------------------- live

class Live:
    """Judges the newest partial transcript with one request in flight, opens on the first
    confident answer, and goes quiet for the rest of that utterance.

    Each utterance gets an id. A final transcript always gets its own judgment, so
    the complete sentence is never dropped, and a slow answer about an old utterance
    can never open something while you are saying the next one.
    """

    def __init__(self, mode, apps, jev, dry):
        self.mode, self.apps, self.jev, self.dry = mode, apps, jev, dry
        self.uid, self.latest, self.heard_at = 0, "", 0.0
        self.fired: set[int] = set()
        self.busy = False
        self.lock = threading.Lock()
        self.threads: list[threading.Thread] = []

    def _spawn(self, fn, *args) -> None:
        t = threading.Thread(target=fn, args=args, daemon=True)
        self.threads.append(t)
        t.start()

    def feed(self, text: str, final: bool) -> None:
        with self.lock:
            if text != self.latest:
                self.latest, self.heard_at = text, time.monotonic()
            uid = self.uid
            go = bool(text.strip()) and uid not in self.fired and not self.busy
            if go:
                self.busy = True
            if final:
                self.uid += 1
                self.latest = ""
        if final and text.strip():
            self._spawn(self._decide_once, uid, text, time.monotonic())
        elif go:
            self._spawn(self._follow)

    def _fire(self, uid, text, heard, name, conf, ms, who) -> bool:
        with self.lock:
            if uid in self.fired:
                return False
            self.fired.add(uid)
        open_ms = 0.0 if self.dry else open_app(name, self.apps)
        total = int((time.monotonic() - heard) * 1000)
        print(f"  → {name:<22} {conf:.2f}  {who} {ms}ms  open {open_ms:.0f}ms  "
              f"heard→open {total}ms   \"{text}\"", flush=True)
        return True

    def _decide_once(self, uid, text, heard) -> None:
        if uid in self.fired:
            return
        name, conf, ms, who = decide(text, self.mode, self.apps, self.jev)
        if name != NONE and conf >= THRESHOLD:
            self._fire(uid, text, heard, name, conf, ms, who)
        elif uid not in self.fired:
            print(f"  · {text!r:<44} {name} {conf:.2f} ({who} {ms}ms) final, nothing opened", flush=True)

    def _follow(self) -> None:
        """Chase the partial transcript until something fires or it stops changing."""
        try:
            while True:
                with self.lock:
                    uid, text, heard = self.uid, self.latest, self.heard_at
                if not text or uid in self.fired:
                    break
                name, conf, ms, who = decide(text, self.mode, self.apps, self.jev)
                if name != NONE and conf >= THRESHOLD:
                    self._fire(uid, text, heard, name, conf, ms, who)
                    break
                print(f"  · {text!r:<44} {name} {conf:.2f} ({who} {ms}ms)", flush=True)
                with self.lock:
                    if self.latest == text:     # nothing new arrived while we were asking
                        break
        finally:
            with self.lock:
                self.busy = False

    def drain(self) -> None:
        for t in self.threads:
            t.join(timeout=10)


def run_live(mode, apps, jev, dry) -> None:
    live = Live(mode, apps, jev, dry)
    print(f"{mode}: {len(apps)} apps. say 'open ...'. ctrl-c to stop.", flush=True)
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        live.feed(msg.get("text", ""), bool(msg.get("final")))
    live.drain()


# ---------------------------------------------------------------- bench

def run_bench(apps, jev, modes) -> None:
    cases = json.loads((HERE / "bench.json").read_text())["cases"]
    missing = {a for c in cases for a in c["want"] if a != NONE and a not in apps}
    if missing:
        sys.exit(f"bench.json names apps that are not installed: {sorted(missing)}")
    rows, score = [], {m: {} for m in modes}
    for c in cases:
        row = {"said": c["said"], "kind": c["kind"], "want": c["want"]}
        for m in modes:
            if jev:
                jev._cache.clear()          # every mode pays for its own Jev calls
            name, conf, ms, who = decide(c["said"], m, apps, jev)
            opened = name if (name != NONE and conf >= THRESHOLD) else NONE
            ok = opened in c["want"]
            row[m] = {"pick": name, "conf": round(conf, 3), "ms": ms, "who": who, "ok": ok}
            s = score[m].setdefault(c["kind"], [0, 0, []])
            s[0] += ok
            s[1] += 1
            s[2].append(ms)
        rows.append(row)
        marks = "  ".join(f"{m}:{'✓' if row[m]['ok'] else '✗'} {row[m]['pick']}" for m in modes)
        print(f"{c['kind']:<11} {c['said'][:44]:<44} {marks}", flush=True)

    print()
    kinds = list(dict.fromkeys(c["kind"] for c in cases))
    print(f"{'':<12}" + "".join(f"{m:>16}" for m in modes))
    for k in kinds + ["ALL"]:
        cells = []
        for m in modes:
            if k == "ALL":
                ok = sum(v[0] for v in score[m].values())
                n = sum(v[1] for v in score[m].values())
            else:
                ok, n, _ = score[m][k]
            cells.append(f"{ok}/{n} {100 * ok // n:>3}%")
        print(f"{k:<12}" + "".join(f"{c:>16}" for c in cells))
    print()
    for m in modes:
        ms = sorted(x for v in score[m].values() for x in v[2])
        print(f"{m:<8} latency  median {ms[len(ms) // 2]}ms   p90 {ms[int(len(ms) * .9)]}ms")
    out = HERE / "bench_results.json"
    out.write_text(json.dumps({"apps": len(apps), "threshold": THRESHOLD, "rows": rows}, indent=1))
    print(f"\nper-case detail → {out.name}")


# ---------------------------------------------------------------- main

def load_env() -> None:
    env = HERE / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            k, sep, v = line.partition("=")
            if sep and k.strip() and not k.startswith("#"):
                os.environ.setdefault(k.strip(), v.strip().strip("\"'"))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["hard", "jev", "hybrid"], default="hybrid")
    p.add_argument("--say", help="decide on this text instead of listening")
    p.add_argument("--apps", action="store_true", help="list every app it can open")
    p.add_argument("--bench", action="store_true", help="score hard / jev / hybrid on bench.json")
    p.add_argument("--dry", action="store_true", help="decide but do not open anything")
    a = p.parse_args()

    t0 = time.monotonic()
    apps = index_apps()
    scan_ms = int((time.monotonic() - t0) * 1000)
    if a.apps:
        for n, info in apps.items():
            print(f"{n:<40} {info['category'] or ''}")
        print(f"\n{len(apps)} apps, indexed in {scan_ms}ms")
        return

    load_env()
    needs_jev = a.bench or a.mode != "hard"
    jev = Jev(apps) if needs_jev else None
    if jev:
        jev.warm()

    if a.bench:
        run_bench(apps, jev, ["hard", "jev", "hybrid"])
    elif a.say:
        name, conf, ms, who = decide(a.say, a.mode, apps, jev)
        if name != NONE and conf >= THRESHOLD:
            open_ms = 0.0 if a.dry else open_app(name, apps)
            print(f"→ {name}  {conf:.2f}  ({who} {ms}ms, open {open_ms:.0f}ms)")
        else:
            print(f"· nothing opened (best guess {name} {conf:.2f}, {who} {ms}ms)")
    else:
        run_live(a.mode, apps, jev, a.dry)


if __name__ == "__main__":
    main()
