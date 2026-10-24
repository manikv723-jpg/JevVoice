#!/usr/bin/env python3
"""Local web UI for JevVoice.

Same engine as the CLI. The Swift listener runs as a subprocess so speech
recognition stays on-device; the browser only watches and controls.

    ./web.sh   →   http://localhost:4700
"""

import json
import os
import pathlib
import queue
import subprocess
import threading
import time

from flask import Flask, Response, jsonify, request, send_from_directory
from typesafe_sdk import TypeSafeClient

import agent as engine

HERE = pathlib.Path(__file__).parent
app = Flask(__name__, static_folder=None)

engine.load_env()   # before the client is built, not after

subscribers: list[queue.Queue] = []
sub_lock = threading.Lock()
state = {"listening": False, "dry": True, "threshold": 0.65, "trust": False, "proc": None}
if not os.environ.get("TYPESAFE_API_KEY"):
    raise SystemExit("TYPESAFE_API_KEY missing, put it in .env next to this file")
client = TypeSafeClient()


def publish(event: dict) -> None:
    event.setdefault("t", time.time())
    with sub_lock:
        for q in list(subscribers):
            q.put(event)


# One agent for the whole server, so a proposal made during listening is still
# there when you click Run a few seconds later.
AGENT = engine.Agent(client, threshold=state["threshold"], dry=state["dry"],
                     verbose=False, sink=publish)


def sync_agent() -> engine.Agent:
    AGENT.threshold = state["threshold"]
    AGENT.dry = state["dry"]
    AGENT.trust = state["trust"]
    return AGENT


@app.get("/")
def index():
    return send_from_directory(HERE, "index.html")


@app.get("/events")
def events():
    q: queue.Queue = queue.Queue()
    with sub_lock:
        subscribers.append(q)

    def gen():
        yield f"data: {json.dumps({'kind': 'hello', **public_state()})}\n\n"
        try:
            while True:
                try:
                    ev = q.get(timeout=15)
                    yield f"data: {json.dumps(ev)}\n\n"
                except queue.Empty:
                    yield ": ping\n\n"
        finally:
            with sub_lock:
                if q in subscribers:
                    subscribers.remove(q)

    return Response(gen(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def public_state() -> dict:
    return {"listening": state["listening"], "dry": state["dry"],
            "threshold": state["threshold"], "trust": state["trust"],
            "capabilities": [c["id"] for c in AGENT.caps], "apps": len(AGENT.apps)}


def listen_loop() -> None:
    """Drive the Swift listener through the same Utterance the CLI uses."""
    proc = subprocess.Popen(
        [str(HERE / "listen")], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1
    )
    state["proc"] = proc
    utt = engine.Utterance(sync_agent(), min_chars=8)
    busy_until = 0.0

    threading.Thread(
        target=lambda: [publish({"kind": "log", "line": l.strip()}) for l in proc.stderr],
        daemon=True,
    ).start()

    for line in proc.stdout:
        if not state["listening"]:
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        text = (msg.get("text") or "").strip()
        publish({"kind": "partial", "text": text, "final": bool(msg.get("final"))})
        if text and time.monotonic() >= busy_until:
            # settings can change mid-sentence
            sync_agent()
            try:
                if utt.feed(text):
                    busy_until = time.monotonic() + 0.25
            except Exception as exc:  # a bad key or a rate limit should not kill the loop
                publish({"kind": "error", "message": str(exc)})
        if msg.get("final"):
            try:
                utt.flush(text)
            except Exception as exc:
                publish({"kind": "error", "message": str(exc)})
            utt.reset()
            publish({"kind": "utterance_end"})

    proc.terminate()
    state["proc"] = None
    state["listening"] = False
    publish({"kind": "state", **public_state()})


@app.post("/listen")
def toggle_listen():
    want = bool(request.json.get("on"))
    if want and not state["listening"]:
        state["listening"] = True
        threading.Thread(target=listen_loop, daemon=True).start()
    elif not want and state["listening"]:
        state["listening"] = False
        if state["proc"]:
            state["proc"].terminate()
    publish({"kind": "state", **public_state()})
    return jsonify(public_state())


@app.post("/settings")
def settings():
    body = request.json or {}
    if "dry" in body:
        state["dry"] = bool(body["dry"])
    if "threshold" in body:
        state["threshold"] = max(0.1, min(0.99, float(body["threshold"])))
    if "trust" in body:
        state["trust"] = bool(body["trust"])
    sync_agent()
    publish({"kind": "state", **public_state()})
    return jsonify(public_state())


@app.post("/approve")
def approve():
    """Run a command Claude proposed. Nothing here runs without this click."""
    pid = (request.json or {}).get("id", "")
    ran = AGENT.approve(pid)
    if ran is None:
        return jsonify({"error": "unknown or already used"}), 404
    return jsonify({"ran": ran})


@app.post("/dismiss")
def dismiss():
    AGENT.proposals.pop((request.json or {}).get("id", ""), None)
    return jsonify({"ok": True})


@app.post("/say")
def say():
    """Type a sentence instead of speaking it. Replays word by word, like the mic."""
    text = (request.json or {}).get("text", "").strip()
    if not text:
        return jsonify({"error": "empty"}), 400

    def run():
        utt = engine.Utterance(sync_agent(), min_chars=8)
        words = text.split()
        for i in range(1, len(words) + 1):
            partial = " ".join(words[:i])
            publish({"kind": "partial", "text": partial, "final": False})
            try:
                utt.feed(partial)
            except Exception as exc:
                publish({"kind": "error", "message": str(exc)})
                return
            time.sleep(0.05)
        publish({"kind": "partial", "text": text, "final": True})
        try:
            utt.flush(text)
        except Exception as exc:
            publish({"kind": "error", "message": str(exc)})
        publish({"kind": "utterance_end"})

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"ok": True})


if __name__ == "__main__":
    print("JevVoice on http://localhost:4700")
    app.run(host="127.0.0.1", port=4700, threaded=True, debug=False)
