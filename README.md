# Sovereign Agent Stack — live/web toolkit

A toolkit for agents that need to see and hear the live web **without a
human in the loop**: no accounts to create, no API keys to beg, no browser
session tied to a person. TikTok is the first full implementation — live
discovery, live chat reading, video download + comments, live transcription —
built on platform-agnostic pieces (request signing, CDP tooling, a TLS
forwarder) that transfer to other targets.

Everything here was built and verified working end-to-end on a live system:
the Zig client streams real chat from real rooms, the video script downloads
real MP4s with real comments, and the transcription pipeline turns live
audio into text.

## Component map

```
zig/
  live-chat/    Pure-Zig TikTok LIVE chat reader (the flagship).
                main.zig — room lookup (roomId from the /@user/live page HTML),
                  cookie fetch (ttwid / tt_csrf_token / tt_chain_token), TLS via
                  OpenSSL through the SNI forwarder, websocket handshake,
                  im_enter_room protobuf, gzip + protobuf chat parsing.
                  Also carries a --fuzz-ws probe mode on a reusable
                  connectRoom() handshake.
                xgorgon.zig — X-Gorgon request signing, ported to pure Zig.
                build.zig
  cdp-shot/     Hand-rolled Zig CDP client: websocket handshake to a headless
                browser (Lightpanda), navigate, screenshot. No dependencies.
  replay/       Canvas-call replay engine: records a page's canvas 2D calls
                as JSON and replays them into real pixels with z2d — pixels
                from a browser engine that cannot rasterize.
                NOTE: the vendored z2d library (~11 MB) is NOT included in
                this repo; fetch z2d v0.9.0 separately and drop it in as
                replay/z2d/ before building.
tools/
  sni_forward.py    SNI-sniffing TLS forwarder: tunnels TLS through an HTTP
                    egress proxy by peeking at the SNI name. Required by the
                    Zig client in proxied environments.
  fuzzer.py         HTTP endpoint fuzzer (history-endpoint hunt; pattern space
                    exhausted — kept as a reusable signed-request fuzzer).
  ws_fuzzer.py      Drives the Zig client's --fuzz-ws mode over candidate
                    websocket payload types.
  feed_probe3.py    Working probe for the live FEED endpoint (see docs/FEED.md).
  feed_fetch.py     Fetches and inspects a full feed response.
  capture_feed2.py  CDP capture of the real web client's feed XHR (full URL +
                    response body) — how the feed request was reverse-engineered.
  signatures/       Clean-room X-Gorgon signer in Python (xgorgon_clean.py),
                    the reference implementation the Zig port was verified
                    against.
scripts/
  tiktok-video.sh     Download a TikTok video (MP4) via the tikwm API and
                      optionally print its comments. Resolves share links.
  live-transcribe.sh  Record N seconds of a live (yt-dlp FLV + ffmpeg) and
                      transcribe the audio with whisper.cpp.
docs/
  FEED.md       The live-feed endpoint: full solved request recipe, and the
                one remaining wall (clean-IP egress, below).
  README.md     Original stack notes: how the chat reader works, wire formats.
startup.sh      Restores the runtime stack after a reboot (SNI forwarder,
                Lightpanda, sanity checks).
```

## External dependencies (install separately — none are vendored)

- **Zig 0.15.1** — builds everything under `zig/`.
- **Lightpanda** — headless browser (Zig, CDP-compatible) used for discovery
  and request capture. `pip install lightpanda`.
- **yt-dlp** and **ffmpeg** — live stream resolution and recording
  (`scripts/live-transcribe.sh`).
- **whisper.cpp** — transcription. Build it, place a model (e.g.
  `ggml-tiny.bin`) in its `models/`, and point `$WHISPER_DIR` at it if it
  doesn't live at `~/workspace/whisper-cpp`.
- **python3 + curl** — used by the tools and glue scripts.
- This environment reaches the internet through an egress proxy
  (`$https_proxy`); the SNI forwarder exists because of that. On an
  unrestricted network the Zig client can skip it.

## Open research threads

1. **From commands to reusable functions.** The chat reader is already a
   real program — its handshake was refactored into a reusable
   `connectRoom()` shared by the reader and the fuzzer. The rest of the
   stack is still connective tissue: shell scripts and one-off command
   flows (the tikwm download, the record→transcribe chain) that an agent
   has to drive step by step. The work ahead is promoting those flows
   into callable functions with the same shape as `connectRoom()` — less
   exhausting for agents, fewer moving parts to babysit.

2. **Clean-IP egress for the feed.** The live-feed API request is fully
   solved (see `docs/FEED.md`): right host, right params, guest device id,
   accepted signature, `status_code 0` — but the response envelope comes
   back with **zero rooms** from a datacenter IP. Three independent
   clients (real Chromium, the genuine page JS, the raw signed API) all
   hit the same wall, so the gate is IP reputation, not request shape.
   Named-creator polling (page-HTML roomId + websocket connect) is fully
   sovereign today; open feed discovery turns on as-is the moment this
   stack runs behind a clean (residential/mobile) egress.
