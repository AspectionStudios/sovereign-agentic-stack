#!/usr/bin/env python3
"""Round 3: untested combos for webcast feed."""
import sys, urllib.request, random
sys.path.insert(0, '/home/hatch/workspace/tiktoklive/signatures')
from xgorgon_clean import getxg

WEBID = str(random.randint(7500000000000000000, 7699999999999999999))
WEB_STYLE = ("aid=1988&app_language=en&app_name=tiktok_web&browser_language=en-US"
             "&browser_name=Mozilla&browser_online=true&browser_platform=Win32"
             "&browser_version=1.0&channel=tiktok_web&channel_id=86&content_type=0"
             "&cookie_enabled=true&cpu_number=4&data_collection_enabled=false"
             f"&device_id={WEBID}&device_platform=web_pc&device_type=web_h264"
             "&focus_state=true&history_len=1&is_fullscreen=false&is_non_personalized=0"
             "&is_page_visible=true&max_time=0&os=unknown&region=US"
             "&req_from=pc_web_suggested_host&screen_height=1080&screen_width=1920"
             "&tz_name=America%2FPhoenix&user_is_login=false&webcast_language=en")
APP_ON_WEB = WEB_STYLE.replace("aid=1988", "aid=1233")

CASES = [
    ("webcast.us + aid1233 + web-style params", "webcast.us.tiktok.com", APP_ON_WEB),
    ("webcast.us + aid1233 minimal", "webcast.us.tiktok.com", "aid=1233&count=30"),
    ("webcast + aid1233 + web-style params", "webcast.tiktok.com", APP_ON_WEB),
    ("webcast.us + aid1988 web-style (control)", "webcast.us.tiktok.com", WEB_STYLE),
]
for name, host, params in CASES:
    sig = getxg(params, "", "")
    url = f"https://{host}/webcast/feed/?{params}"
    req = urllib.request.Request(url, headers={
        "X-Gorgon": sig["X-Gorgon"], "X-Khronos": sig["X-Khronos"],
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read()[:400].decode('utf8', 'ignore')
            print(f"[{name}] HTTP {r.status} -> {body[:300]!r}\n")
    except Exception as e:
        try:
            body = e.read()[:300].decode('utf8', 'ignore')
        except Exception:
            body = str(e)[:80]
        print(f"[{name}] ERR -> {body[:300]!r}\n")
