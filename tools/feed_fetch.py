#!/usr/bin/env python3
"""Fetch the FULL webcast feed response (aid=1233 + web-style params) and inspect for rooms."""
import sys, urllib.request, random, json
sys.path.insert(0, '/home/hatch/workspace/tiktoklive/signatures')
from xgorgon_clean import getxg

WEBID = str(random.randint(7500000000000000000, 7699999999999999999))
PARAMS = ("aid=1233&app_language=en&app_name=tiktok_web&browser_language=en-US"
          "&browser_name=Mozilla&browser_online=true&browser_platform=Win32"
          "&browser_version=1.0&channel=tiktok_web&channel_id=86&content_type=0"
          "&cookie_enabled=true&cpu_number=4&data_collection_enabled=false"
          f"&device_id={WEBID}&device_platform=web_pc&device_type=web_h264"
          "&focus_state=true&history_len=1&is_fullscreen=false&is_non_personalized=0"
          "&is_page_visible=true&max_time=0&os=unknown&region=US"
          "&req_from=pc_web_suggested_host&screen_height=1080&screen_width=1920"
          "&tz_name=America%2FPhoenix&user_is_login=false&webcast_language=en")

sig = getxg(PARAMS, "", "")
url = f"https://webcast.us.tiktok.com/webcast/feed/?{PARAMS}"
req = urllib.request.Request(url, headers={
    "X-Gorgon": sig["X-Gorgon"], "X-Khronos": sig["X-Khronos"],
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"})
with urllib.request.urlopen(req, timeout=15) as r:
    raw = r.read().decode('utf8', 'ignore')
print("total bytes:", len(raw))
with open('/tmp/feed_full.json', 'w') as f:
    f.write(raw)
d = json.loads(raw)
print("top-level keys:", list(d.keys()))
data = d.get("data")
print("data type:", type(data).__name__)
if isinstance(data, dict):
    print("data keys:", list(data.keys()))
    for k, v in data.items():
        if isinstance(v, list):
            print(f"  {k}: list of {len(v)}")
            if v:
                print("  first item keys:", list(v[0].keys())[:20] if isinstance(v[0], dict) else v[0])
elif isinstance(data, list):
    print("data list len:", len(data))
    if data:
        print("first item:", json.dumps(data[0])[:800])
