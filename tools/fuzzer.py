#!/usr/bin/env python3
"""TikTok history endpoint fuzzer. Tries URL patterns, logs hits."""
import sys, urllib.request, json, os
sys.path.insert(0, '/home/hatch/workspace/tiktoklive/signatures')
from xgorgon_clean import getxg

def find_live_room():
    """Get room from Keenan's links. He sends live links, we use them.
    No verification - im/fetch is useless for checking liveness.
    If the room is dead, the fuzz just gets nothing."""
    import os
    keenan_file = "/home/hatch/workspace/tiktoklive/keenan_rooms.txt"
    if os.path.exists(keenan_file):
        for l in open(keenan_file):
            l = l.strip()
            if l.isdigit():
                return l, "keenan-link"
    return None, None

LOG = "/home/hatch/workspace/tiktoklive/fuzzer.log"
_liveroom = find_live_room()
if not _liveroom[0]:
    print("No live rooms found - skipping fuzz (lives have ended)")
    with open(LOG, "a") as f:
        f.write("--- skipped: no live rooms ---\n")
    sys.exit(0)
ROOM, ROOM_USER = _liveroom
print(f"Fuzzing against live room {ROOM} ({ROOM_USER})")

# Generate patterns from components
hosts = [
    "webcast.tiktok.com",
    "api16-normal-c-useast1a.tiktokv.com",
    "api19-normal-c-useast1a.tiktokv.com",
]
prefixes = ["", "/webcast", "/aweme/v1/webcast", "/aweme/v2/webcast", "/aweme/v1"]
paths = [
    "room/history", "room/comment/history", "room/history_comment",
    "room/historycomment", "im/fetch_history", "im/history",
    "comment/history", "live/history", "live/room/history",
    "room/chat/history", "chat/history", "msg/history",
]

def test(host, full_path):
    params = f"aid=1233&room_id={ROOM}&cursor=&count=20"
    try:
        sig = getxg(params, "", "")
    except:
        return None
    url = f"https://{host}{full_path}?{params}"
    req = urllib.request.Request(url, headers={
        "X-Gorgon": sig["X-Gorgon"], "X-Khronos": sig["X-Khronos"],
        "User-Agent": "Mozilla/5.0"
    })
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.read()[:300].decode('utf8', 'ignore')
    except Exception as e:
        return f"ERR:{str(e)[:40]}"

tested = set()
if os.path.exists(LOG + ".seen"):
    tested = set(open(LOG + ".seen").read().splitlines())

hits = []
for host in hosts:
    for pre in prefixes:
        for p in paths:
            fp = f"{pre}/{p}/"
            key = f"{host}{fp}"
            if key in tested:
                continue
            tested.add(key)
            body = test(host, fp)
            # Rejections: webcast host says "Url does not match",
            # mobile api16/api19 hosts say "url doesn't match" (still status_code 0)
            low = body.lower() if body else ""
            if body and "does not match" not in low and "doesn't match" not in low and not body.startswith("ERR"):
                hits.append((key, body[:120]))
                with open(LOG, "a") as f:
                    f.write(f"HIT {key}: {body[:120]}\n")

with open(LOG + ".seen", "w") as f:
    f.write("\n".join(tested))
with open(LOG, "a") as f:
    f.write(f"--- sweep done, {len(tested)} total, {len(hits)} hits ---\n")
print(f"done: {len(tested)} tested, {len(hits)} hits")
for k, b in hits:
    print(f"HIT: {k}")
