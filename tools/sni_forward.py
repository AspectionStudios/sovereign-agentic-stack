"""SNI-sniffing TCP forwarder: localhost:443 -> egress proxy CONNECT tunnel.
Lets proxy-unaware clients (TikTokLive's websocket) reach the internet."""
import socket, threading, struct, base64, os, re, sys

LISTEN = ("127.0.0.1", 443)
PROXY_HOST, PROXY_PORT = "198.19.0.1", 3128
px = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY") or ""
m = re.match(r"https?://([^:]+):([^@]+)@", px)
AUTH = base64.b64encode(f"{m.group(1)}:{m.group(2)}".encode()).decode() if m else ""

def get_sni(data: bytes):
    try:
        if data[0] != 0x16: return None
        # skip record header (5) -> handshake header (4) -> client hello body
        p = 5 + 4
        p += 2 + 32            # version + random
        sid_len = data[p]; p += 1 + sid_len
        cs_len = struct.unpack(">H", data[p:p+2])[0]; p += 2 + cs_len
        cm_len = data[p]; p += 1 + cm_len
        ext_len = struct.unpack(">H", data[p:p+2])[0]; p += 2
        end = p + ext_len
        while p + 4 <= end:
            et, el = struct.unpack(">HH", data[p:p+4]); p += 4
            if et == 0:  # server_name
                p += 2  # list len
                if data[p] == 0:
                    nl = struct.unpack(">H", data[p+1:p+3])[0]
                    return data[p+3:p+3+nl].decode()
                return None
            p += el
    except Exception:
        pass
    return None

def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            s.close()

def handle(client):
    try:
        client.settimeout(10)
        hello = client.recv(4096)
        if not hello: client.close(); return
        sni = get_sni(hello)
        if not sni:
            print("no SNI, closing", flush=True); client.close(); return
        print(f"tunnel -> {sni}:443", flush=True)
        px_sock = socket.create_connection((PROXY_HOST, PROXY_PORT), timeout=15)
        req = f"CONNECT {sni}:443 HTTP/1.1\r\nHost: {sni}:443\r\nProxy-Authorization: Basic {AUTH}\r\n\r\n"
        px_sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = px_sock.recv(4096)
            if not chunk: raise RuntimeError("proxy closed")
            resp += chunk
        if b" 200 " not in resp.split(b"\r\n", 1)[0]:
            print("proxy refused:", resp[:80], flush=True); client.close(); px_sock.close(); return
        px_sock.settimeout(None); client.settimeout(None)
        px_sock.sendall(hello)
        threading.Thread(target=pipe, args=(client, px_sock), daemon=True).start()
        pipe(px_sock, client)
    except Exception as e:
        print("handle err:", e, flush=True)
        try: client.close()
        except Exception: pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(LISTEN); srv.listen(100)
print(f"SNI forwarder on {LISTEN[0]}:{LISTEN[1]}", flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
