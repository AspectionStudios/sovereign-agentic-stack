# Home relay

Route a small number of HTTPS requests from the agent VM out through a machine
on the owner's Tailscale tailnet, so the traffic exits to the internet from
that machine's connection and public IP.

## Pieces

- **Host end — `tools/home_proxy.py`.** Tiny authenticated HTTP CONNECT proxy,
  pure Python 3 stdlib, no installs. Set the `TOKEN` constant in the file (the
  repo copy carries a placeholder), then run it on the tailnet host and leave
  it running:

  ```
  python3 home_proxy.py        # listens on port 8899
  ```

  Auth is `Proxy-Authorization: Basic` with any username and the token as the
  password. Requests without it get `407 Proxy Authentication Required`.

- **Agent end — a chaining shim on the VM.** The VM reaches tailnet services
  through its tunnel; the shim accepts a local CONNECT on 127.0.0.1:8898,
  opens a tunnel connection to the host's `100.x:8899`, then issues the real
  CONNECT with the proxy auth and relays bytes both ways. Any HTTP client can
  then use the shim as its proxy — e.g. `tools/feed.py` with a
  `requests.Session` whose proxies point at the shim.

## Security model

The proxy listens on 0.0.0.0 on the host, but it is only reachable from the
host's LAN and the tailnet. Never port-forward port 8899 from a router.
Token auth sits on top of WireGuard; treat the token as a shared secret for
the tailnet only.

## Status (2026-10-24)

Chain proven end-to-end: an egress check (`https://ipinfo.io/json`) issued
through the shim returns the host's public IP (tested with the host on AWS
EC2 us-east-2). Feed discovery through the relay still returns zero rooms
when the host's egress is a datacenter IP — TikTok gates the feed against
every datacenter egress class tested so far (VM egress, Tor exits, public
proxies, EC2). The remaining untested class is a clean residential or
carrier IP; the relay turns on as-is behind any such host.
