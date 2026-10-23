#!/usr/bin/env python3
"""TikTok live feed — one reusable function with the transport injected.

    from feed import feed
    result = feed()                                  # default env-proxy session
    result = feed(channel_id=87)                     # rec tab
    result = feed(transport=my_session)              # any requests.Session

`result` is the parsed response envelope (a dict). Every call also attaches
`result["_meta"] = {"http_status": int, "raw_bytes": int, "rooms": int}` —
transport facts of that specific call, so callers (and tests) can compare
behavior across egresses without re-implementing the room counting.

The whole recipe lives in this module (docs/FEED.md): the web-client param
template with aid=1233, the channel_id variants, a self-generated guest
device_id, and plain X-Gorgon signing via getxg() (vendored signer in
xgorgon.py next to this file; falls back to the stack original in
~/workspace/tiktoklive/signatures/ if the vendored copy is missing).
The transport is the ONLY thing a caller controls: whatever egress the
passed session rides (env proxy, SOCKS/Tor, chained proxy) is what the
request goes out on. feed(channel_id=86, transport=None) is the baseline.
"""
import os
import random
import sys

import requests

# --- signer: vendored copy first, stack original as fallback ----------------
try:
    from xgorgon import getxg
except ImportError:  # pragma: no cover - only when vendored copy is absent
    sys.path.insert(0, os.path.expanduser("~/workspace/tiktoklive/signatures"))
    from xgorgon_clean import getxg

HOST = "webcast.us.tiktok.com"
USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# Per-channel differences inside the template (FEED.md). Everything else in
# the template is shared. Unknown channels fall back to the 86 variant.
_CHANNEL_EXTRAS = {
    86: {"content_type": "0", "max_time": "0",
         "req_from": "pc_web_suggested_host"},
    87: {"req_from": "live_mt_pc_web_rec_tab_refresh"},
}

# Ordered param template (order matters: the signature is an md5 of this
# exact query string). {device_id} and {channel_id} are filled per call.
_PARAM_ORDER = [
    "aid", "app_language", "app_name", "browser_language", "browser_name",
    "browser_online", "browser_platform", "browser_version", "channel",
    "channel_id", "content_type", "cookie_enabled", "cpu_number",
    "data_collection_enabled", "device_id", "device_platform", "device_type",
    "focus_state", "history_len", "is_fullscreen", "is_non_personalized",
    "is_page_visible", "max_time", "os", "region", "req_from",
    "screen_height", "screen_width", "tz_name", "user_is_login",
    "webcast_language",
]
_PARAM_DEFAULTS = {
    "aid": "1233",
    "app_language": "en",
    "app_name": "tiktok_web",
    "browser_language": "en-US",
    "browser_name": "Mozilla",
    "browser_online": "true",
    "browser_platform": "Win32",
    "browser_version": "1.0",
    "channel": "tiktok_web",
    "cookie_enabled": "true",
    "cpu_number": "4",
    "data_collection_enabled": "false",
    "device_platform": "web_pc",
    "device_type": "web_h264",
    "focus_state": "true",
    "history_len": "1",
    "is_fullscreen": "false",
    "is_non_personalized": "0",
    "is_page_visible": "true",
    "os": "unknown",
    "region": "US",
    "screen_height": "1080",
    "screen_width": "1920",
    "tz_name": "America%2FPhoenix",
    "user_is_login": "false",
    "webcast_language": "en",
}


def _guest_device_id():
    """Self-generated 19-digit guest webid (same range the probes used)."""
    return str(random.randint(7500000000000000000, 7699999999999999999))


def _build_params(channel_id, device_id):
    values = dict(_PARAM_DEFAULTS)
    values["channel_id"] = str(channel_id)
    values["device_id"] = device_id or _guest_device_id()
    values.update(_CHANNEL_EXTRAS.get(int(channel_id), _CHANNEL_EXTRAS[86]))
    return "&".join(f"{k}={values[k]}" for k in _PARAM_ORDER if k in values)


def _count_rooms(parsed):
    data = parsed.get("data") if isinstance(parsed, dict) else None
    if isinstance(data, dict):
        return sum(len(v) for v in data.values() if isinstance(v, list))
    if isinstance(data, list):
        return len(data)
    return 0


def feed(channel_id=86, transport=None, device_id=None, timeout=45):
    """Fetch the TikTok live feed once and return the parsed envelope dict.

    channel_id: 86 = suggested hosts, 87 = rec tab.
    transport:  a requests.Session to send through, or None for a default
                session (which honors the env proxy vars, like the probes).
    device_id:  guest webid to present; None mints a fresh random one.
    """
    session = transport if transport is not None else requests.Session()
    params = _build_params(channel_id, device_id)
    sig = getxg(params, "", "")
    resp = session.get(
        f"https://{HOST}/webcast/feed/?{params}",
        headers={"X-Gorgon": sig["X-Gorgon"], "X-Khronos": sig["X-Khronos"],
                 "User-Agent": USER_AGENT},
        timeout=timeout,
    )
    result = resp.json()
    if isinstance(result, dict):
        result["_meta"] = {"http_status": resp.status_code,
                           "raw_bytes": len(resp.content),
                           "rooms": _count_rooms(result)}
    return result


if __name__ == "__main__":
    out = feed()
    meta = out.get("_meta", {})
    print(f"HTTP {meta.get('http_status')}  bytes {meta.get('raw_bytes')}  "
          f"status_code {out.get('status_code')}  rooms {meta.get('rooms')}")
