# TikTok API Signatures (2026-10-18)

## X-Gorgon / X-Khronos — WORKING
- `xgorgon_clean.py` — extracted from tikvues/tiktok-signatures, termcolor removed
- Generates valid X-Gorgon (52-char hex) + X-Khronos (unix timestamp)
- **Verified**: `webcast.tiktok.com/webcast/im/fetch/` accepts these signatures (status 0)
- Usage: `from xgorgon_clean import getxg; sig = getxg(params, stub, cookie)`
- No X-Argus needed for webcast host

## X-Argus — NOT WORKING
- Public implementation has placeholder AES key (`bytes(range(32))`)
- Marked "not final and maybe short and non-working" by author
- May not be needed if X-Gorgon suffices for target endpoints

## Endpoints tested
- `webcast.tiktok.com/webcast/im/fetch/` — accepts X-Gorgon, returns status 0 (empty data when no active live)
- `webcast.tiktok.com/webcast/room/info/` — exists (from TikTokLive source)
- History-specific paths tried: `im/fetch_history/`, `im/history_fetch/`, `im/history/` — all 404
- TokInsight workflow: `webcast_room_msg_fetch` -> `history_comment_cursor` -> `webcast_room_history_msg_fetch`

## Zig integration (2026-10-18)
- Ported to `~/workspace/zig/live-chat/xgorgon.zig` — pure Zig, no dependencies
- Integrated into `main.zig` as `httpsGetSigned()` — adds X-Gorgon + X-Khronos headers
- `--history <room_id>` mode added to live-chat binary for signed API testing
- **Verified**: TikTok's `webcast.tiktok.com/webcast/im/fetch/` accepts Zig-generated signatures (status 0)
