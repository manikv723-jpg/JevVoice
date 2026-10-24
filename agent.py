#!/usr/bin/env python3
"""Voice agent on Jev.

Reads partial transcripts from stdin (JSON lines from ./listen), asks Jev one
fan-out question set per clause, and fires the Mac action the moment the
probabilities cross a threshold. It does not wait for you to stop talking.

Generality comes from three places, not from the model writing code:

  1. every installed app is an option, discovered at startup
  2. skills.json is the capability menu, editable without touching Python
  3. anything the menu misses goes to `other`, which asks Claude for a command
     and shows it to you before anything runs

Jev never writes a string here. It points at options this file assembled.
"""

import argparse
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse

from typesafe_sdk import Choice, Noul, TypeSafeClient

HERE = pathlib.Path(__file__).parent
APP_DIRS = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
            str(pathlib.Path.home() / "Applications")]
MAX_APPS = 200          # a Choice takes up to 255 options

# A run-on sentence is several instructions strung together. Code finds the
# seams; Jev judges one clause at a time. Splitting here rather than after the
# fact is what stops a fired action from cutting a phrase in half.
SEAM = re.compile(r"\b(?:and also|and then|and|then|also|plus|after that)\b", re.I)
CUES = r"called|titled|named|say|says|saying|search for|searching for|look up|google|remind me to|copy|find"
CLOSED_THRESHOLD = 0.30   # bar for a clause the speaker has already moved past

# Never run these, whoever proposed them.
FORBIDDEN = re.compile(
    r"\b(sudo|rm\s|rmdir|mkfs|diskutil|dd\s|shutdown|reboot|killall\s+-9|launchctl|"
    r"csrutil|defaults\s+delete|chmod\s+777|curl[^|]*\|\s*(sh|bash)|>\s*/dev/)", re.I)


def discover_apps() -> dict[str, str]:
    """Every app on this Mac becomes an option. No hardcoded list to outgrow."""
    found: dict[str, str] = {}
    for d in APP_DIRS:
        p = pathlib.Path(d)
        if not p.is_dir():
            continue
        for app in sorted(p.glob("*.app")):
            name = app.stem
            found.setdefault(name, name)
    return dict(sorted(found.items())[:MAX_APPS])


def load_skills() -> list[dict]:
    return json.loads((HERE / "skills.json").read_text())["capabilities"]


def clauses(text: str) -> list[str]:
    return [p for p in (s.strip(" ,.?!") for s in SEAM.split(text)) if p]


def spans(text: str, limit: int = 8) -> list[str]:
    """Candidate dictated phrases pulled out of one clause by plain code.

    Jev selects one of these. It never invents the string, so whatever reaches
    Notes or the clipboard is text the speaker actually said.
    """
    out: list[str] = []
    for m in re.finditer(r"[\"'“”‘’](.+?)[\"'“”‘’]", text):
        out.append(m.group(1))
    for m in re.finditer(rf"\b(?:{CUES})\b[,:]?\s+(.+)", text, re.I):
        out.append(m.group(1).strip(" ,.?!"))
    words = text.split()
    if len(words) > 2:
        out.append(" ".join(words[-2:]))
    seen, clean = set(), []
    for s in out:
        s = s.strip(" ,.?!’\"'")
        key = s.lower()
        if s and key not in seen and 1 < len(s) < 120:
            seen.add(key)
            clean.append(s)
    return clean[:limit]


def build_questions(clause: str, caps: list[dict], apps: dict[str, str]):
    """One request. Everything below is answered in parallel against one state.

    Most of these questions are irrelevant to any given clause. That is the
    point: asking speculatively costs a few tokens, a second round trip costs
    400ms, and 400ms is the entire budget.
    """
    candidates = spans(clause)
    qs = {
        "ready": Noul(
            instructions=(
                "`instruction` is one clause of a sentence someone is still speaking to their Mac. "
                "Does it already state both an action and the thing to act on, so it could be run "
                "right now? Answer false while it is still half-finished, for example 'open the', "
                "'make a new note', or 'search for'."
            )
        ),
        "capability": Choice(
            instructions="Which one of these should the Mac do for `instruction`?",
            criteria={c["id"]: c["description"] for c in caps},
        ),
        "app": Choice(
            instructions=(
                "If `instruction` names or implies an application installed on this Mac, which one "
                "is it? Match loosely: 'chrome' means Google Chrome, 'the browser' means whichever "
                "browser is listed. Pick 'none' if no application is meant."
            ),
            criteria={**{name: None for name in apps}, "none": "No application is named or implied."},
        ),
    }
    if candidates:
        qs["target"] = Choice(
            instructions=(
                "Each option is a phrase taken from `instruction`. Which one is the exact phrase the "
                "speaker dictated as content, such as a note title, a reminder, or something to "
                "search or copy? Prefer the shortest option that is still the whole phrase. Pick "
                "'none' if the speaker did not dictate any content."
            ),
            criteria={**{f"c{i}": s for i, s in enumerate(candidates)},
                      "none": "No content phrase was dictated."},
        )
    for c in caps:
        for arg, spec in c.get("args", {}).items():
            if spec.get("type") == "enum":
                qs[f"arg:{c['id']}:{arg}"] = Choice(
                    instructions=spec.get("question", f"Which {arg}?"),
                    criteria={k: (v.get("desc") if isinstance(v, dict) else None)
                              for k, v in spec["options"].items()},
                )
    return qs, candidates


def substitute(part: str, args: dict[str, str]) -> str:
    def repl(m):
        name, _, filt = m.group(1).partition("|")
        val = str(args.get(name, ""))
        if filt == "url":
            return urllib.parse.quote(val)
        return val
    part = part.replace("{desktop}", str(pathlib.Path.home() / "Desktop"))
    return re.sub(r"\{([a-z_]+(?:\|[a-z]+)?)\}", repl, part)


def build_command(cap: dict, args: dict[str, str]) -> list[str] | None:
    run = cap.get("run")
    for arg, table in cap.get("run_if", {}).items():        # per-value overrides
        if args.get(arg) in table:
            run = table[args[arg]]
            break
    if not run:
        return None
    return [substitute(p, args) for p in run]


def ask_claude(clause: str) -> list[str] | None:
    """The long tail. Jev routes in 400ms; this takes seconds, so it only ever
    runs on a clause the speaker has already finished, and never auto-executes."""
    prompt = (
        "Translate this spoken macOS instruction into ONE shell command that carries it out.\n"
        f'Instruction: "{clause}"\n'
        "Rules: output only the command on one line, no explanation, no markdown fences. "
        "Prefer osascript for controlling apps. Never use sudo, rm, or anything that deletes "
        "or reconfigures the system. If it cannot be done safely in one command, output exactly "
        "UNSUPPORTED."
    )
    try:
        out = subprocess.run(["claude", "-p", prompt], capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    cmd = out.stdout.strip().strip("`").strip()
    if not cmd or "UNSUPPORTED" in cmd or "\n" in cmd or FORBIDDEN.search(cmd):
        return None
    try:
        return shlex.split(cmd)
    except ValueError:
        return None


def execute(cmd: list[str]) -> str:
    joined = " ".join(cmd)
    if FORBIDDEN.search(joined):
        return f"refused: {joined}"
    subprocess.run(cmd, check=False, capture_output=True)
    return joined


class Agent:
    def __init__(self, client, threshold: float, dry: bool, verbose: bool, sink=None, trust: bool = False):
        self.client = client
        self.threshold = threshold
        self.dry = dry
        self.verbose = verbose
        self.trust = trust              # auto-run what Claude proposes
        self.sink = sink                # web UI subscribes here; CLI leaves it None
        self.caps = load_skills()
        self.apps = discover_apps()
        self.fired: list[str] = []
        self.proposals: dict[str, list[str]] = {}
        self._last_exec = None      # lets a refinable clause correct itself
        self._pending: list[threading.Thread] = []
        self._cache: dict[tuple, dict] = {}

    def emit(self, kind: str, **fields) -> None:
        if self.sink:
            self.sink({"kind": kind, **fields})

    def judge(self, clause: str, done: list[str]) -> dict:
        key = (clause, tuple(done))
        if key in self._cache:
            return {**self._cache[key], "ms": 0}
        qs, candidates = build_questions(clause, self.caps, self.apps)
        t0 = time.monotonic()
        r = self.client.system_one(
            state={
                "instruction": clause,
                "already_done": done or ["nothing yet"],
                "situation": "live dictation to a Mac, the speaker is still mid-sentence",
            },
            questions=qs,
        )
        ms = int((time.monotonic() - t0) * 1000)
        out = {
            "ready": r.nouls["ready"].noul,
            "capability": r.choices["capability"].choice,
            "confidence": r.choices["capability"].confidence,
            "answers": {k: v.choice for k, v in r.choices.items()},
            "candidates": candidates,
            "ms": ms,
            "tokens": r.usage.input_tokens,
        }
        self._cache[key] = out
        return out

    def resolve(self, cap: dict, j: dict, closed: bool = False) -> tuple[dict[str, str] | None, str]:
        """Returns the filled arguments, or None plus why it could not be filled."""
        args: dict[str, str] = {}
        for arg, spec in cap.get("args", {}).items():
            kind = spec.get("type")
            if kind == "span":
                pick = j["answers"].get("target", "none")
                if pick == "none":
                    return None, f"nothing was dictated to use as the {arg}"
                # A dictated phrase can always grow: "friday" becomes "friday recap".
                # Nothing in the words says which, so never take one until the
                # speaker has moved past the clause. This is the one place where
                # mid-sentence firing is simply not available, and pretending
                # otherwise just writes the wrong note title.
                if not closed:
                    return None, f"waiting for the {arg} to finish"
                args[arg] = j["candidates"][int(pick[1:])]
            elif kind == "app":
                pick = j["answers"].get("app", "none")
                if pick == "none" or pick not in self.apps:
                    return None, "no app by that name is installed on this Mac"
                args[arg] = self.apps[pick]
            elif kind == "enum":
                pick = j["answers"].get(f"arg:{cap['id']}:{arg}")
                if pick not in spec["options"]:
                    return None, f"could not settle on a {arg}"
                opt = spec["options"][pick]
                # A fallback option ("no browser named") is what you get when the
                # qualifier has not been spoken yet. Wait for the clause to close
                # before accepting it, or "open a new tab in chrome" fires as
                # "open a new tab" the moment it is grammatical.
                if isinstance(opt, dict) and opt.get("fallback") and not closed:
                    return None, f"waiting in case a {arg} is named"
                args[arg] = opt["value"] if isinstance(opt, dict) else opt
        return args, ""

    def consider(self, clause: str, done: list[str], closed: bool = False) -> bool:
        """True when a clause is settled, which moves the caller to the next one.

        `closed` means the speaker has moved past this clause, so a dictated
        phrase is finished by construction. Jev cannot know that from the words
        alone, so the bar drops and code supplies the certainty.
        """
        j = self.judge(clause, done)
        cap = next((c for c in self.caps if c["id"] == j["capability"]), None)
        # A refinable capability can correct itself, so a wrong first guess is
        # cheap but noisy. Make it clear a higher bar before the first attempt.
        bar = CLOSED_THRESHOLD if closed else self.threshold + (
            0.10 if cap and cap.get("refine") and self._last_exec is None else 0.0)
        target = j["candidates"][int(j["answers"]["target"][1:])] \
            if j["answers"].get("target", "none") != "none" else ""

        self.emit("judgment", clause=clause, closed=closed, ready=j["ready"],
                  action=j["capability"], app=j["answers"].get("app", "none"),
                  target=target, confidence=j["confidence"], ms=j["ms"], bar=bar,
                  tokens=j["tokens"])
        if self.verbose:
            mark = "|" if closed else " "
            print(f"  jev {j['ms']:>4}ms {mark} ready={j['ready']:.2f} "
                  f"{j['capability']}({j['confidence']:.2f}) app={j['answers'].get('app')} "
                  f"target={target!r}", file=sys.stderr)

        # `other` competes against every other capability at once, so its
        # confidence is structurally lower. The gate is per capability.
        min_conf = (cap or {}).get("min_confidence", 0.6)
        if j["ready"] < bar or j["capability"] == "none" or j["confidence"] < min_conf:
            return False

        if cap.get("escalate"):
            if not closed:
                return False            # Claude is slow: only on a finished clause
            self.propose(clause)
            done.append(f"asked Claude about: {clause}")
            return True

        args, why = self.resolve(cap, j, closed)
        if args is None:
            if not closed:
                return False            # an argument may still be coming, keep listening
            # the speaker has moved on and it still cannot be done: say so and
            # step past it, or one bad clause blocks the rest of the sentence
            self.emit("skipped", clause=clause, action=cap["id"], reason=why)
            print(f"  → skipped {cap['id']}: {why}", file=sys.stderr)
            done.append(f"could not do: {clause}")
            self._last_exec = None
            return True
        cmd = build_command(cap, args)
        if not cmd:
            return False
        label = f"{cap['id']}" + (f" · {' '.join(args.values())}" if args else "")

        # "turn the volume down" is already complete, so it fires. Then "to half"
        # arrives. A refinable capability stays open until the clause closes, and
        # the better answer supersedes the first one.
        sig = (cap["id"], tuple(sorted(args.items())))
        already = sig == self._last_exec
        if already and not closed:
            return False
        if not already:
            if not self.dry:
                execute(cmd)
            refines = self._last_exec is not None
            print(f"  → {'(dry) ' if self.dry else ''}{label}"
                  f"{'  (refines)' if refines else ''}    "
                  f"[{j['ms']}ms, ready {j['ready']:.2f}, conf {j['confidence']:.2f}]",
                  file=sys.stderr)
            self.emit("action", label=label, action=cap["id"], command=" ".join(cmd),
                      ready=j["ready"], confidence=j["confidence"], ms=j["ms"],
                      dry=self.dry, refines=refines)
            self.fired.append(label)
            self._last_exec = sig
        if cap.get("refine") and not closed:
            return False              # keep listening, the speaker may qualify it
        done.append(label)
        self._last_exec = None
        return True

    def propose(self, clause: str) -> None:
        """Jev said 'not one of mine'. Ask Claude, then wait for a human."""
        self.emit("thinking", clause=clause)

        def work():
            cmd = ask_claude(clause)
            if not cmd:
                self.emit("proposal_failed", clause=clause)
                print(f"  → no safe command for: {clause}", file=sys.stderr)
                return
            pid = f"p{int(time.time()*1000)}"
            self.proposals[pid] = cmd
            joined = " ".join(cmd)
            if self.trust and not self.dry:
                execute(cmd)
                self.emit("action", label=f"other · {clause}", action="other", command=joined,
                          ready=1.0, confidence=1.0, ms=0, dry=False)
                print(f"  → ran: {joined}", file=sys.stderr)
            else:
                self.emit("proposal", id=pid, clause=clause, command=joined)
                print(f"  → proposed ({'--trust to run' if self.dry else 'approve in the app'}): "
                      f"{joined}", file=sys.stderr)

        t = threading.Thread(target=work, daemon=True)
        self._pending.append(t)
        t.start()

    def wait(self, timeout: float = 90) -> None:
        """Escalations are slow by nature. Let them land before exiting."""
        for t in self._pending:
            t.join(timeout)

    def approve(self, pid: str) -> str | None:
        cmd = self.proposals.pop(pid, None)
        if not cmd:
            return None
        joined = execute(cmd)
        self.emit("action", label=f"other · approved", action="other", command=joined,
                  ready=1.0, confidence=1.0, ms=0, dry=False)
        return joined


class Utterance:
    """Tracks which clause of the current sentence is still owed an action."""

    def __init__(self, agent: Agent, min_chars: int = 8):
        self.agent = agent
        self.min_chars = min_chars
        self.reset()

    def reset(self) -> None:
        self.agent._last_exec = None
        self.idx = 0
        self.done: list[str] = []
        self.last_eval = ("", False)

    def feed(self, text: str, force_closed: bool = False) -> bool:
        parts = clauses(text)
        if self.idx >= len(parts):
            return False                      # speaker started a new clause, nothing said yet
        clause = parts[self.idx]
        closed = force_closed or self.idx < len(parts) - 1
        if len(clause) < self.min_chars or (clause, closed) == self.last_eval:
            return False
        self.last_eval = (clause, closed)
        self.agent.emit("clause", clause=clause, closed=closed)
        if self.agent.verbose:
            print(f"…{clause}", file=sys.stderr)
        if self.agent.consider(clause, self.done, closed):
            self.idx += 1
            self.last_eval = ("", False)
            return True
        return False

    def flush(self, text: str) -> None:
        """Sentence is over: every clause left is closed, so judge at the low bar."""
        while self.feed(text, force_closed=True):
            pass


def stream(utt: Utterance, debounce: float) -> None:
    state = {"text": "", "final": False, "seq": 0, "eof": False}
    lock = threading.Lock()

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                msg = {"text": line, "final": True}
            with lock:
                state["text"] = msg.get("text", "")
                state["final"] = state["final"] or bool(msg.get("final"))
                state["seq"] += 1
        with lock:
            state["eof"] = True

    threading.Thread(target=reader, daemon=True).start()
    last_seq, busy_until = 0, 0.0

    while True:
        with lock:
            seq, text, final, eof = state["seq"], state["text"], state["final"], state["eof"]
            state["final"] = False
        fresh = seq != last_seq

        if fresh and time.monotonic() >= busy_until:
            last_seq = seq
            if utt.feed(text.strip()):
                busy_until = time.monotonic() + debounce
            fresh = False

        if final:
            utt.flush(text.strip())
            utt.reset()
            print(file=sys.stderr)

        if eof and not fresh:
            utt.flush(text.strip())
            break

        time.sleep(0.05)


def load_env() -> None:
    """Read .env next to this file so --say works without run.sh."""
    f = HERE / ".env"
    if not f.exists():
        return
    for line in f.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip("\"'"))


def main() -> None:
    p = argparse.ArgumentParser(description="Voice-controlled Mac actions on Jev")
    p.add_argument("--say", help="judge this text word by word instead of listening")
    p.add_argument("--dry", action="store_true", help="decide but do not touch the Mac")
    p.add_argument("--trust", action="store_true", help="run what Claude proposes without asking")
    p.add_argument("--threshold", type=float, default=0.65, help="fire when P(instruction complete) clears this")
    p.add_argument("--min-chars", type=int, default=8, help="ignore clauses shorter than this")
    p.add_argument("--debounce", type=float, default=0.25, help="seconds to wait after firing")
    p.add_argument("--list", action="store_true", help="show the capability menu and exit")
    p.add_argument("-q", "--quiet", action="store_true", help="hide the per-call probabilities")
    args = p.parse_args()

    if args.list:
        apps = discover_apps()
        print(f"{len(load_skills())} capabilities, {len(apps)} apps\n")
        for c in load_skills():
            argstr = ", ".join(f"{k}:{v.get('type')}" for k, v in c.get("args", {}).items())
            print(f"  {c['id']:<20} {argstr}")
        return

    load_env()
    if not os.environ.get("TYPESAFE_API_KEY"):
        sys.exit("TYPESAFE_API_KEY is not set. Put it in .env next to this file.")

    with TypeSafeClient() as client:
        agent = Agent(client, args.threshold, args.dry, not args.quiet, trust=args.trust)
        utt = Utterance(agent, args.min_chars)
        if args.say:
            words = args.say.split()
            for i in range(1, len(words) + 1):
                utt.feed(" ".join(words[:i]))
            utt.flush(args.say)
            agent.wait()
            print(f"\nfired: {agent.fired}", file=sys.stderr)
            return
        stream(utt, args.debounce)


if __name__ == "__main__":
    main()
