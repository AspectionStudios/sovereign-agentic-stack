#!/usr/bin/env python3
"""Websocket method fuzzer: probes candidate history-fetch method names
against a live TikTok room using the Zig client's --fuzz-ws mode.

Needs: SNI forwarder alive (~/workspace/tiktoklive/startup.sh restores it),
and a LIVE room id (pass as argv[1], or first id in keenan_rooms.txt).

Usage: python3 ws_fuzzer.py [room_id]
"""
import subprocess, sys, os, time, re

# Frame methods that arrive from the enter-room handshake for EVERY
# candidate. Novel methods (anything else) are the only real signal.
BASELINE_METHODS = {"im_enter_room_resp", "msg"}

def frame_methods(out):
    return re.findall(r"method='([^']+)'", out or "")

ZIG_BIN = "/home/hatch/workspace/zig/live-chat/zig-out/bin/live-chat"
LOG = "/home/hatch/workspace/tiktoklive/ws_fuzzer.log"
SEEN = LOG + ".seen"
ROOMS_FILE = "/home/hatch/workspace/tiktoklive/keenan_rooms.txt"

# Candidate method names for the history mechanism (field 7 of WebcastPushFrame).
# HIT rule: only a frame method OUTSIDE the baseline connect set
# (im_enter_room_resp, msg) counts. Baseline frames arrive for every
# candidate from the enter-room handshake and prove nothing -- counting
# any non-empty payload as a HIT was a false-positive generator (Oct 19).
candidates = [
    "webcast_im_fetch_history",
    "im_fetch_history",
    "im_history",
    "im_get_history",
    "im_fetch",
    "history_fetch",
    "fetch_history",
    "im_history_fetch",
    "webcast_history_comment",
    "webcast_fetch_history_comment",
]

def log(msg):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")

def main():
    room = sys.argv[1] if len(sys.argv) > 1 else None
    if not room:
        with open(ROOMS_FILE) as f:
            ids = [l.strip() for l in f if l.strip().isdigit()]
        if not ids:
            log("no room ids in keenan_rooms.txt; pass a live room id as argv[1]")
            return
        room = ids[0]
    tested = set()
    if os.path.exists(SEEN):
        tested = set(open(SEEN).read().splitlines())
    fresh = [c for c in candidates if c not in tested]
    if not fresh:
        log("all candidates already tested")
        return
    log(f"room={room} testing {len(fresh)} candidates")
    for method in fresh:
        log(f"--- probe {method} ---")
        try:
            p = subprocess.run([ZIG_BIN, "--fuzz-ws", room, method],
                               capture_output=True, text=True, timeout=90)
            out = (p.stdout or "") + (p.stderr or "")
            for line in out.splitlines():
                s = line.strip()
                if any(k in s for k in ("HIT", "frame ", "fuzz-ws", "FAIL", "error", "TLS ok", "connected")):
                    log("  " + s[:200])
            novel = [m for m in set(frame_methods(out)) if m not in BASELINE_METHODS]
            ml = method.lower()
            if any(ml in m.lower() or "history" in m.lower() for m in novel):
                log(f"*** CANDIDATE HIT: {method} (room {room}) novel methods={novel} ***")
            elif novel:
                log(f"  novel non-history methods for {method}: {novel}")
        except subprocess.TimeoutExpired:
            log(f"  timeout on {method}")
        except Exception as e:
            log(f"  error on {method}: {e}")
        tested.add(method)
        with open(SEEN, "w") as f:
            f.write("\n".join(sorted(tested)))
    log("sweep done")

if __name__ == "__main__":
    main()
