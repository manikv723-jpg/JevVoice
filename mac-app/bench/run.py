"""Runs both engines on bench/actions.json through the real app binary and scores them.

  set -a; . ../.env; set +a; python3 bench/run.py
"""
import json, pathlib, re, subprocess, sys, collections

HERE = pathlib.Path(__file__).parent
cases = json.loads((HERE / (sys.argv[1] if len(sys.argv) > 1 else "actions.json")).read_text())["cases"]
out = subprocess.run([str(HERE.parent / "build/SayOpen.app/Contents/MacOS/SayOpen"), "--selftest",
                      *[c["said"] for c in cases]], capture_output=True, text=True, timeout=900).stdout
rows = [json.loads(l) for l in out.splitlines() if l.startswith("{")]
assert len(rows) == len(cases), (len(rows), len(cases))

norm = lambda s: re.sub(r"[^a-z0-9 ]", "", str(s).lower()).strip()
def ok(want, got):
    acts = want["action"] if isinstance(want["action"], list) else [want["action"]]
    if got.get("action") not in acts:
        return False
    for k in ("app", "setting", "text"):
        if k in want:
            allowed = want[k] if isinstance(want[k], list) else [want[k]]
            if norm(got.get(k, "")) not in [norm(a) for a in allowed]:
                return False
    return True

score = collections.defaultdict(lambda: {"jev": 0, "rules": 0, "n": 0})
ms = {"jev": [], "rules": []}
detail = []
for c, r in zip(cases, rows):
    s = score[c["kind"]]
    s["n"] += 1
    res = {}
    for e in ("jev", "rules"):
        good = ok(c["want"], r[e])
        s[e] += good
        res[e] = good
        if isinstance(r[e].get("ms"), (int, float)):
            ms[e].append(r[e]["ms"])
    detail.append({"kind": c["kind"], "said": c["said"], "want": c["want"], "jev": r["jev"], "rules": r["rules"],
                   "jev_ok": res["jev"], "rules_ok": res["rules"]})
    mark = lambda b: "ok " if b else "XX "
    print(f"{c['kind']:<10} {c['said'][:40]:<40} J {mark(res['jev'])}{r['jev'].get('label', r['jev']['action'])[:30]:<30} "
          f"R {mark(res['rules'])}{r['rules'].get('label', r['rules']['action'])[:30]}")

print(f"\n{'':<11}{'Jev':>10}{'Rules':>10}")
tot = {"jev": 0, "rules": 0, "n": 0}
for k, s in score.items():
    print(f"{k:<11}{s['jev']:>5}/{s['n']:<4}{s['rules']:>5}/{s['n']:<4}")
    for e in tot: tot[e] += s[e]
print(f"{'ALL':<11}{tot['jev']:>5}/{tot['n']:<4}{tot['rules']:>5}/{tot['n']:<4}")
med = lambda xs: sorted(xs)[len(xs) // 2] if xs else 0
print(f"median decide time: Jev {med(ms['jev'])}ms, Rules {med(ms['rules']):.2f}ms")
(HERE / ("results-" + pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "actions.json").stem + ".json")).write_text(json.dumps({"summary": {k: dict(v) for k, v in score.items()}, "total": tot,
    "median_ms": {"jev": med(ms["jev"]), "rules": med(ms["rules"])}, "cases": detail}, indent=1))
