package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

var mu sync.Mutex
var validUser = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)

// ══════════════════════════════════════════════════════════════════
// UUID generator (v4 format, seperti generateUUID() di server.cjs)
// ══════════════════════════════════════════════════════════════════
func generateUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t := time.Now().UnixNano()
		for i := 0; i < 16; i++ {
			b[i] = byte(t >> (i * 8))
		}
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func getOrCreateUUID() string {
	const path = "/tmp/uuid.txt"
	if data, err := os.ReadFile(path); err == nil {
		if s := strings.TrimSpace(string(data)); len(s) >= 32 {
			return s
		}
	}
	u := generateUUID()
	_ = os.WriteFile(path, []byte(u), 0644)
	return u
}

// ══════════════════════════════════════════════════════════════════
// Public domain auto-detect (quick tunnel + named tunnel)
// ══════════════════════════════════════════════════════════════════
func getPublicDomain() string {
	const cachePath = "/tmp/domain.txt"

	// 1. Coba cache dulu
	if data, err := os.ReadFile(cachePath); err == nil {
		if s := strings.TrimSpace(string(data)); s != "" && s != "localhost" {
			return s
		}
	}

	// 2. Parse cloudflared logs
	logPaths := []string{
		"/tmp/tunnel.log",
		"/tmp/named_tunnel.log",
		"/var/log/cloudflared.log",
	}
	reQuick := regexp.MustCompile(`https://([a-zA-Z0-9][a-zA-Z0-9-]*\.trycloudflare\.com)`)
	reNamed := regexp.MustCompile(`"hostname"\s*:\s*"([^"]+)"`)

	for _, lp := range logPaths {
		data, err := os.ReadFile(lp)
		if err != nil {
			continue
		}
		if m := reQuick.FindSubmatch(data); m != nil {
			d := string(m[1])
			_ = os.WriteFile(cachePath, []byte(d), 0644)
			return d
		}
		if m := reNamed.FindSubmatch(data); m != nil {
			d := string(m[1])
			_ = os.WriteFile(cachePath, []byte(d), 0644)
			return d
		}
	}

	// 3. Env fallback (opsional)
	if d := os.Getenv("PUBLIC_DOMAIN"); d != "" {
		return d
	}
	return "localhost"
}

// ══════════════════════════════════════════════════════════════════
// SSH Account CRUD
// ══════════════════════════════════════════════════════════════════
func apiList(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	users := []map[string]string{}
	data, err := os.ReadFile("/etc/passwd")
	if err != nil {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": err.Error()})
		return
	}
	skip := map[string]bool{"nobody": true, "ubuntu": true, "sshd": true, "www-data": true, "systemd-network": true}
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.Split(line, ":")
		if len(parts) < 7 {
			continue
		}
		var uid int
		fmt.Sscanf(parts[2], "%d", &uid)
		if uid >= 1000 && uid < 65534 && !skip[parts[0]] {
			users = append(users, map[string]string{
				"username": parts[0],
				"shell":    parts[6],
				"home":     parts[5],
			})
		}
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"status": "success", "total": len(users), "users": users})
}

func apiAdd(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	r.ParseForm()
	user := strings.TrimSpace(r.FormValue("user"))
	pass := strings.TrimSpace(r.FormValue("pass"))

	if !validUser.MatchString(user) {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": "Username tidak valid (alphanumeric, -,_)"})
		return
	}
	if len(pass) < 4 {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": "Password minimal 4 karakter"})
		return
	}

	mu.Lock()
	defer mu.Unlock()

	if err := exec.Command("useradd", "-m", "-s", "/bin/bash", user).Run(); err != nil {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": "User sudah ada / gagal: " + err.Error()})
		return
	}
	cmd := exec.Command("chpasswd")
	cmd.Stdin = strings.NewReader(user + ":" + pass + "\n")
	if err := cmd.Run(); err != nil {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": "Gagal set password: " + err.Error()})
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{"status": "success", "message": "Akun SSH " + user + " berhasil dibuat"})
}

func apiDelete(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	r.ParseForm()
	user := strings.TrimSpace(r.FormValue("user"))
	if !validUser.MatchString(user) {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": "Username tidak valid"})
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if err := exec.Command("userdel", "-r", user).Run(); err != nil {
		json.NewEncoder(w).Encode(map[string]interface{}{"status": "error", "message": "Gagal hapus: " + err.Error()})
		return
	}
	json.NewEncoder(w).Encode(map[string]interface{}{"status": "success", "message": "Akun " + user + " dihapus"})
}

// ══════════════════════════════════════════════════════════════════
// Info JSON — UUID & Domain auto
// ══════════════════════════════════════════════════════════════════
func apiInfo(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"uuid":    getOrCreateUUID(),
		"domain":  getPublicDomain(),
		"cfip":    getEnv("CFIP", "104.17.3.81"),
		"cf_port": getEnv("CF_PORT", "443"),
		"paths": map[string]string{
			"vless":  "/vless-argo",
			"vmess":  "/vmess-argo",
			"trojan": "/trojan-argo",
			"ssh":    "/ssh-ws",
		},
	})
}

func getEnv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ══════════════════════════════════════════════════════════════════
// HTML Panel — Embedded
// ══════════════════════════════════════════════════════════════════
func serveUI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(htmlPanel))
}

func main() {
	// Generate UUID di awal (persist ke /tmp/uuid.txt)
	u := getOrCreateUUID()
	fmt.Printf("[admin] UUID aktif: %s\n", u)

	mux := http.NewServeMux()
	mux.HandleFunc("/api/list", apiList)
	mux.HandleFunc("/api/add", apiAdd)
	mux.HandleFunc("/api/delete", apiDelete)
	mux.HandleFunc("/api/info", apiInfo)
	mux.HandleFunc("/", serveUI)

	fmt.Println("[admin] listen 127.0.0.1:8081")
	http.ListenAndServe("127.0.0.1:8081", mux)
}

const htmlPanel = `<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Server Panel</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
background:#0a0a0f;color:#e0e0e0;padding:16px;line-height:1.6;font-size:14px}
.wrap{max-width:520px;margin:0 auto}
h1{color:#7B68EE;font-size:1.4em;text-align:center;margin-bottom:4px}
h2{color:#8A2BE2;font-size:.85em;margin:20px 0 8px;text-transform:uppercase;
letter-spacing:1px;border-bottom:1px solid #2a2a3a;padding-bottom:4px}
.sub{text-align:center;color:#6a6a8a;font-size:.8em;margin-bottom:16px}
.status{text-align:center;color:#00ff88;font-size:.85em;margin-bottom:16px;font-weight:bold}
.status::before{content:"● ";font-size:1em}
.card{background:#12121a;border:1px solid #2a2a3a;border-radius:8px;padding:14px;margin-bottom:12px}
.row{margin-bottom:10px}
label{display:block;font-size:.72em;color:#7B68EE;font-weight:bold;
margin-bottom:4px;text-transform:uppercase}
input,select{width:100%;background:#0a0a0f;border:1px solid #2a2a3a;
border-radius:6px;padding:8px 10px;color:#e0e0e0;font-family:monospace;font-size:.85em}
input:focus,select:focus{outline:none;border-color:#7B68EE}
button{background:#7B68EE;color:#000;border:none;border-radius:6px;
padding:9px 16px;font-weight:bold;font-family:inherit;cursor:pointer;
font-size:.82em;transition:.2s;margin-right:4px}
button:hover{background:#9370DB}
.btn-red{background:#d94a4a;color:#fff}
.btn-red:hover{background:#ff5555}
.btn-sm{padding:5px 10px;font-size:.7em;margin:0}
.out{background:#0a0a0f;border:1px solid #2a2a3a;border-radius:6px;
padding:10px;font-family:monospace;font-size:.72em;word-break:break-all;
margin-top:10px;min-height:36px;color:#00ff88;max-height:120px;overflow-y:auto}
.msg{padding:8px 10px;border-radius:6px;font-size:.8em;margin-top:8px;font-weight:bold}
.msg.ok{background:#1a3a1a;color:#00ff88;border:1px solid #00ff88}
.msg.err{background:#3a1a1a;color:#ff6666;border:1px solid #ff6666}
table{width:100%;border-collapse:collapse;font-size:.78em;margin-top:8px}
th,td{text-align:left;padding:6px 4px;border-bottom:1px solid #2a2a3a}
th{color:#7B68EE;font-size:.85em}
code{color:#00ff88;font-family:monospace;word-break:break-all}
.tabs{display:flex;gap:6px;margin-bottom:14px}
.tab{flex:1;padding:8px;text-align:center;background:#12121a;border:1px solid #2a2a3a;
border-radius:6px;cursor:pointer;font-size:.78em;font-weight:bold;color:#6a6a8a;transition:.2s}
.tab.active{background:#7B68EE;color:#000;border-color:#7B68EE}
.section{display:none}.section.active{display:block}
</style>
</head>
<body>
<div class="wrap">
  <h1>▬ SERVER PANEL ▬</h1>
  <p class="sub">VLESS · VMess · Trojan · SSH</p>
  <div class="status">ONLINE</div>

  <div class="tabs">
    <div class="tab active" onclick="tab('ssh',event)">SSH</div>
    <div class="tab" onclick="tab('config',event)">Config</div>
    <div class="tab" onclick="tab('info',event)">Info</div>
  </div>

  <div id="sec-ssh" class="section active">
    <h2>Buat Akun SSH</h2>
    <div class="card">
      <div class="row"><label>Username</label><input id="u" placeholder="user1"></div>
      <div class="row"><label>Password</label><input id="p" placeholder="min 4 karakter"></div>
      <button onclick="addUser()">+ Tambah</button>
      <button onclick="loadUsers()">↻ Refresh</button>
      <div id="msg-add"></div>
    </div>
    <h2>Akun SSH Aktif</h2>
    <div class="card">
      <table>
        <thead><tr><th>Username</th><th>Shell</th><th style="text-align:right">Aksi</th></tr></thead>
        <tbody id="tbody"><tr><td colspan="3" style="text-align:center;color:#6a6a8a">Loading...</td></tr></tbody>
      </table>
    </div>
  </div>

  <div id="sec-config" class="section">
    <h2>Config Generator</h2>
    <div class="card">
      <div class="row">
        <label>Protokol</label>
        <select id="proto">
          <option value="vless">VLESS</option>
          <option value="vmess">VMess</option>
          <option value="trojan">Trojan</option>
        </select>
      </div>
      <div class="row">
        <label>Bug Host (SNI)</label>
        <input id="bug" value="suporte.garena.com">
      </div>
      <div class="row">
        <label>Mode</label>
        <select id="mode">
          <option value="sni">SNI Normal</option>
          <option value="sni_reverse">SNI Reverse</option>
          <option value="cdn">CDN Proxy</option>
        </select>
      </div>
      <button onclick="genConfig()">Generate</button>
      <button onclick="copyOut()">Copy</button>
      <div id="out" class="out">Pilih protokol lalu klik Generate</div>
    </div>
  </div>

  <div id="sec-info" class="section">
    <h2>Info Server</h2>
    <div class="card">
      <div class="row"><label>Domain</label><input id="i-dom" readonly></div>
      <div class="row"><label>UUID</label><input id="i-uuid" readonly></div>
      <div class="row"><label>CF IP</label><input id="i-cfip" readonly></div>
      <div class="row"><label>CF Port</label><input id="i-cfport" readonly></div>
    </div>
    <h2>Path WS</h2>
    <div class="card" style="font-family:monospace;font-size:.8em;line-height:1.8">
      VLESS  : <code id="i-pv"></code><br>
      VMess  : <code id="i-pm"></code><br>
      Trojan : <code id="i-pt"></code><br>
      SSH WS : <code id="i-ps"></code>
    </div>
    <h2>Command SSH</h2>
    <div class="card">
      <div class="out" id="sshCmd">ssh -p 443 user@domain</div>
      <button onclick="copySSH()">Copy</button>
    </div>
  </div>
</div>

<script>
let INFO = {paths:{}};

function tab(t, ev){
  document.querySelectorAll('.tab').forEach(e=>e.classList.remove('active'));
  document.querySelectorAll('.section').forEach(e=>e.classList.remove('active'));
  ev.target.classList.add('active');
  document.getElementById('sec-'+t).classList.add('active');
}

function msg(el, text, ok){
  const d = document.getElementById(el);
  d.innerHTML = '<div class="msg '+(ok?'ok':'err')+'">'+text+'</div>';
  setTimeout(()=>d.innerHTML='', 4000);
}

async function loadUsers(){
  const r = await fetch('/api/list');
  const d = await r.json();
  const t = document.getElementById('tbody');
  if(!d.users || !d.users.length){
    t.innerHTML = '<tr><td colspan="3" style="text-align:center;color:#6a6a8a">Belum ada akun</td></tr>';
    return;
  }
  t.innerHTML = d.users.map(u=>`<tr>
    <td><code>${u.username}</code></td>
    <td style="font-size:.85em;color:#6a6a8a">${u.shell}</td>
    <td style="text-align:right"><button class="btn-red btn-sm" onclick="delUser('${u.username}')">Hapus</button></td>
  </tr>`).join('');
}

async function addUser(){
  const user = document.getElementById('u').value.trim();
  const pass = document.getElementById('p').value.trim();
  if(!user || !pass){ msg('msg-add','Isi username & password',false); return; }
  const r = await fetch('/api/add',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:'user='+encodeURIComponent(user)+'&pass='+encodeURIComponent(pass)});
  const d = await r.json();
  msg('msg-add', d.message, d.status==='success');
  if(d.status==='success'){ document.getElementById('u').value=''; document.getElementById('p').value=''; loadUsers(); }
}

async function delUser(user){
  if(!confirm('Hapus akun '+user+'?')) return;
  const r = await fetch('/api/delete',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:'user='+encodeURIComponent(user)});
  const d = await r.json();
  if(d.status==='success') loadUsers();
  else alert(d.message);
}

function b64(s){return btoa(encodeURIComponent(s).replace(/%([0-9A-F]{2})/g,
  (m,p1)=>String.fromCharCode('0x'+p1)));}

function genConfig(){
  const proto = document.getElementById('proto').value;
  const mode = document.getElementById('mode').value;
  const bug = document.getElementById('bug').value.trim();
  const host = INFO.domain;
  const uuid = INFO.uuid;
  const path = INFO.paths[proto] || '/'+proto+'-argo';
  const cdnPath = '/'+bug+path;
  const rem = 'PREMIUM-'+proto.toUpperCase()+'-'+mode.toUpperCase();
  let r = '';

  if(mode==='sni'){
    if(proto==='vless') r = 'vless://'+uuid+'@'+bug+':443?encryption=none&security=tls&sni='+host+'&fp=randomized&type=ws&host='+host+'&path='+encodeURIComponent(path)+'#'+rem;
    if(proto==='vmess') r = 'vmess://'+b64(JSON.stringify({v:"2",ps:rem,add:bug,port:443,id:uuid,aid:0,scy:"auto",net:"ws",type:"none",host:host,path:path,tls:"tls",sni:host}));
    if(proto==='trojan') r = 'trojan://'+uuid+'@'+bug+':443?security=tls&sni='+host+'&type=ws&host='+host+'&path='+encodeURIComponent(path)+'#'+rem;
  } else if(mode==='sni_reverse'){
    if(proto==='vless') r = 'vless://'+uuid+'@'+host+':443?encryption=none&security=tls&sni='+bug+'&fp=randomized&type=ws&host='+bug+'&path='+encodeURIComponent(path)+'#'+rem;
    if(proto==='vmess') r = 'vmess://'+b64(JSON.stringify({v:"2",ps:rem,add:host,port:443,id:uuid,aid:0,scy:"auto",net:"ws",type:"none",host:bug,path:path,tls:"tls",sni:bug}));
    if(proto==='trojan') r = 'trojan://'+uuid+'@'+host+':443?security=tls&sni='+bug+'&type=ws&host='+bug+'&path='+encodeURIComponent(path)+'#'+rem;
  } else {
    if(proto==='vless') r = 'vless://'+uuid+'@'+host+':443?encryption=none&security=tls&sni='+host+'&fp=randomized&type=ws&host='+host+'&path='+encodeURIComponent(cdnPath)+'#'+rem;
    if(proto==='vmess') r = 'vmess://'+b64(JSON.stringify({v:"2",ps:rem,add:host,port:443,id:uuid,aid:0,scy:"auto",net:"ws",type:"none",host:host,path:cdnPath,tls:"tls",sni:host}));
    if(proto==='trojan') r = 'trojan://'+uuid+'@'+host+':443?security=tls&sni='+host+'&type=ws&host='+host+'&path='+encodeURIComponent(cdnPath)+'#'+rem;
  }
  document.getElementById('out').textContent = r;
}

function copyOut(){ navigator.clipboard.writeText(document.getElementById('out').textContent); }

function copySSH(){
  const dom = INFO.domain || 'localhost';
  navigator.clipboard.writeText('ssh -p 443 user@'+dom);
}

(async ()=>{
  try {
    const r = await fetch('/api/info');
    INFO = await r.json();
    document.getElementById('i-dom').value = INFO.domain;
    document.getElementById('i-uuid').value = INFO.uuid;
    document.getElementById('i-cfip').value = INFO.cfip;
    document.getElementById('i-cfport').value = INFO.cf_port;
    document.getElementById('i-pv').textContent = INFO.paths.vless;
    document.getElementById('i-pm').textContent = INFO.paths.vmess;
    document.getElementById('i-pt').textContent = INFO.paths.trojan;
    document.getElementById('i-ps').textContent = INFO.paths.ssh;
    document.getElementById('sshCmd').textContent = 'ssh -p 443 user@'+INFO.domain;
  } catch(e){}
  loadUsers();
})();
</script>
</body>
</html>`
