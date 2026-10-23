# Sovereign TikTok Stack

Pure-Zig TikTok live chat reader. No Python, no external APIs, no browser required for chat.

## Components (all in ~/workspace = persistent)

| Component | Path | Purpose |
|-----------|------|---------|
| live-chat | `~/workspace/zig/live-chat/` | Zig binary: room lookup, cookies, websocket, protobuf chat parsing |
| sni_forward.py | `~/workspace/tiktoklive/` | TLS forwarder through egress proxy (required) |
| whisper.cpp | `~/workspace/whisper-cpp/` | Audio transcription (persistent build) |
| startup.sh | `~/workspace/tiktoklive/` | Restart script after VM reboot |
| TikTokLive venv | `~/workspace/venvs/tiktoklive/` | Python fallback (room_id backup) |

## Quick start

```bash
# After VM restart:
~/workspace/tiktoklive/startup.sh

# Read live chat:
~/workspace/zig/live-chat/zig-out/bin/live-chat naru.o_o
```

## How it works

1. **Room lookup**: HTTPS GET `tiktok.com/@user/live`, parse `roomId` from SIGI_STATE JSON
2. **Cookies**: HTTPS GET `tiktok.com/`, extract `ttwid`/`tt_csrf_token`/`tt_chain_token` from Set-Cookie
3. **Websocket**: Build URL from template (X-Bogus/X-Gnarly NOT validated by server), TLS via OpenSSL through sni_forward.py, send `im_enter_room` protobuf
4. **Chat**: Parse WebcastPushFrame → gunzip → WebcastResponse → WebcastChatMessage (field 3=content, field 2.user.field 3=nickname)

## Key discoveries

- TikTok's websocket does NOT validate X-Bogus/X-Gnarly signatures
- The `wrss` token value is NOT validated (dummy works)
- Only 3 HTTP cookies required (no JS/msToken needed)
- Python's websockets lib hid the real error (`417: named cookie not present` surfaced as opaque InvalidUpgrade)

## Chat history (2026-10-18)
- `history_comment_count` URL param controls how many recent messages the server replays on connect. Was `0` (no history); now `2000`.
- Server caps the actual history returned (~7-11 messages observed regardless of count) — the count is a request, not a guarantee.
- There is NO history API for messages older than the connect-time replay. TikTok's frontend "scroll up" shows its in-memory buffer, not server-fetched history.
- Keenan's hypothesis: fresh joins can scroll further back than the replay gives — mechanism still open. Possible the web frontend paginates via `im_cursor`.
