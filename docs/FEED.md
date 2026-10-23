# TikTok live FEED endpoint — recipe solved, data IP-gated (2026-10-23)

## The endpoint
`GET https://webcast.us.tiktok.com/webcast/feed/` (webcast.tiktok.com also works)

## Working request recipe (verified status_code 0)
- Full web-client param template captured from the real page's XHR via Lightpanda CDP
  (see capture_feed2.py) — BUT with **aid=1233** instead of 1988.
- Required: channel_id (86 = suggested hosts w/ content_type=0, max_time=0,
  req_from=pc_web_suggested_host; 87 = rec tab w/ req_from=live_mt_pc_web_rec_tab_refresh).
  No channel_id -> 10011 "Request params error".
- device_id = self-generated 19-digit guest webid (page mints its own via
  mcs.tiktokw.us/v1/user/webid; a random one is accepted).
- Signed with plain X-Gorgon (xgorgon_clean.py / xgorgon.zig). No X-Gnarly/X-Dynosaur needed
  on the aid=1233 path. Minimal params -> 10011; aid=1988 -> empty body.

## The wall
Response is `{"status_code":0,"extra":{...}}` with NO data field — zero rooms —
under every channel/param variant from this VM's datacenter egress IP.
Same wall three ways: real Chromium 156 (Oct 18), the genuine page JS in Lightpanda
(its own signed feed requests returned 0-byte bodies), and this raw signed API.
TikTok withholds feed data by IP reputation; request engineering cannot fix it.
The moment this stack runs behind a clean IP, this recipe turns discovery on as-is.

## Probes
feed_probe.py / feed_probe2.py / feed_probe3.py / feed_fetch.py / capture_feed_xhr.py / capture_feed2.py
