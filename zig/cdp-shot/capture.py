import json, time
import websocket

# Wrap the game's canvas 2d context: record every call + property set
INJECT = r"""
(() => {
  window.__calls = [];
  const c = document.querySelector('canvas');
  if (!c) return 'no canvas';
  const ctx = c.getContext('2d');
  window.__ctx = ctx;
  const methods = ['fillRect','clearRect','strokeRect','beginPath','arc','fill','stroke',
    'moveTo','lineTo','closePath','fillText','strokeText','save','restore',
    'translate','rotate','scale','setTransform','resetTransform','drawImage'];
  for (const m of methods) {
    if (typeof ctx[m] !== 'function') continue;
    const orig = ctx[m].bind(ctx);
    ctx[m] = (...a) => { window.__calls.push({m, a: a.map(String)}); return orig(...a); };
  }
  const props = ['fillStyle','strokeStyle','globalAlpha','lineWidth','shadowBlur',
    'shadowColor','font','textAlign','textBaseline','globalCompositeOperation','lineCap','lineJoin'];
  for (const p of props) {
    let val;
    try {
      Object.defineProperty(ctx, p, {
        set(v) { window.__calls.push({p, v: String(v)}); val = v; },
        get() { return val; },
        configurable: true,
      });
    } catch (e) {}
  }
  return 'wrapped';
})()
"""

ws = websocket.create_connection('ws://127.0.0.1:9222/', suppress_origin=True)
mid = [0]
def send(m, p=None, sid=None):
    mid[0] += 1
    d = {'id': mid[0], 'method': m}
    if p: d['params'] = p
    if sid: d['sessionId'] = sid
    ws.send(json.dumps(d))
    return mid[0]
def recv(iid, t=15):
    ws.settimeout(t); end = time.time() + t
    while time.time() < end:
        m = json.loads(ws.recv())
        if m.get('id') == iid: return m
    return {'error': 'timeout'}

iid = send('Target.createTarget', {'url': 'about:blank'}); r = recv(iid); tid = r['result']['targetId']
iid = send('Target.attachToTarget', {'targetId': tid, 'flatten': True}); r = recv(iid); sid = r['result']['sessionId']
iid = send('Page.navigate', {'url': 'http://127.0.0.1:8124/neon-swarm.html'}, sid=sid); recv(iid); time.sleep(3)

# inject wrapper
iid = send('Runtime.evaluate', {'expression': INJECT}, sid=sid); r = recv(iid)
print('inject:', r.get('result', {}).get('result', {}).get('value'))

# start game, play a bit
iid = send('Input.dispatchKeyEvent', {'type': 'keyDown', 'key': 'Enter', 'code': 'Enter'}, sid=sid); recv(iid)
iid = send('Input.dispatchKeyEvent', {'type': 'keyUp', 'key': 'Enter', 'code': 'Enter'}, sid=sid); recv(iid)
time.sleep(1)
for code in ['KeyW', 'KeyA', 'Space']:
    iid = send('Input.dispatchKeyEvent', {'type': 'keyDown', 'code': code, 'key': 'x'}, sid=sid); recv(iid)
time.sleep(2.5)
for code in ['KeyW', 'KeyA', 'Space']:
    iid = send('Input.dispatchKeyEvent', {'type': 'keyUp', 'code': code, 'key': 'x'}, sid=sid); recv(iid)

# dump calls
iid = send('Runtime.evaluate', {'expression': 'JSON.stringify(window.__calls.length)'}, sid=sid); r = recv(iid)
n = int(r['result']['result']['value'])
print('recorded calls:', n)

# fetch in chunks to avoid message size limits
iid = send('Runtime.evaluate', {'expression': 'JSON.stringify(window.__calls)'}, sid=sid); r = recv(iid, t=30)
calls = r['result']['result']['value']
open('/home/hatch/workspace/zig/cdp-shot/calls.json', 'w').write(calls)
print('wrote calls.json', len(calls), 'chars')
ws.close()
