# feed.py — test log (2026-10-23)

**Verdict: ALL THREE TESTS PASS.** The extracted module reproduces the known
feed behavior exactly through every transport — which is the pass bar, since
the feed returns zero rooms from every egress this stack has (behavior
parity = success). Nothing was pushed to GitHub; `~/workspace/stack-repo`
and `~/workspace/tiktoklive` were not modified.

## What was built

`~/workspace/stack-experiments/feed-module/`

- **feed.py** — the single reusable module. `feed(channel_id=86, transport=None,
  device_id=None, timeout=45) -> dict` returns the parsed response envelope
  with a `_meta` key attached (`http_status`, `raw_bytes`, `rooms`) so callers
  can compare behavior across egresses. All recipe knowledge lives inside:
  the ordered web-client param template with aid=1233, per-channel variants
  (86: content_type=0/max_time=0/req_from=pc_web_suggested_host; 87:
  req_from=live_mt_pc_web_rec_tab_refresh), a self-generated guest device_id,
  and X-Gorgon/X-Khronos headers. `transport` is a requests.Session (or None
  for a default env-proxy session) — the only thing a caller controls.
  Running `python3 feed.py` is the CLI demo.
- **xgorgon.py** — the signer, vendored byte-for-byte (plus a 2-line
  provenance header) from `~/workspace/tiktoklive/signatures/xgorgon_clean.py`.
  feed.py imports `getxg` from it, falling back to the stack original if the
  vendored copy is ever missing. The signer was NOT rewritten.
- **test_tor.py** — Test 2 harness (builds the Tor session, calls feed()).
- **torrc** — the Tor config used for Test 2 (previous batch's torrc was gone;
  rebuilt to the RESULTS.md A2 pattern).

Baseline for comparison (RESULTS.md): HTTP 200, status_code 0, data null,
258-byte envelope, top-level keys `status_code` + `extra` only, zero rooms.

## Test 1 — default transport (env proxy), CLI demo

Command: `cd ~/workspace/stack-experiments/feed-module && python3 feed.py`

```
HTTP 200  bytes 258  status_code 0  rooms 0
exit=0
egress IP: 104.29.197.139
```

(Egress IP is in the same Cloudflare datacenter range as the recorded
baseline 104.29.193.195; exit IPs rotate within the range.)

Full envelope dump:

```
keys: ['extra', 'status_code']
status_code: 0
data: None
_meta: {'http_status': 200, 'raw_bytes': 258, 'rooms': 0}
```

**PASS** — byte-identical envelope shape to baseline.

## Test 2 — Tor transport (injected session)

Setup, per RESULTS.md A2: standalone Tor expert bundle
(`~/workspace/stack-experiments/tor/`, still on disk from the batch) with a
rebuilt torrc — `HTTPSProxy 127.0.0.1:3129` (the batch's local no-auth shim,
`stack-experiments/shim3129.py`, restarted for this test) +
`FascistFirewall 1` + `FirewallPorts 80, 443`, SOCKS on 127.0.0.1:9050,
DataDirectory reused (cached consensus → bootstrapped 100% in <1 min).
test_tor.py builds a requests.Session with `socks5h://127.0.0.1:9050`
(PySocks from the batch's `stack-experiments/pylibs`, same as feed_tor.py)
and passes it as `transport`:

```
Tor exit IP: 192.42.116.65
keys: ['extra', 'status_code']
status_code: 0
data: None
_meta: {'http_status': 200, 'raw_bytes': 258, 'rooms': 0}
```

**PASS** — from a genuine Tor exit (192.42.116.65, different from A2's
104.244.77.208, as expected), the module returns the identical baseline
envelope: HTTP 200, status_code 0, data null, 258 bytes, 0 rooms. The only
difference from feed_tor.py's hand-rolled version is that the request logic
now lives in feed() and the session was injected.

## Test 3 — import from a different working directory

Throwaway script at /tmp/import_test.py (5 lines: sys.path the module dir,
import feed, call it, print), run with cwd=/:

```
status_code: 0 | rooms: 0 | http: 200 | bytes: 258
exit=0 (cwd was /)
```

**PASS** — feed.py is a real importable module, not a script that only works
in place.

## Bonus parity check — channel_id=87

```
ch87: 0 {'http_status': 200, 'raw_bytes': 300, 'rooms': 0}
```

status_code 0 (recipe accepted for the rec-tab variant), 0 rooms, 300-byte
envelope (the `extra` block is larger on 87; data still null). Consistent
with FEED.md.

## Cleanup

Tor and the shim were stopped after Test 2; verified: ports 9050 and 3129
closed, no tor/shim processes remain. (One operational note: the first
cleanup attempt used `pkill -f` with patterns that also matched the cleanup
shell's own command line and SIGTERM'd the shell itself — processes were
then verified individually and the shim stopped by PID. No state left
running either way.)
