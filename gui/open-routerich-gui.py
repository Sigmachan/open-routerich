#!/usr/bin/env python3
"""
open-routerich :: desktop installer GUI (Linux / macOS / Windows)

A pretty, dependency-free installer. Pure Python stdlib: it spins up a tiny local
web app (127.0.0.1 only), opens your browser, and drives the router over SSH so
you can set up DPI bypass / WARP / the on-router panel with a few clicks.

Requirements: python3 + the system `ssh` client (built into macOS, Linux, and
Windows 10+). Password auth additionally uses `sshpass` if installed; otherwise
use an SSH key / agent (recommended).

Run:
    python3 gui/open-routerich-gui.py
    # or: gui/run.sh   (macOS/Linux)   |   gui\run.bat (Windows)
"""
import http.server, socketserver, json, subprocess, threading, webbrowser, shutil, sys, os, socket

REPO_RAW = "https://raw.githubusercontent.com/Sigmachan/open-routerich/main"

# ---------------------------------------------------------------- ssh helpers
def _ssh_base(host, user, port, key, password):
    ssh = shutil.which("ssh") or "ssh"
    base = []
    if password and shutil.which("sshpass"):
        base = ["sshpass", "-p", password]
    cmd = base + [ssh,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=15",
        "-o", "NumberOfPasswordPrompts=1",
        "-p", str(port or 22)]
    if key:
        cmd += ["-i", key]
    cmd += [f"{user or 'root'}@{host}"]
    return cmd

def ssh_run(params, remote_cmd, timeout=300):
    host = (params.get("host") or "").strip()
    if not host:
        return 1, "no host given"
    cmd = _ssh_base(host, params.get("user"), params.get("port"),
                    params.get("key"), params.get("password")) + [remote_cmd]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except FileNotFoundError as e:
        return 127, f"ssh not found: {e}"
    except Exception as e:
        return 1, f"error: {e}"

def build_install_flags(opts):
    f = []
    if opts.get("quic") == 0:      f.append("--no-quic")
    if opts.get("redirect") == 0:  f.append("--no-redirect")
    if opts.get("overrides") == 0: f.append("--no-overrides")
    da = (opts.get("doh_addr") or "").strip()
    if da: f += ["--doh-addr", da]
    if opts.get("immutable") == 1: f.append("--immutable")
    if opts.get("entware") == 1:   f.append("--entware")
    f.append("-y")
    return " ".join(f)

ACTIONS = {
    "detect":    lambda o: "cat /tmp/sysinfo/model 2>/dev/null; echo '---'; "
                           "ubus call system board 2>/dev/null | grep -oE '\"version\":[^,]*'; "
                           "opkg print-architecture 2>/dev/null | awk '{print $2}' | tail -1; "
                           "( : > /usr/lib/.w 2>/dev/null && echo 'root=writable' && rm -f /usr/lib/.w || echo 'root=immutable'); "
                           "[ -x /opt/bin/opkg ] && echo 'entware=yes' || echo 'entware=no'",
    "install":   lambda o: f"wget -O- {REPO_RAW}/install.sh | sh -s -- {build_install_flags(o)}",
    "webui":     lambda o: f"wget -O- {REPO_RAW}/webui/install-webui.sh | sh",
    "uninstall": lambda o: f"wget -O- {REPO_RAW}/uninstall.sh | sh",
    "module":    lambda o: f"wget -O- {REPO_RAW}/modules/{o.get('name','awg-warp')}.sh | sh",
}

# ---------------------------------------------------------------- HTTP server
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, HTML, "text/html; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")
    def do_POST(self):
        ln = int(self.headers.get("Content-Length") or 0)
        try: data = json.loads(self.rfile.read(ln) or b"{}")
        except Exception: data = {}
        action = self.path.lstrip("/").split("?")[0]
        if action not in ACTIONS:
            self._send(404, json.dumps({"log": "unknown action"})); return
        remote = ACTIONS[action](data)
        rc, out = ssh_run(data, remote, timeout=600)
        self._send(200, json.dumps({"rc": rc, "log": out}))

def find_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def main():
    port = find_port()
    httpd = socketserver.ThreadingTCPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"open-routerich GUI -> {url}")
    if not shutil.which("ssh"):
        print("WARNING: system 'ssh' not found in PATH. Install OpenSSH client.", file=sys.stderr)
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try: httpd.serve_forever()
    except KeyboardInterrupt: print("\nbye, мяу")

HTML = r"""<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>open-routerich · installer</title>
<style>
:root{--bg:#0a0c12;--glass:rgba(255,255,255,.06);--glass2:rgba(255,255,255,.09);--stroke:rgba(255,255,255,.12);
--txt:#eef1f7;--mut:#9aa3b5;--accent:#6ea8ff;--accent2:#7af7c8;--ok:#54e08a;--err:#ff6b81;--warn:#ffd166;--r:18px}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:var(--txt);
background:radial-gradient(1200px 700px at 80% -10%,rgba(110,168,255,.16),transparent 60%),
radial-gradient(900px 600px at -10% 110%,rgba(122,247,200,.12),transparent 55%),var(--bg);min-height:100vh}
.wrap{max-width:760px;margin:0 auto;padding:26px 18px 80px}
header{display:flex;gap:14px;align-items:center;margin:6px 0 20px}
.logo{width:46px;height:46px;border-radius:14px;display:grid;place-items:center;font-size:24px;
background:linear-gradient(135deg,var(--accent),var(--accent2));box-shadow:0 8px 30px rgba(110,168,255,.35)}
h1{font-size:21px;margin:0}.sub{color:var(--mut);font-size:13px}
.card{background:var(--glass);backdrop-filter:blur(22px) saturate(150%);-webkit-backdrop-filter:blur(22px) saturate(150%);
border:1px solid var(--stroke);border-radius:var(--r);padding:18px;margin:14px 0;box-shadow:0 10px 40px rgba(0,0,0,.35)}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:1.1px;color:var(--mut);margin:0 0 13px}
label.f{display:block;margin:9px 0}.f .k{font-size:12px;color:var(--mut);margin-bottom:4px}
input{background:var(--glass2);border:1px solid var(--stroke);color:var(--txt);border-radius:10px;padding:10px 12px;width:100%;font:inherit;outline:none}
input:focus{border-color:var(--accent)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.row{display:flex;align-items:center;justify-content:space-between;padding:9px 2px;border-bottom:1px solid rgba(255,255,255,.06)}
.row:last-child{border-bottom:0}
.sw{position:relative;width:46px;height:27px}.sw input{opacity:0;width:0;height:0}
.sw span{position:absolute;inset:0;background:rgba(255,255,255,.14);border-radius:999px;cursor:pointer;transition:.2s}
.sw span:before{content:"";position:absolute;height:21px;width:21px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.2s}
.sw input:checked+span{background:linear-gradient(135deg,var(--accent),var(--accent2))}.sw input:checked+span:before{transform:translateX(19px)}
.btns{display:flex;gap:10px;flex-wrap:wrap;margin-top:6px}
button{font:inherit;font-weight:600;border:1px solid var(--stroke);border-radius:12px;padding:11px 16px;cursor:pointer;color:var(--txt);background:var(--glass2);transition:.15s}
button:hover{transform:translateY(-1px);background:rgba(255,255,255,.13)}button:disabled{opacity:.5;cursor:not-allowed}
button.primary{background:linear-gradient(135deg,var(--accent),var(--accent2));color:#06131f;border:0}
button.danger{background:rgba(255,107,129,.15);color:var(--err);border-color:rgba(255,107,129,.3)}
.mods{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:9px}
.mod{background:var(--glass2);border:1px solid var(--stroke);border-radius:13px;padding:12px;cursor:pointer}.mod:hover{background:rgba(255,255,255,.12)}
.mod .t{font-weight:600}.mod .d{color:var(--mut);font-size:12px;margin-top:2px}
pre#log{background:#05070c;border:1px solid var(--stroke);border-radius:13px;padding:13px;max-height:300px;overflow:auto;
font:12px/1.5 ui-monospace,Menlo,monospace;color:#c7d0e0;white-space:pre-wrap;margin-top:8px}
.foot{color:var(--mut);font-size:12px;text-align:center;margin-top:18px}a{color:var(--accent);text-decoration:none}
.spin{width:14px;height:14px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;display:inline-block;animation:s .7s linear infinite}@keyframes s{to{transform:rotate(360deg)}}
</style></head><body><div class="wrap">
<header><div class="logo">🛡️</div><div><h1>open-routerich · установщик</h1>
<div class="sub">обход DPI на любой OpenWrt-роутер по SSH</div></div></header>

<div class="card"><h2>Подключение к роутеру</h2>
<div class="grid2">
  <label class="f"><div class="k">IP роутера</div><input id="host" value="192.168.1.1"></label>
  <label class="f"><div class="k">SSH порт</div><input id="port" value="22"></label>
  <label class="f"><div class="k">Пользователь</div><input id="user" value="root"></label>
  <label class="f"><div class="k">Пароль (или пусто = ключ)</div><input id="password" type="password" placeholder="ключ/agent"></label>
</div>
<label class="f"><div class="k">SSH-ключ (необязательно, путь)</div><input id="key" placeholder="~/.ssh/id_ed25519"></label>
<div class="btns"><button id="btnDetect">🔍 Определить роутер</button></div>
</div>

<div class="card"><h2>Параметры обхода</h2>
<div class="row"><div>QUIC-блок (REJECT UDP 80/443)</div><label class="sw"><input type="checkbox" id="quic" checked><span></span></label></div>
<div class="row"><div>Гео-редирект доменов</div><label class="sw"><input type="checkbox" id="redirect" checked><span></span></label></div>
<div class="row"><div>Статические A-записи</div><label class="sw"><input type="checkbox" id="overrides" checked><span></span></label></div>
<label class="f"><div class="k">DoH-резолвер (immutable: 127.0.0.1#5353)</div><input id="doh_addr" placeholder="авто"></label>
<div class="btns">
  <button class="primary" id="btnInstall">⚡ Установить обход DPI</button>
  <button id="btnWebui">🖥️ Поставить веб-панель на роутер</button>
  <button class="danger" id="btnOff">⏏ Откатить</button>
</div></div>

<div class="card"><h2>Модули</h2><div class="mods">
  <div class="mod" data-mod="awg-warp"><div class="t">AmneziaWG WARP</div><div class="d">туннель WARP</div></div>
  <div class="mod" data-mod="warp6"><div class="t">WARP6 (IPv6)</div><div class="d">IPv6 WARP</div></div>
  <div class="mod" data-mod="podkop"><div class="t">Podkop</div><div class="d">доменный роутинг</div></div>
  <div class="mod" data-mod="proxy"><div class="t">opera-proxy+sing-box</div><div class="d">free-WARP :18080</div></div>
</div></div>

<div class="card"><h2>Журнал</h2><pre id="log">введи IP роутера и жми «Определить», мяу.</pre></div>
<div class="foot">open-routerich · <a href="https://github.com/Sigmachan/open-routerich" target="_blank">github.com/Sigmachan/open-routerich</a></div>
</div>
<script>
const $=s=>document.querySelector(s);
const log=t=>{const l=$("#log");l.textContent=(l.dataset.v?l.textContent+"\n":"")+t;l.dataset.v=1;l.scrollTop=l.scrollHeight;};
const conn=()=>({host:$("#host").value,port:$("#port").value,user:$("#user").value,password:$("#password").value,key:$("#key").value});
const opts=()=>({quic:$("#quic").checked?1:0,redirect:$("#redirect").checked?1:0,overrides:$("#overrides").checked?1:0,doh_addr:$("#doh_addr").value});
function busy(b){document.querySelectorAll("button").forEach(x=>x.disabled=b);}
async function call(action,extra){
  busy(true);log("→ "+action+" ...");
  try{
    const r=await fetch("/"+action,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({...conn(),...opts(),...(extra||{})})});
    const j=await r.json();log(j.log||"(нет вывода)");log(j.rc===0?"✓ готово (rc=0)":"⚠ rc="+j.rc);
  }catch(e){log("ошибка: "+e);}
  busy(false);
}
$("#btnDetect").onclick=()=>call("detect");
$("#btnInstall").onclick=()=>call("install");
$("#btnWebui").onclick=()=>call("webui");
$("#btnOff").onclick=()=>{if(confirm("Откатить open-routerich на роутере?"))call("uninstall");};
document.querySelectorAll(".mod").forEach(m=>m.onclick=()=>{if(confirm("Запустить модуль "+m.dataset.mod+"?"))call("module",{name:m.dataset.mod});});
</script></body></html>"""

if __name__ == "__main__":
    main()
