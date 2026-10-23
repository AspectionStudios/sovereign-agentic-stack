#!/usr/bin/env python3
"""Capture the FULL webcast/feed request URL + its response body via CDP."""
import json, time
import websocket

ws = websocket.create_connection("ws://127.0.0.1:9222/", suppress_origin=True, timeout=30)
_id = 0
def send(method, params=None, session=None):
    global _id
    _id += 1
    msg = {"id": _id, "method": method, "params": params or {}}
    if session:
        msg["sessionId"] = session
    ws.send(json.dumps(msg))
    return _id

def recv_until(want_id, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        ws.settimeout(max(1, end - time.time()))
        try:
            m = json.loads(ws.recv())
        except Exception:
            break
        if m.get("id") == want_id:
            return m
    return None

i = send("Target.createTarget", {"url": "about:blank"})
tid = recv_until(i)["result"]["targetId"]
i = send("Target.attachToTarget", {"targetId": tid, "flatten": True})
sess = recv_until(i)["result"]["sessionId"]

send("Network.enable", {}, sess)
send("Page.enable", {}, sess)
i = send("Page.navigate", {"url": "https://www.tiktok.com/live?lang=en"}, sess)
recv_until(i)

feed_reqs = {}   # requestId -> url
pending_body = []
end = time.time() + 20
while time.time() < end:
    ws.settimeout(max(1, end - time.time()))
    try:
        m = json.loads(ws.recv())
    except Exception:
        break
    meth = m.get("method", "")
    if meth == "Network.requestWillBeSent":
        u = m["params"]["request"]["url"]
        if "webcast.us.tiktok.com/webcast/feed/?" in u:
            feed_reqs[m["params"]["requestId"]] = u
    elif meth == "Network.loadingFinished":
        rid = m["params"]["requestId"]
        if rid in feed_reqs and len(pending_body) < 3:
            pending_body.append(rid)

for n, (rid, u) in enumerate(feed_reqs.items()):
    print(f"=== FEED URL {n} ===")
    print(u)
    print()

# fetch bodies for the first few
for rid in pending_body[:2]:
    i = send("Network.getResponseBody", {"requestId": rid}, sess)
    r = recv_until(i, timeout=10)
    if r and "result" in r:
        body = r["result"].get("body", "")
        print(f"=== BODY for {rid} ({len(body)} chars) ===")
        print(body[:1500])
        print()
